/**
 * Checking a broadcast post without the app.
 *
 * A signature only means something to whoever can check it, and until this
 * existed that was one application. But a message spreads by screenshot,
 * and a screenshot carries no signature — so the thing people actually
 * pass around was exactly the thing nobody could verify.
 *
 * This is the whole verifier: parse an evidence bundle, check the chain,
 * report what it does and does not prove. No network, no dependencies, no
 * storage. It runs from a file on a memory card as happily as from a page.
 *
 * What it proves: this text was signed by the holder of this root key, at
 * this sequence number, at this declared time. What it does not prove:
 * whose key that is. Binding a key to a person is what a bootstrap code —
 * and ultimately a human — is for, and a verifier that blurred the two
 * would be worse than none.
 */

export const EVIDENCE_VERSION = 1;
export const CERTIFICATE_BYTES = 125;
export const CERTIFICATE_VERSION = 2;
export const DESCRIPTOR_VERSION = 1;
export const AUTHOR_ID_BYTES = 16;
export const MAX_TEXT_BYTES = 64 * 1024;

const CERT_DOMAIN = 'vck/broadcast/publishing-key/v1\n';
const DESCRIPTOR_DOMAIN = 'vck/broadcast/descriptor/v1\n';

const LAYER_TEXT = 0x01;
const LAYER_SLOTS = [0x01, 0x02, 0x04, 0x08, 0x10];
const LAYER_RETRACTION = 0x10;

const TEXT_ENCODER = new TextEncoder();

/** Why a bundle was refused. Each value is shown to a person verbatim. */
export const Rejection = {
  malformed: 'these bytes are not an evidence bundle',
  unsupportedVersion: 'this bundle is from a newer format than this page',
  textTooLong: 'the text is larger than this format carries',
  badCertificate: 'the delegation is not signed by the key it names',
  unverifiedDescriptor: 'the post is not signed by the delegated key',
  noTextLayer: 'the post carries no text to check',
  textDoesNotMatch: 'the text is not the text that was signed',
  noEd25519:
    'this browser cannot check Ed25519 signatures, so nothing here is proven',
};

function bytesEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a[i] ^ b[i];
  return diff === 0;
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

