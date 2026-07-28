/**
 * Border relay for the resilient fallback lanes, as a Cloudflare Worker.
 *
 * Two lanes terminate here:
 *
 *   WSS      GET  /ws?session=<id>&role=<a|b>   (with Upgrade: websocket)
 *   HTTP     POST /http?session=<id>&role=<a|b> body = raw frame bytes
 *            GET  /http?session=<id>&role=<a|b>&wait=<ms>
 *
 * Both carry the same bytes: whatever the client wrote, forwarded verbatim
 * to the other side of the same session. The relay never parses a payload,
 * never reframes it, and never reorders it — it is a pipe with a name.
 * gRPC length-prefixed framing is the client's business; the relay would
 * behave identically if the frames were anything else.
 *
 * A third, unrelated surface also terminates here — the broadcast routes
 * `/a/<authorId>/<seq>` and `/o/<hash>`, handled in `broadcast.js`. They
 * share nothing with the call lanes but the hostname: no session, no
 * pairing, no live path. They are immutable reads with short retention,
 * which is why they can be cached at the edge while a call frame never
 * can.
 *
 * State lives in a Durable Object because pairing two peers requires one
 * place that both requests reach. A stateless Worker cannot do it: two
 * requests for the same session can land on different machines.
 */

import {
  AUTH_HEADER,
  BroadcastArchive,
  parseBroadcastPath,
} from './broadcast.js';

/** How often a shard wakes to expire what it holds. */
const _sweepIntervalMs = 60 * 60 * 1000;

/** Frames buffered for a peer that has not connected yet, per direction. */
const MAX_QUEUED_FRAMES = 256;

/** Bytes buffered for a peer that has not connected yet, per direction. */
const MAX_QUEUED_BYTES = 4 * 1024 * 1024;

/** Longest a long-poll is held open before answering empty. */
const MAX_POLL_WAIT_MS = 25_000;

/** Sessions idle this long are dropped. */
const SESSION_IDLE_MS = 5 * 60_000;

const OTHER = { a: 'b', b: 'a' };

