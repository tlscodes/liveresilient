/**
 * Broadcast routes for the border relay: immutable reads, write-once
 * writes, short retention.
 *
 *   GET  /a/<authorId>/<seq>   one post's descriptor
 *   PUT  /a/<authorId>/<seq>   publish it, once
 *   GET  /o/<hash>             one content-addressed object
 *   PUT  /o/<hash>             store it, verified against its own name
 *
 * Three properties make this cheap and hard to misuse, and each one is
 * enforced here rather than assumed:
 *
 *  * Every path is immutable. A given (author, seq) is one document
 *    forever and a given hash is its own bytes, so responses carry a
 *    year-long immutable cache directive.
 *
 *    Read that directive for what it is: it cuts traffic and latency, NOT
 *    Worker invocations. On a route bound to a Worker the Worker runs in
 *    front of the cache, so every read counts. Reaching a large audience
 *    means serving these objects from a path that is not bound to a
 *    Worker — a public bucket on a custom domain with cache rules — and
 *    leaving the Worker the write path, whose volume is negligible. Until
 *    that exists, one relay on the free tier serves on the order of
 *    50,000 readers of one text post per day, since a post is at least
 *    two reads.
 *  * A write may not change what a path already holds. That is what makes
 *    a duplicated signing key show up as two conflicting posts a reader
 *    can prove, instead of history being quietly replaced.
 *  * Retention is short by design. This is a cache, not an archive:
 *    durability comes from the readers who already hold verified copies,
 *    and a relay that forgets quickly is both cheaper and a far easier
 *    thing to operate.
 *
 * The relay verifies no signatures and holds no keys — it cannot, since
 * it has no idea who any author is. It checks only what it can check from
 * the bytes themselves: that an object hashes to the name it is filed
 * under, and that nothing exceeds its limits.
 */

/** Longest descriptor accepted. The format's maximum is 243 bytes. */
export const MAX_DESCRIPTOR_BYTES = 512;

/**
 * Largest object accepted.
 *
 * Set by the storage backend, not by the format: a Durable Object value
 * is capped near 128 KB, so a publisher targeting this relay must chunk
 * its media at or below this. The Dart client's default chunk size of
 * 64 KB fits with room to spare.
 */
export const MAX_OBJECT_BYTES = 100_000;

/** How long anything written here survives. */
export const RETENTION_MS = 48 * 60 * 60 * 1000;

/** Posts one author may publish within a retention window. */
export const MAX_POSTS_PER_AUTHOR = 512;

/** Bytes one storage shard will hold before refusing writes. */
export const MAX_SHARD_BYTES = 64 * 1024 * 1024;

/** Highest sequence number the client's wire format can express. */
const MAX_SEQ = 0xffffffff;

const HEX_16 = /^[0-9a-f]{16}$/;
const HEX_64 = /^[0-9a-f]{64}$/;
const DECIMAL = /^(0|[1-9][0-9]*)$/;

/**
 * Classifies a broadcast path, or returns null when it is not one.
 *
 * Strict on purpose: one canonical spelling per address. A leading zero
 * or an uppercase hash would be a second name for the same bytes, which
 * would split the cache and let one post be served twice.
 */
export function parseBroadcastPath(pathname) {
  const parts = pathname.split('/');
  if (parts.length === 4 && parts[0] === '' && parts[1] === 'a') {
    const [, , authorId, seqText] = parts;
    if (!HEX_16.test(authorId) || !DECIMAL.test(seqText)) return null;
    const seq = Number(seqText);
    if (!Number.isSafeInteger(seq) || seq > MAX_SEQ) return null;
    return { kind: 'descriptor', authorId, seq, shard: `a:${authorId}` };
  }
  if (parts.length === 3 && parts[0] === '' && parts[1] === 'o') {
    const hash = parts[2];
    if (!HEX_64.test(hash)) return null;
    // Sharded by the first byte of the hash so an object can be found
    // from its name alone, with no index and no author involved.
    return { kind: 'object', hash, shard: `o:${hash.slice(0, 2)}` };
  }
  return null;
}