export function toHex(bytes) {
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** Decode base64, standard or url-safe, ignoring whitespace people add. */
export function fromBase64(text) {
  const cleaned = text
    .replace(/\s+/g, '')
    .replace(/-/g, '+')
    .replace(/_/g, '/');
  try {
    const binary = atob(cleaned);
    const out = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) out[i] = binary.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

async function sha256(bytes) {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
}

async function verifyEd25519(publicKey, message, signature) {
  const key = await crypto.subtle.importKey(
    'raw',
    publicKey,
    { name: 'Ed25519' },
    false,
    ['verify'],
  );
  return crypto.subtle.verify('Ed25519', key, signature, message);
}

/** Whether this runtime can check the signatures at all. */
export async function hasEd25519() {
  try {
    await crypto.subtle.importKey(
      'raw',
      new Uint8Array(32),
      { name: 'Ed25519' },
      false,
      ['verify'],
    );
    return true;
  } catch {
    return false;
  }
}

class Reader {
  constructor(bytes) {
    this.bytes = bytes;
    this.offset = 0;
  }

  need(count) {
    if (count < 0 || this.bytes.length - this.offset < count) {
      throw new RangeError('truncated');
    }
  }

  u8() {
    this.need(1);
    return this.bytes[this.offset++];
  }

  u16() {
    this.need(2);
    const v = (this.bytes[this.offset] << 8) | this.bytes[this.offset + 1];
    this.offset += 2;
    return v;
  }

  u32() {
    this.need(4);
    const view = new DataView(
      this.bytes.buffer,
      this.bytes.byteOffset + this.offset,
      4,
    );
    this.offset += 4;
    return view.getUint32(0);
  }

  u40() {
    this.need(5);
    const b = this.bytes;
    const o = this.offset;
    this.offset += 5;
    return (
      b[o] * 0x100000000 +
      ((b[o + 1] << 24) >>> 0) +
      (b[o + 2] << 16) +
      (b[o + 3] << 8) +
      b[o + 4]
    );
  }

  take(count) {
    this.need(count);
    const out = this.bytes.slice(this.offset, this.offset + count);
    this.offset += count;
    return out;
  }

  get remaining() {
    return this.bytes.length - this.offset;
  }
}

function parseDescriptor(bytes) {
  const reader = new Reader(bytes);
  if (reader.u8() !== DESCRIPTOR_VERSION) return null;
  const flags = reader.u8();
  // An unknown flag shifts every field after it, so it is refused rather
  // than skipped — the same rule the app applies, and the reason a
  // retracting post is never shown stripped of its retraction.
  if ((flags & ~0x1f) !== 0 || flags === 0) return null;
  const authorId = reader.take(AUTHOR_ID_BYTES);
  const seq = reader.u32();
  const publishedAt = new Date(reader.u40() * 1000);
  reader.take(32); // prev
  const commitments = new Map();
  for (const slot of LAYER_SLOTS) {
    if ((flags & slot) !== 0) commitments.set(slot, reader.take(32));
  }
  const signature = reader.take(64);
  if (reader.remaining !== 0) return null;
  return {
    authorId,
    seq,
    publishedAt,
    commitments,
    signature,
    body: bytes.slice(0, bytes.length - 64),
    retracts: commitments.get(LAYER_RETRACTION) ?? null,
  };
}

function parseCertificate(bytes) {
  if (bytes.length !== CERTIFICATE_BYTES) return null;
  const reader = new Reader(bytes);
  if (reader.u8() !== CERTIFICATE_VERSION) return null;
  const authorId = reader.take(AUTHOR_ID_BYTES);
  const publishingKey = reader.take(32);
  const notBefore = new Date(reader.u40() * 1000);
  const notAfter = new Date(reader.u40() * 1000);
  const cadenceHours = reader.u16();
  const signature = reader.take(64);
  return {
    authorId,
    publishingKey,
    notBefore,
    notAfter,
    cadenceHours,
    signature,
    body: bytes.slice(0, bytes.length - 64),
  };
}

/**
 * Check an evidence bundle.
 *
 * Returns `{ ok: true, post }` or `{ ok: false, reason }`. Never throws:
 * the input is something a stranger pasted in, so refusal is an ordinary
 * outcome rather than an error.
 */
export async function verifyEvidence(bytes) {
  if (!(await hasEd25519())) {
    return { ok: false, reason: Rejection.noEd25519 };
  }

  let rootPublicKey;
  let certificateBytes;
  let descriptorBytes;
  let text;
  try {
    const reader = new Reader(bytes);
    if (reader.u8() !== EVIDENCE_VERSION) {
      return { ok: false, reason: Rejection.unsupportedVersion };
    }
    rootPublicKey = reader.take(32);
    certificateBytes = reader.take(CERTIFICATE_BYTES);
    descriptorBytes = reader.take(reader.u16());
    const textLength = reader.u32();
    if (textLength > MAX_TEXT_BYTES) {
      return { ok: false, reason: Rejection.textTooLong };
    }
    text = reader.take(textLength);
    if (reader.remaining !== 0) {
      return { ok: false, reason: Rejection.malformed };
    }
  } catch {
    return { ok: false, reason: Rejection.malformed };
  }

  const certificate = parseCertificate(certificateBytes);
  if (certificate === null) {
    return { ok: false, reason: Rejection.badCertificate };
  }
  const authorId = (await sha256(rootPublicKey)).slice(0, AUTHOR_ID_BYTES);
  if (!bytesEqual(certificate.authorId, authorId)) {
    return { ok: false, reason: Rejection.badCertificate };
  }
  const certOk = await verifyEd25519(
    rootPublicKey,
    concat(TEXT_ENCODER.encode(CERT_DOMAIN), certificate.body),
    certificate.signature,
  );
  if (!certOk) return { ok: false, reason: Rejection.badCertificate };

  const descriptor = parseDescriptor(descriptorBytes);
  if (descriptor === null) {
    return { ok: false, reason: Rejection.unverifiedDescriptor };
  }
  if (!bytesEqual(descriptor.authorId, authorId)) {
    return { ok: false, reason: Rejection.unverifiedDescriptor };
  }
  const postOk = await verifyEd25519(
    certificate.publishingKey,
    concat(TEXT_ENCODER.encode(DESCRIPTOR_DOMAIN), descriptor.body),
    descriptor.signature,
  );
  if (!postOk) return { ok: false, reason: Rejection.unverifiedDescriptor };

  const committed = descriptor.commitments.get(LAYER_TEXT);
  if (!committed) return { ok: false, reason: Rejection.noTextLayer };
  if (!bytesEqual(await sha256(text), committed)) {
    return { ok: false, reason: Rejection.textDoesNotMatch };
  }

  // The signature is over bytes, not over readable text, and those bytes
  // may be a compressed payload this page has no decoder for. Saying so
  // is the honest outcome: the proof stands either way, and pretending to
  // read something unreadable would be the one failure a verifier must
  // never have.
  let readable = null;
  try {
    readable = new TextDecoder('utf-8', { fatal: true }).decode(text);
  } catch {
    readable = null;
  }

  return {
    ok: true,
    post: {
      authorId: toHex(authorId),
      rootPublicKey: toHex(rootPublicKey),
      seq: descriptor.seq,
      publishedAt: descriptor.publishedAt,
      text: readable,
      textIsReadable: readable !== null,
      textHash: toHex(await sha256(text)),
      textBytes: text.length,
      retracts: descriptor.retracts ? toHex(descriptor.retracts) : null,
      certificateFrom: certificate.notBefore,
      certificateUntil: certificate.notAfter,
    },
  };
}
