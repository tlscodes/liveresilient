/**
 * Silent-push wake for a locked phone (phase چ, PROMPT-CH-PUSH-2026-10-13).
 *
 * A phone that wants to be woken when a box lands on a shelf registers its
 * APNs device token against that shelf's author id:
 *
 *   PUT /p/<authorId>   body {"token":"<hex>","env":"sandbox"|"production"}
 *   GET /p/<authorId>   {"registered":bool,"last":{...}} — never the token
 *   GET /p/probe        one push to an all-zero token: proves the key, the
 *                       JWT and the HTTP/2 path without waking anyone
 *
 * The registration lives in its own archive shard `p:<authorId>`, so the
 * archive's own storage, sweep and stats never see it. When the author's
 * shard `a:<authorId>` stores a descriptor (201), it asks `p:<authorId>` to
 * fire: one background push, `content-available: 1`, no alert, no content.
 *
 * What the relay learns: that some token reads that pseudonymous author.
 * Shelf authors change every day and name nobody, so it still cannot tell
 * who writes to whom; it can tell that the shelf has a reader on that token.
 *
 * Signing: ES256 JWT (kid = key id, iss = team id) made with WebCrypto from
 * the .p8 in the APNS_KEY_P8 secret. Apple wants a token reused for at least
 * 20 minutes and refused after 60, so one is cached for 40.
 */

const TOKEN_HEX = /^[0-9a-f]{64,200}$/;
const AUTHOR_HEX = /^[0-9a-f]{32}$/;
const REGISTRATION_TTL_MS = 4 * 24 * 3600 * 1000;
const JWT_REUSE_MS = 40 * 60 * 1000;
const APNS_HOST = {
  sandbox: 'https://api.sandbox.push.apple.com',
  production: 'https://api.push.apple.com',
};
const DEFAULT_TOPIC = 'com.tlscodes.referenceApp';

/** `/p/<author>` → shard name, or `/p/probe`; null for anything else. */
export function parsePushPath(pathname) {
  const parts = pathname.split('/');
  if (parts.length !== 3 || parts[0] !== '' || parts[1] !== 'p') return null;
  if (parts[2] === 'probe') return { kind: 'probe' };
  if (!AUTHOR_HEX.test(parts[2])) return null;
  return { kind: 'push', authorId: parts[2], shard: `p:${parts[2]}` };
}

function b64url(bytes) {
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function pemToDer(pem) {
  const body = pem.replace(/-----[A-Z ]+-----/g, '').replace(/\s+/g, '');
  const bin = atob(body);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

let cachedJwt = null; // { jwt, at, kid }

/** The provider token; [nowMs] and [subtle] are injectable for the test. */
export async function apnsJwt(env, nowMs = Date.now(), subtle = crypto.subtle) {
  if (!env.APNS_KEY_P8 || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) {
    throw new Error('apns secrets missing');
  }
  if (cachedJwt && cachedJwt.kid === env.APNS_KEY_ID && nowMs - cachedJwt.at < JWT_REUSE_MS) {
    return cachedJwt.jwt;
  }
  const enc = new TextEncoder();
  const header = b64url(enc.encode(JSON.stringify({ alg: 'ES256', kid: env.APNS_KEY_ID })));
  const claims = b64url(
    enc.encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(nowMs / 1000) })),
  );
  const key = await subtle.importKey(
    'pkcs8',
    pemToDer(env.APNS_KEY_P8),
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  );
  // WebCrypto gives r||s (IEEE P1363), which is exactly the JWS ES256 form.
  const sig = new Uint8Array(
    await subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, enc.encode(`${header}.${claims}`)),
  );
  const jwt = `${header}.${claims}.${b64url(sig)}`;
  cachedJwt = { jwt, at: nowMs, kid: env.APNS_KEY_ID };
  return jwt;
}

/** The request one background push is; separate so the test can read it. */
export function backgroundPushRequest(jwt, token, apnsEnv, topic = DEFAULT_TOPIC) {
  const host = APNS_HOST[apnsEnv] ?? APNS_HOST.sandbox;
  return {
    url: `${host}/3/device/${token}`,
    init: {
      method: 'POST',
      headers: {
        authorization: `bearer ${jwt}`,
        'apns-push-type': 'background',
        'apns-priority': '5',
        'apns-topic': topic,
        'apns-expiration': '0',
        'content-type': 'application/json',
      },
      body: JSON.stringify({ aps: { 'content-available': 1 } }),
    },
  };
}

/** Sends one background push; never throws — the outcome is the result. */
export async function sendBackgroundPush(env, token, apnsEnv, fetchImpl = fetch) {
  const at = new Date().toISOString();
  try {
    const jwt = await apnsJwt(env);
    const { url, init } = backgroundPushRequest(jwt, token, apnsEnv, env.APNS_TOPIC || DEFAULT_TOPIC);
    const resp = await fetchImpl(url, init);
    const text = await resp.text();
    let reason = null;
    try {
      reason = text ? JSON.parse(text).reason ?? null : null;
    } catch {
      reason = text.slice(0, 120);
    }
    return { at, env: apnsEnv, status: resp.status, apns_id: resp.headers.get('apns-id'), reason };
  } catch (error) {
    return { at, env: apnsEnv, status: 0, error: `${error?.message ?? error}`.slice(0, 160) };
  }
}

function json(status, value) {
  return new Response(`${JSON.stringify(value)}\n`, {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  });
}

/**
 * Handles `/p/<author>` inside the `p:<author>` shard, and the internal
 * `__push_fire` the author's archive shard sends after it stores a pointer.
 */
export async function handlePushShard(request, storage, env, nowMs = Date.now(), fetchImpl = fetch) {
  const url = new URL(request.url);
  if (url.pathname === '/__push_fire') {
    const reg = await storage.get('push');
    if (!reg || nowMs - reg.registeredAt > REGISTRATION_TTL_MS) return json(200, { fired: false });
    const last = await sendBackgroundPush(env, reg.token, reg.env, fetchImpl);
    await storage.put('push_last', last);
    return json(200, { fired: true, last });
  }
  if (request.method === 'PUT') {
    let body;
    try {
      body = JSON.parse(new TextDecoder().decode(await request.arrayBuffer()));
    } catch {
      return json(400, { error: 'body must be json' });
    }
    const token = `${body?.token ?? ''}`.toLowerCase();
    const apnsEnv = body?.env === 'production' ? 'production' : 'sandbox';
    if (!TOKEN_HEX.test(token)) return json(400, { error: 'token must be hex' });
    await storage.put('push', { token, env: apnsEnv, registeredAt: nowMs });
    return json(201, { registered: true, env: apnsEnv });
  }
  if (request.method === 'GET') {
    const reg = await storage.get('push');
    const live = !!reg && nowMs - reg.registeredAt <= REGISTRATION_TTL_MS;
    return json(200, {
      registered: live,
      env: live ? reg.env : null,
      registered_at: live ? new Date(reg.registeredAt).toISOString() : null,
      last: (await storage.get('push_last')) ?? null,
    });
  }
  return json(405, { error: 'method not allowed' });
}

/** `/p/probe`: one push to an all-zero sandbox token. 400 BadDeviceToken = signing works. */
export async function handlePushProbe(env, fetchImpl = fetch) {
  return json(200, await sendBackgroundPush(env, '0'.repeat(64), 'sandbox', fetchImpl));
}

export const _test = { pemToDer, b64url, resetJwtCache: () => (cachedJwt = null) };
