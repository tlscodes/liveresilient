/**
 * Builds the real credentials a descriptor write must carry, using real
 * Ed25519 keys, so the worker's authorization runs against the same bytes
 * the Dart client produces rather than against a stub.
 */

import { sha256Hex } from '../src/broadcast.js';

const TEXT = new TextEncoder();

const CERT_DOMAIN = 'vck/broadcast/publishing-key/v1\n';
const DESCRIPTOR_DOMAIN = 'vck/broadcast/descriptor/v1\n';

function toBase64Url(bytes) {
  let binary = '';
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function concat(...parts) {
  const total = parts.reduce((sum, p) => sum + p.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function u32(value) {
  const out = new Uint8Array(4);
  new DataView(out.buffer).setUint32(0, value);
  return out;
}

/** Five-byte big-endian, matching the Dart format's u40. */
function u40(value) {
  const out = new Uint8Array(5);
  out[0] = Math.floor(value / 0x100000000) & 0xff;
  new DataView(out.buffer).setUint32(1, value >>> 0);
  return out;
}

export async function generateKeyPair() {
  const pair = await crypto.subtle.generateKey({ name: 'Ed25519' }, true, [
    'sign',
    'verify',
  ]);
  const raw = new Uint8Array(
    await crypto.subtle.exportKey('raw', pair.publicKey),
  );
  return { privateKey: pair.privateKey, publicKey: raw };
}

async function sign(privateKey, message) {
  return new Uint8Array(
    await crypto.subtle.sign('Ed25519', privateKey, message),
  );
}

/** The truncated author id for a root public key. */
export async function authorIdOf(rootPublicKey) {
  return (await sha256Hex(rootPublicKey)).slice(0, 16);
}

/** A 117-byte version-2 publishing certificate, signed by the root key. */
export async function makeCertificate({
  root,
  publishingPublicKey,
  notBeforeSeconds = 1_800_000_000,
  notAfterSeconds = 1_800_600_000,
  cadenceHours = 720,
}) {
  const authorHex = await authorIdOf(root.publicKey);
  const author = new Uint8Array(
    authorHex.match(/../g).map((pair) => parseInt(pair, 16)),
  );
  const cadence = new Uint8Array(2);
  new DataView(cadence.buffer).setUint16(0, cadenceHours);
  const body = concat(
    new Uint8Array([2]),
    author,
    publishingPublicKey,
    u40(notBeforeSeconds),
    u40(notAfterSeconds),
    cadence,
  );
  const signature = await sign(
    root.privateKey,
    concat(TEXT.encode(CERT_DOMAIN), body),
  );
  return concat(body, signature);
}

/**
 * A minimal valid descriptor: version 1, text layer only, signed by the
 * publishing key. Layout mirrors the Dart encoder exactly.
 */
export async function makeDescriptor({
  root,
  publishing,
  seq = 0,
  timeSeconds = 1_800_000_100,
  fill = 1,
}) {
  const authorHex = await authorIdOf(root.publicKey);
  const author = new Uint8Array(
    authorHex.match(/../g).map((pair) => parseInt(pair, 16)),
  );
  const prev = new Uint8Array(32);
  if (seq !== 0) prev.fill(9);
  const layerHash = new Uint8Array(32).fill(fill);
  const body = concat(
    new Uint8Array([1, 0x01]),
    author,
    u32(seq),
    u40(timeSeconds),
    prev,
    layerHash,
  );
  const signature = await sign(
    publishing.privateKey,
    concat(TEXT.encode(DESCRIPTOR_DOMAIN), body),
  );
  return concat(body, signature);
}

/** The `x-broadcast-auth` header value for these credentials. */
export function authHeader(rootPublicKey, certificate) {
  return toBase64Url(concat(rootPublicKey, certificate));
}

/** Everything one author needs, ready to write with. */
export async function newAuthor() {
  const root = await generateKeyPair();
  const publishing = await generateKeyPair();
  const certificate = await makeCertificate({
    root,
    publishingPublicKey: publishing.publicKey,
  });
  return {
    root,
    publishing,
    certificate,
    authorId: await authorIdOf(root.publicKey),
    header: authHeader(root.publicKey, certificate),
    descriptor: (options = {}) =>
      makeDescriptor({ root, publishing, ...options }),
  };
}
