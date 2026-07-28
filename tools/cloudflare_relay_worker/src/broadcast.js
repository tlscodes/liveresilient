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

/** Longest descriptor accepted. The format's maximum is 283 bytes. */
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

/**
 * Largest fork report accepted.
 *
 * A report is a certificate and two descriptors — under 600 bytes for any
 * real one. The cap is generous enough for a future layout and small
 * enough that the open write path cannot be used as storage.
 */
export const MAX_FORK_REPORT_BYTES = 2048;

/** How long anything written here survives. */
export const RETENTION_MS = 48 * 60 * 60 * 1000;

/** Posts one author may publish within a retention window. */
export const MAX_POSTS_PER_AUTHOR = 512;

/** Bytes one storage shard will hold before refusing writes. */
export const MAX_SHARD_BYTES = 64 * 1024 * 1024;

/** Highest sequence number the client's wire format can express. */
const MAX_SEQ = 0xffffffff;

/** A 16-byte author id, as 32 lowercase hex characters. */
const HEX_AUTHOR = /^[0-9a-f]{32}$/;
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
    if (!HEX_AUTHOR.test(authorId) || !DECIMAL.test(seqText)) return null;
    const seq = Number(seqText);
    if (!Number.isSafeInteger(seq) || seq > MAX_SEQ) return null;
    return { kind: 'descriptor', authorId, seq, shard: `a:${authorId}` };
  }
  // Fork reports are content-addressed inside one author's slot, so a
  // relay may hold several — two readers can see different forks — and
  // none may overwrite another. The hash is always in the path for the
  // same reason it is for an object: it is what makes the write checkable
  // without any key, which is what lets anyone at all publish one.
  if (parts.length === 4 && parts[0] === '' && parts[1] === 'f') {
    const [, , authorId, hash] = parts;
    if (!HEX_AUTHOR.test(authorId) || !HEX_64.test(hash)) return null;
    return {
      kind: 'forkReport',
      authorId,
      hash,
      shard: `f:${authorId}`,
    };
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

/**
 * Header carrying the credentials a descriptor write must prove itself
 * with: base64url of the 32-byte root public key followed by the
 * 125-byte publishing certificate.
 */
export const AUTH_HEADER = 'x-broadcast-auth';

/**
 * Exact byte length of the credential blob: root key plus certificate.
 *
 * The 125 is a version-2 certificate with a 16-byte author id. Kept as
 * arithmetic rather than a literal so the reason the number moved stays
 * visible — this length has changed twice, once for the publishing
 * cadence and once for the wider author id, and both times the relay
 * knowing it as its own constant is what the conformance vectors caught.
 */
export const AUTH_BYTES = 32 + 125;

/** Offsets into a descriptor, from the Dart format's own layout. */
const DESCRIPTOR_AUTHOR_OFFSET = 2;
const DESCRIPTOR_AUTHOR_BYTES = 16;
const DESCRIPTOR_SIGNATURE_BYTES = 64;

/** Offsets into a publishing certificate. */
const CERT_AUTHOR_OFFSET = 1;
const CERT_KEY_OFFSET = 17;
const CERT_KEY_BYTES = 32;
const CERT_SIGNATURE_BYTES = 64;

const CERT_DOMAIN = 'vck/broadcast/publishing-key/v1\n';
const DESCRIPTOR_DOMAIN = 'vck/broadcast/descriptor/v1\n';

/** Decode base64url without padding. */
function fromBase64Url(text) {
  const padded = text.replace(/-/g, '+').replace(/_/g, '/');
  try {
    const binary = atob(padded);
    const out = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) out[i] = binary.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

function concat(prefix, bytes) {
  const out = new Uint8Array(prefix.length + bytes.length);
  out.set(prefix, 0);
  out.set(bytes, prefix.length);
  return out;
}

const TEXT = new TextEncoder();

/**
 * Verify an Ed25519 signature with WebCrypto.
 *
 * Needs a compatibility date where workerd exposes Ed25519 through
 * SubtleCrypto. If a deployment's date predates that, importKey throws and
 * this returns false, which fails writes closed rather than open — the
 * safe direction, and loud enough to notice immediately.
 */
async function verifyEd25519(publicKey, message, signature) {
  try {
    const key = await crypto.subtle.importKey(
      'raw',
      publicKey,
      { name: 'Ed25519' },
      false,
      ['verify'],
    );
    return await crypto.subtle.verify('Ed25519', key, signature, message);
  } catch {
    return false;
  }
}

function bytesEqual(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i += 1) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

/**
 * Whether the credentials in [authHeader] authorize writing [descriptor]
 * at [authorId].
 *
 * The relay holds no keys and knows no authors, but it does not need to:
 * the credentials carry the whole chain, and every link is checkable from
 * the bytes alone.
 *
 *   1. the author id in the path is the truncated hash of the root key
 *   2. the certificate names that same author and is signed by that root
 *   3. the descriptor names that same author and is signed by the
 *      publishing key the certificate delegates to
 *
 * Without this, write-once worked against the author it was meant to
 * protect: anyone could PUT a one-byte body to a hundred of an author's
 * future sequence numbers and lock them for the whole retention window.
 * Note what is still NOT checked here — certificate validity dates. Time
 * is the reader's business; the relay only establishes that these bytes
 * come from whoever holds that root key.
 */
export async function authorizeDescriptorWrite({
  authorId,
  descriptor,
  authHeader,
  verify = verifyEd25519,
  hash = sha256Hex,
}) {
  if (!authHeader) return false;
  const credentials = fromBase64Url(authHeader);
  if (!credentials || credentials.length !== AUTH_BYTES) return false;

  const rootKey = credentials.subarray(0, 32);
  const certificate = credentials.subarray(32);

  // 1. The path names this root key.
  const rootHash = await hash(rootKey);
  if (rootHash.slice(0, DESCRIPTOR_AUTHOR_BYTES * 2) !== authorId) {
    return false;
  }

  // 2. The certificate is this author's, and the root key signed it.
  const certAuthor = certificate.subarray(
    CERT_AUTHOR_OFFSET,
    CERT_AUTHOR_OFFSET + DESCRIPTOR_AUTHOR_BYTES,
  );
  const pathAuthor = new Uint8Array(
    authorId.match(/../g).map((pair) => parseInt(pair, 16)),
  );
  if (!bytesEqual(certAuthor, pathAuthor)) return false;

  const certBody = certificate.subarray(
    0,
    certificate.length - CERT_SIGNATURE_BYTES,
  );
  const certSignature = certificate.subarray(
    certificate.length - CERT_SIGNATURE_BYTES,
  );
  const certOk = await verify(
    rootKey,
    concat(TEXT.encode(CERT_DOMAIN), certBody),
    certSignature,
  );
  if (!certOk) return false;

  // 3. The descriptor is this author's, and the delegated key signed it.
  if (
    descriptor.length <
    DESCRIPTOR_AUTHOR_OFFSET +
      DESCRIPTOR_AUTHOR_BYTES +
      DESCRIPTOR_SIGNATURE_BYTES
  ) {
    return false;
  }
  const descriptorAuthor = descriptor.subarray(
    DESCRIPTOR_AUTHOR_OFFSET,
    DESCRIPTOR_AUTHOR_OFFSET + DESCRIPTOR_AUTHOR_BYTES,
  );
  if (!bytesEqual(descriptorAuthor, pathAuthor)) return false;

  const publishingKey = certificate.subarray(
    CERT_KEY_OFFSET,
    CERT_KEY_OFFSET + CERT_KEY_BYTES,
  );
  const descriptorBody = descriptor.subarray(
    0,
    descriptor.length - DESCRIPTOR_SIGNATURE_BYTES,
  );
  const descriptorSignature = descriptor.subarray(
    descriptor.length - DESCRIPTOR_SIGNATURE_BYTES,
  );
  return verify(
    publishingKey,
    concat(TEXT.encode(DESCRIPTOR_DOMAIN), descriptorBody),
    descriptorSignature,
  );
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
  switch (route.kind) {
    case 'descriptor':
      return `d:${route.authorId}:${route.seq}`;
    case 'forkReport':
      return `f:${route.authorId}:${route.hash}`;
    default:
      return `o:${route.hash}`;
  }
}

/**
 * Accounted size of a stored entry.
 *
 * Tolerates both a typed array and a plain array, because a shard written
 * by an older build holds the latter and its bytes must still be counted
 * and freed correctly.
 */
function entryLength(entry) {
  const bytes = entry?.bytes;
  if (!bytes) return 0;
  return bytes.byteLength ?? bytes.length ?? 0;
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
    // Injected so the authorization logic runs under a plain object in a
    // unit test, with no workerd and no real keys.
    this.verify = options.verify ?? verifyEd25519;
  }

  /// Handles one already-parsed broadcast request.
  ///
  /// [authHeader] is required for a descriptor write and ignored for an
  /// object write, whose name already proves what it holds.
  async handle(route, method, body, authHeader) {
    if (method === 'GET' || method === 'HEAD') {
      return this.read(route, method === 'HEAD');
    }
    if (method === 'PUT' || method === 'POST') {
      // Size first, signatures second. Verifying an Ed25519 chain is the
      // most expensive thing this code does, and there is no sense
      // spending it on a body that is already too big or empty to store.
      const refusal = this.checkSize(route, body);
      if (refusal) return refusal;

      if (route.kind === 'descriptor') {
        const bytes = new Uint8Array(body ?? new Uint8Array(0));
        const authorized = await authorizeDescriptorWrite({
          authorId: route.authorId,
          descriptor: bytes,
          authHeader,
          verify: this.verify,
        });
        if (!authorized) {
          return new Response(
            'a descriptor write must prove the author signed it\n',
            { status: 403 },
          );
        }
      }
      return this.write(route, body);
    }
    return new Response('method not allowed\n', { status: 405 });
  }

  async read(route, headOnly) {
    const key = storageKey(route);
    const held = await this.storage.get(key);
    if (!held) return new Response(null, { status: 404 });
    if (this.isExpired(held)) {
      await this.forget(key, held);
      return new Response(null, { status: 404 });
    }
    const bytes = new Uint8Array(held.bytes);
    return new Response(headOnly ? null : bytes, {
      status: 200,
      headers: { ...IMMUTABLE_HEADERS, 'content-length': String(bytes.length) },
    });
  }

  /// Refuses a body that cannot be stored, or null when it can.
  checkSize(route, body) {
    const length = body?.byteLength ?? body?.length ?? 0;
    if (length === 0) {
      return new Response('empty body\n', { status: 400 });
    }
    const limit = {
      descriptor: MAX_DESCRIPTOR_BYTES,
      forkReport: MAX_FORK_REPORT_BYTES,
      object: MAX_OBJECT_BYTES,
    }[route.kind];
    if (length > limit) {
      return new Response(`at most ${limit} bytes\n`, { status: 413 });
    }
    return null;
  }

  async write(route, body) {
    const bytes = new Uint8Array(body);
    const refusal = this.checkSize(route, bytes);
    if (refusal) return refusal;

    // An object must hash to the name it is filed under. This is the only
    // claim the relay can check without keys, and checking it means a
    // reader that trusts nothing still cannot be handed the wrong bytes
    // under a right name. A fork report is filed the same way, which is
    // what lets anyone at all publish one: a false report is bytes that
    // fail on the reader's side, so the relay needs no opinion about it.
    if (route.kind === 'object' || route.kind === 'forkReport') {
      const actual = await sha256Hex(bytes);
      if (actual !== route.hash) {
        return new Response('object does not hash to its name\n', {
          status: 400,
        });
      }
    }

    const key = storageKey(route);
    const held = await this.storage.get(key);
    if (held && this.isExpired(held)) {
      // Discount it before writing over it. Without this the old entry's
      // bytes stay counted while the new entry's are added, and the
      // shard's accounting drifts upward every time an address is reused
      // until it reports itself full while holding almost nothing.
      await this.forget(key, held);
    }
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
    // Stored as the typed array, not `[...bytes]`. Spreading turns 100 kB
    // into a 100,000-element JS array whose serialized form is several
    // times the byte count it is accounted at, so the shard ceiling would
    // bound nothing real. Structured clone handles a Uint8Array directly.
    await this.storage.put(key, { bytes, at });
    await this.storage.put('meta', {
      bytes: meta.bytes + bytes.length,
      posts: meta.posts + (route.kind === 'descriptor' ? 1 : 0),
      since: meta.since ?? at,
    });
    return new Response(null, { status: 201 });
  }

  /// Delete one entry and give back what it was accounted at.
  async forget(key, entry) {
    await this.storage.delete(key);
    const meta = await this.loadMeta();
    const length = entryLength(entry);
    await this.storage.put('meta', {
      ...meta,
      bytes: Math.max(0, meta.bytes - length),
      posts: key.startsWith('d:') ? Math.max(0, meta.posts - 1) : meta.posts,
    });
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
    if (meta.since === null || this.now() - meta.since <= this.retentionMs) {
      return meta;
    }
    // The window has rolled. The counters reset with it — otherwise an
    // author who published a lot once stays locked out long after those
    // posts are gone — but they are recomputed from what is actually
    // held rather than zeroed. Zeroing was wrong in both directions:
    // entries written just before the boundary are still live for nearly
    // another full window, so an author could hold twice the stated cap
    // by publishing on either side of it, and the shard's byte ceiling
    // undercounted the same set.
    let bytes = 0;
    let posts = 0;
    const all = await this.storage.list();
    for (const [key, entry] of all) {
      if (key === 'meta' || this.isExpired(entry)) continue;
      bytes += entryLength(entry);
      if (key.startsWith('d:')) posts += 1;
    }
    return { bytes, posts, since: posts > 0 || bytes > 0 ? this.now() : null };
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
    let livePosts = 0;
    for (const [key, entry] of all) {
      if (key === 'meta') continue;
      if (this.isExpired(entry)) {
        await this.storage.delete(key);
        removed += 1;
      } else {
        liveBytes += entryLength(entry);
        if (key.startsWith('d:')) livePosts += 1;
      }
    }
    // Both counters are recomputed from what is actually held, not just
    // the byte one. Leaving `posts` alone meant an author whose posts had
    // all expired and been swept still counted against the rate limit
    // until the window rolled.
    const meta = await this.loadMeta();
    await this.storage.put('meta', {
      ...meta,
      bytes: liveBytes,
      posts: livePosts,
    });
    return removed;
  }

  /**
   * What this shard is actually holding, counted rather than estimated.
   *
   * Every capacity question about this relay has so far been answered
   * with arithmetic on assumptions. These are the numbers that settle
   * them: what is stored, what is live, what has expired but not yet been
   * swept, and how far into its own limits the shard is. Nothing here is
   * derived from the meta record — it is counted from storage — so it
   * also reveals a meta record that has drifted.
   */
  async stats() {
    const all = await this.storage.list();
    let descriptors = 0;
    let objects = 0;
    let forkReports = 0;
    let liveBytes = 0;
    let expired = 0;
    let oldestAt = null;
    for (const [key, entry] of all) {
      if (key === 'meta') continue;
      if (this.isExpired(entry)) {
        expired += 1;
        continue;
      }
      liveBytes += entryLength(entry);
      if (key.startsWith('d:')) descriptors += 1;
      else if (key.startsWith('f:')) forkReports += 1;
      else objects += 1;
      if (oldestAt === null || entry.at < oldestAt) oldestAt = entry.at;
    }
    const meta = (await this.storage.get('meta')) ?? { bytes: 0, posts: 0 };
    return {
      descriptors,
      objects,
      forkReports,
      liveBytes,
      expiredAwaitingSweep: expired,
      shardBytesLimit: MAX_SHARD_BYTES,
      shardBytesUsedFraction: liveBytes / MAX_SHARD_BYTES,
      postsThisWindow: meta.posts ?? 0,
      postsPerAuthorLimit: MAX_POSTS_PER_AUTHOR,
      retentionMs: this.retentionMs,
      oldestEntryAgeMs: oldestAt === null ? null : this.now() - oldestAt,
      // Named so a drift between what is stored and what is accounted is
      // visible at a glance rather than inferred from a bug report.
      accountedBytes: meta.bytes ?? 0,
      accountingDriftBytes: (meta.bytes ?? 0) - liveBytes,
    };
  }

  /// Whether anything held has passed its retention.
  ///
  /// Cheap enough to ask before rescheduling an alarm, and it keeps the
  /// alarm loop from being the only thing that can notice.
  async hasExpired() {
    const all = await this.storage.list();
    for (const [key, entry] of all) {
      if (key !== 'meta' && this.isExpired(entry)) return true;
    }
    return false;
  }
}