/** Served for every path that is not a relay route. */
const LANDING_PAGE = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Service Operational</title>
<style>
body{font-family:system-ui,sans-serif;margin:0;display:grid;
place-items:center;min-height:100vh;color:#333;background:#fafafa}
main{text-align:center}h1{font-weight:500;font-size:1.25rem;margin:0 0 .5rem}
p{margin:0;color:#777;font-size:.9rem}
</style>
</head>
<body><main><h1>Service Operational</h1><p>This endpoint is running.</p></main></body>
</html>
`;

function badRequest(message) {
  return new Response(`${message}\n`, { status: 400 });
}

/** Parses and validates the session/role pair every route needs. */
function readRoute(url) {
  const session = url.searchParams.get('session');
  const role = url.searchParams.get('role');
  if (!session || session.length > 128 || !/^[A-Za-z0-9._-]+$/.test(session)) {
    return { error: 'session must be 1-128 chars of [A-Za-z0-9._-]' };
  }
  if (role !== 'a' && role !== 'b') {
    return { error: "role must be 'a' or 'b'" };
  }
  return { session, role };
}

export default {
  /**
   * Routes to the session's Durable Object. The object name is derived
   * from the session id, so both peers of a call reach the same instance
   * wherever they connect from.
   */
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === '/health') {
      return new Response('ok\n', { status: 200 });
    }

    // Broadcast is checked before the landing page so a malformed
    // broadcast path falls through to the same ordinary page every other
    // unknown path gets, rather than announcing that the route exists.
    const broadcast = parseBroadcastPath(url.pathname);
    if (broadcast) {
      const id = env.BROADCAST_ARCHIVE.idFromName(broadcast.shard);
      return env.BROADCAST_ARCHIVE.get(id).fetch(request);
    }

    // Anything that is not a relay route gets an ordinary page rather
    // than a 404. A scanner that probes a host and gets "not found" on
    // every path learns the host answers only on secret paths, which is
    // itself a signal; a plain page is the same answer any unremarkable
    // site gives. It claims to be nothing in particular and imitates no
    // real service — the point is to be uninteresting, not to pass as
    // someone else.
    if (url.pathname !== '/ws' && url.pathname !== '/http') {
      return new Response(LANDING_PAGE, {
        status: 200,
        headers: {
          'content-type': 'text/html; charset=utf-8',
          'cache-control': 'public, max-age=3600',
        },
      });
    }

    const route = readRoute(url);
    if (route.error) return badRequest(route.error);

    const id = env.RELAY_SESSION.idFromName(route.session);
    return env.RELAY_SESSION.get(id).fetch(request);
  },
};

/**
 * One shard of the broadcast archive: either one author's descriptors or
 * one hash prefix's objects.
 *
 * All the logic is in `BroadcastArchive`, which knows nothing about the
 * Durable Object runtime and is unit-tested against a plain object. This
 * class only supplies the real storage, the real clock, and the alarm
 * that expires what it holds.
 */
export class BroadcastArchiveObject {
  constructor(state) {
    this.state = state;
    this.archive = new BroadcastArchive(state.storage);
  }

  async fetch(request) {
    const url = new URL(request.url);
    const route = parseBroadcastPath(url.pathname);
    if (!route) return new Response(null, { status: 404 });

    const body =
      request.method === 'PUT' || request.method === 'POST'
        ? await request.arrayBuffer()
        : null;
    const response = await this.archive.handle(
      route,
      request.method,
      body,
      request.headers.get(AUTH_HEADER),
    );

    // Any write attempt schedules the sweep, not only a successful one.
    // Scheduling on 201 alone left a dead end: a shard that reported
    // itself full answered 507, a 507 scheduled nothing, and once the last
    // alarm had fired there was no path left that could ever free it.
    if (request.method === 'PUT' || request.method === 'POST') {
      const pending = await this.state.storage.getAlarm();
      if (pending === null) {
        await this.state.storage.setAlarm(Date.now() + _sweepIntervalMs);
      }
    }
    return response;
  }

  /// Expires what is past retention, and keeps sweeping while anything is
  /// still held that will eventually expire.
  async alarm() {
    await this.archive.sweep();
    // Rescheduled while anything remains, because everything here has an
    // expiry and something must be awake to act on it.
    const remaining = await this.state.storage.list();
    for (const key of remaining.keys()) {
      if (key !== 'meta') {
        await this.state.storage.setAlarm(Date.now() + _sweepIntervalMs);
        return;
      }
    }
  }
}

/**
 * One call session: at most two peers, 'a' and 'b', and a queue in each
 * direction for whichever peer is not currently attached.
 */
export class RelaySession {
  constructor(state) {
    this.state = state;

    /** Attached WebSocket per role. */
    this.sockets = { a: null, b: null };

    /** Frames waiting for the peer of that role to read them. */
    this.inbox = { a: [], b: [] };

    /** Byte total of each inbox, kept incrementally. */
    this.inboxBytes = { a: 0, b: 0 };

    /** Resolvers for long-polls currently parked on each inbox. */
    this.waiters = { a: [], b: [] };

    this.lastSeenMs = Date.now();
  }

  async fetch(request) {
    this.lastSeenMs = Date.now();
    const url = new URL(request.url);
    const { session, role, error } = readRoute(url);
    if (error) return badRequest(error);

    if (url.pathname === '/ws') return this.handleWebSocket(request, role);
    // HEAD is the long-poll lane's liveness probe: it must not consume
    // queued frames, so it answers before the poll path.
    if (request.method === 'HEAD') return new Response(null, { status: 204 });
    if (request.method === 'POST') return this.handlePost(request, role);
    if (request.method === 'GET') return this.handlePoll(url, role);
    return new Response('method not allowed\n', { status: 405 });
  }

  /** Accepts one side of the session and pipes its frames to the other. */
  handleWebSocket(request, role) {
    if (request.headers.get('Upgrade') !== 'websocket') {
      return badRequest('expected a websocket upgrade');
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();

    // A reconnect replaces the previous socket for that role rather than
    // rejecting: a mobile client that changed network has no way to close
    // the old one first.
    const previous = this.sockets[role];
    if (previous) {
      try {
        previous.close(1000, 'replaced by a newer connection');
      } catch {
        // Already gone; nothing to do.
      }
    }
    this.sockets[role] = server;

    server.addEventListener('message', (event) => {
      this.lastSeenMs = Date.now();
      this.deliver(OTHER[role], event.data);
    });

    const drop = () => {
      if (this.sockets[role] === server) this.sockets[role] = null;
    };
    server.addEventListener('close', drop);
    server.addEventListener('error', drop);

    // Anything that arrived before this peer attached is delivered now,
    // in the order it was received.
    this.flushTo(role);

    return new Response(null, { status: 101, webSocket: client });
  }

  /** Accepts frame bytes over plain HTTP for the long-poll lane. */
  async handlePost(request, role) {
    const body = await request.arrayBuffer();
    if (body.byteLength === 0) return badRequest('empty body');
    this.deliver(OTHER[role], body);
    return new Response(null, { status: 204 });
  }

  /**
   * Long-poll: answers with whatever is queued for [role], waiting up to
   * `wait` milliseconds for the first frame rather than returning empty
   * immediately.
   */
  async handlePoll(url, role) {
    const requested = Number(url.searchParams.get('wait') ?? '0');
    const wait = Number.isFinite(requested)
      ? Math.min(Math.max(requested, 0), MAX_POLL_WAIT_MS)
      : 0;

    if (this.inbox[role].length === 0 && wait > 0) {
      await this.waitForFrames(role, wait);
    }
    return this.takeInbox(role);
  }

  /** Resolves when a frame arrives for [role], or after [wait] ms. */
  waitForFrames(role, wait) {
    return new Promise((resolve) => {
      let done = false;
      const finish = () => {
        if (done) return;
        done = true;
        const index = this.waiters[role].indexOf(finish);
        if (index >= 0) this.waiters[role].splice(index, 1);
        resolve();
      };
      this.waiters[role].push(finish);
      setTimeout(finish, wait);
    });
  }

  /** Empties [role]'s inbox into one response body, order preserved. */
  takeInbox(role) {
    const frames = this.inbox[role];
    if (frames.length === 0) return new Response(null, { status: 204 });

    this.inbox[role] = [];
    this.inboxBytes[role] = 0;

    let total = 0;
    for (const frame of frames) total += frame.byteLength;
    const body = new Uint8Array(total);
    let offset = 0;
    for (const frame of frames) {
      body.set(new Uint8Array(frame), offset);
      offset += frame.byteLength;
    }

    return new Response(body, {
      status: 200,
      headers: {
        'content-type': 'application/octet-stream',
        'cache-control': 'no-store',
      },
    });
  }

  /**
   * Hands one frame to [role]: straight down its socket when attached,
   * otherwise onto its queue for the next attach or poll.
   */
  deliver(role, frame) {
    const socket = this.sockets[role];
    if (socket) {
      try {
        socket.send(frame);
        return;
      } catch {
        // The socket died between the check and the send; fall through to
        // the queue so the frame is not lost.
        this.sockets[role] = null;
      }
    }
    this.enqueue(role, frame);
  }

  /**
   * Queues a frame, dropping the OLDEST first when a bound is hit.
   *
   * Oldest-first because this carries live media: a receiver that fell
   * behind wants the newest frames, and dropping the newest would make the
   * queue a permanent record of the moment it filled up.
   */
  enqueue(role, frame) {
    const bytes = frame.byteLength ?? frame.length ?? 0;
    this.inbox[role].push(frame);
    this.inboxBytes[role] += bytes;

    while (
      this.inbox[role].length > MAX_QUEUED_FRAMES ||
      this.inboxBytes[role] > MAX_QUEUED_BYTES
    ) {
      const dropped = this.inbox[role].shift();
      if (dropped === undefined) break;
      this.inboxBytes[role] -= dropped.byteLength ?? dropped.length ?? 0;
    }

    for (const waiter of [...this.waiters[role]]) waiter();
  }

  /** Pushes a freshly attached peer's backlog down its socket, in order. */
  flushTo(role) {
    const socket = this.sockets[role];
    if (!socket) return;
    const frames = this.inbox[role];
    this.inbox[role] = [];
    this.inboxBytes[role] = 0;
    for (const frame of frames) {
      try {
        socket.send(frame);
      } catch {
        // Lost mid-flush; requeue the remainder rather than dropping it.
        this.enqueue(role, frame);
      }
    }
  }
}