/** SHA-256 of [bytes] as lowercase hex. */
export async function sha256Hex(bytes) {
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

const IMMUTABLE_HEADERS = {
  'content-type': 'application/octet-stream',
  'cache-control': 'public, max-age=31536000, immutable',
};

function storageKey(route) {
  return route.kind === 'descriptor'
    ? `d:${route.authorId}:${route.seq}`
    : `o:${route.hash}`;
}

function sameBytes(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i += 1) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

/**
 * The storage logic, independent of the Durable Object runtime.
 *
 * Takes the async key-value surface a Durable Object provides — get, put,
 * delete, list — plus a clock, so the whole of it runs under a plain
 * object in a unit test. The Durable Object class is a thin wrapper.
 */
export class BroadcastArchive {
  /**
   * @param {{get:Function, put:Function, delete:Function, list:Function}} storage
   * @param {{now?:Function, retentionMs?:number}} [options]
   */
  constructor(storage, options = {}) {
    this.storage = storage;
    this.now = options.now ?? (() => Date.now());
    this.retentionMs = options.retentionMs ?? RETENTION_MS;
  }

  /** Handles one already-parsed broadcast request. */
  async handle(route, method, body) {
    if (method === 'GET' || method === 'HEAD') {
      return this.read(route, method === 'HEAD');
    }
    if (method === 'PUT' || method === 'POST') {
      return this.write(route, body);
    }
    return new Response('method not allowed\n', { status: 405 });
  }

  async read(route, headOnly) {
    const held = await this.storage.get(storageKey(route));
    if (!held) return new Response(null, { status: 404 });
    if (this.isExpired(held)) {
      await this.storage.delete(storageKey(route));
      return new Response(null, { status: 404 });
    }
    const bytes = new Uint8Array(held.bytes);
    return new Response(headOnly ? null : bytes, {
      status: 200,
      headers: { ...IMMUTABLE_HEADERS, 'content-length': String(bytes.length) },
    });
  }

  async write(route, body) {
    const bytes = new Uint8Array(body);
    if (bytes.length === 0) {
      return new Response('empty body\n', { status: 400 });
    }
    const limit =
      route.kind === 'descriptor' ? MAX_DESCRIPTOR_BYTES : MAX_OBJECT_BYTES;
    if (bytes.length > limit) {
      return new Response(`at most ${limit} bytes\n`, { status: 413 });
    }

    // An object must hash to the name it is filed under. This is the only
    // claim the relay can check without keys, and checking it means a
    // reader that trusts nothing still cannot be handed the wrong bytes
    // under a right name.
    if (route.kind === 'object') {
      const actual = await sha256Hex(bytes);
      if (actual !== route.hash) {
        return new Response('object does not hash to its name\n', {
          status: 400,
        });
      }
    }

    const key = storageKey(route);
    const held = await this.storage.get(key);
    if (held && !this.isExpired(held)) {
      // Write-once. Identical bytes are a retry and succeed quietly;
      // different bytes are a conflict, and refusing them is what keeps a
      // fork visible instead of overwritten.
      return sameBytes(new Uint8Array(held.bytes), bytes)
        ? new Response(null, { status: 204 })
        : new Response('this address already holds different bytes\n', {
            status: 409,
          });
    }

    const meta = await this.loadMeta();
    if (meta.bytes + bytes.length > MAX_SHARD_BYTES) {
      return new Response('shard is full\n', { status: 507 });
    }
    if (route.kind === 'descriptor' && meta.posts >= MAX_POSTS_PER_AUTHOR) {
      return new Response('too many posts in this window\n', { status: 429 });
    }

    const at = this.now();
    await this.storage.put(key, { bytes: [...bytes], at });
    await this.storage.put('meta', {
      bytes: meta.bytes + bytes.length,
      posts: meta.posts + (route.kind === 'descriptor' ? 1 : 0),
      since: meta.since ?? at,
    });
    return new Response(null, { status: 201 });
  }

  isExpired(entry) {
    return this.now() - entry.at > this.retentionMs;
  }

  async loadMeta() {
    const meta = (await this.storage.get('meta')) ?? {
      bytes: 0,
      posts: 0,
      since: null,
    };
    // The rate limit is per window, so the counters reset with it.
    // Otherwise an author who published a lot once would be locked out
    // long after those posts had already been forgotten.
    if (meta.since !== null && this.now() - meta.since > this.retentionMs) {
      return { bytes: 0, posts: 0, since: null };
    }
    return meta;
  }

  /**
   * Deletes everything past its retention. Returns the number of entries
   * removed, so a caller can tell a sweep that did work from one that
   * found nothing.
   */
  async sweep() {
    const all = await this.storage.list();
    let removed = 0;
    let liveBytes = 0;
    for (const [key, entry] of all) {
      if (key === 'meta') continue;
      if (this.isExpired(entry)) {
        await this.storage.delete(key);
        removed += 1;
      } else {
        liveBytes += entry.bytes.length;
      }
    }
    if (removed > 0) {
      const meta = await this.loadMeta();
      await this.storage.put('meta', { ...meta, bytes: liveBytes });
    }
    return removed;
  }
}
