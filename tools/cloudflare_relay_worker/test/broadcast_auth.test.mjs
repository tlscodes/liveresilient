/**
 * The relay holds no keys and knows no authors, yet it can still refuse a
 * descriptor write from anyone but the author — the credentials carry the
 * whole chain and every link is checkable from the bytes.
 *
 * These run against real Ed25519 keys through WebCrypto, and the byte
 * layouts are built independently of the Dart encoder, so a drift between
 * the two formats fails here.
 */

import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  AUTH_BYTES,
  BroadcastArchive,
  authorizeDescriptorWrite,
} from '../src/broadcast.js';
import {
  authHeader,
  generateKeyPair,
  makeCertificate,
  newAuthor,
} from './authorization.mjs';

class FakeStorage {
  constructor() {
    this.map = new Map();
  }

  async get(key) {
    return this.map.get(key);
  }

  async put(key, value) {
    this.map.set(key, value);
  }

  async delete(key) {
    return this.map.delete(key);
  }

  async list() {
    return new Map(this.map);
  }
}

function route(authorId, seq = 0) {
  return { kind: 'descriptor', authorId, seq, shard: `a:${authorId}` };
}

test('the author can write their own descriptor', async () => {
  const author = await newAuthor();
  const archive = new BroadcastArchive(new FakeStorage());
  const response = await archive.handle(
    route(author.authorId),
    'PUT',
    await author.descriptor(),
    author.header,
  );
  assert.equal(response.status, 201);
});

test('a write with no credentials is refused', async () => {
  const author = await newAuthor();
  const archive = new BroadcastArchive(new FakeStorage());
  const response = await archive.handle(
    route(author.authorId),
    'PUT',
    await author.descriptor(),
    undefined,
  );
  assert.equal(response.status, 403);
});

test('nobody can squat an author future sequence numbers', async () => {
  // The attack write-once made possible: one byte at each of an author's
  // coming addresses locks them for the whole retention window, and the
  // real author can never publish there.
  const victim = await newAuthor();
  const attacker = await newAuthor();
  const archive = new BroadcastArchive(new FakeStorage());

  for (const seq of [0, 1, 2, 41]) {
    const squat = await archive.handle(
      route(victim.authorId, seq),
      'PUT',
      new Uint8Array([1]),
      attacker.header,
    );
    assert.equal(squat.status, 403, `seq ${seq} must be refused`);
  }

  // And the address is still free for its owner.
  const genuine = await archive.handle(
    route(victim.authorId, 41),
    'PUT',
    await victim.descriptor({ seq: 41 }),
    victim.header,
  );
  assert.equal(genuine.status, 201);
});

test('another author credentials do not authorize this path', async () => {
  const victim = await newAuthor();
  const attacker = await newAuthor();
  const archive = new BroadcastArchive(new FakeStorage());
  const response = await archive.handle(
    route(victim.authorId),
    'PUT',
    await attacker.descriptor(),
    attacker.header,
  );
  assert.equal(response.status, 403);
});

test('a descriptor signed by an undelegated key is refused', async () => {
  // Correct root key, correct certificate, but the descriptor was signed
  // by some other key.
  const author = await newAuthor();
  const impostor = await generateKeyPair();
  const archive = new BroadcastArchive(new FakeStorage());
  const forged = await author.descriptor();
  const withOtherSigner = await (async () => {
    const rebuilt = await newAuthor();
    // Reuse the victim's author id in the body but sign with a key their
    // certificate does not name.
    const body = forged.subarray(0, forged.length - 64);
    const signature = new Uint8Array(
      await crypto.subtle.sign(
        'Ed25519',
        impostor.privateKey,
        new Uint8Array([
          ...new TextEncoder().encode('vck/broadcast/descriptor/v1\n'),
          ...body,
        ]),
      ),
    );
    void rebuilt;
    return new Uint8Array([...body, ...signature]);
  })();

  const response = await archive.handle(
    route(author.authorId),
    'PUT',
    withOtherSigner,
    author.header,
  );
  assert.equal(response.status, 403);
});

test('a certificate signed by the wrong root is refused', async () => {
  const author = await newAuthor();
  const stranger = await generateKeyPair();
  // A certificate naming this author, signed by somebody else's root.
  const forgedCert = await makeCertificate({
    root: { privateKey: stranger.privateKey, publicKey: author.root.publicKey },
    publishingPublicKey: author.publishing.publicKey,
  });
  const archive = new BroadcastArchive(new FakeStorage());
  const response = await archive.handle(
    route(author.authorId),
    'PUT',
    await author.descriptor(),
    authHeader(author.root.publicKey, forgedCert),
  );
  assert.equal(response.status, 403);
});

test('a tampered descriptor body is refused', async () => {
  const author = await newAuthor();
  const archive = new BroadcastArchive(new FakeStorage());
  const descriptor = await author.descriptor();
  descriptor[20] ^= 0xff;
  const response = await archive.handle(
    route(author.authorId),
    'PUT',
    descriptor,
    author.header,
  );
  assert.equal(response.status, 403);
});

test('a malformed credential blob is refused without throwing', async () => {
  const author = await newAuthor();
  const archive = new BroadcastArchive(new FakeStorage());
  for (const header of ['', 'not base64!!', 'AAAA', 'a'.repeat(400)]) {
    const response = await archive.handle(
      route(author.authorId),
      'PUT',
      await author.descriptor(),
      header,
    );
    assert.equal(response.status, 403, `must refuse ${header.slice(0, 12)}`);
  }
});

test('the credential blob is a fixed size', async () => {
  const author = await newAuthor();
  assert.equal(author.root.publicKey.length + author.certificate.length, AUTH_BYTES);
  assert.equal(AUTH_BYTES, 147);
});

test('object writes need no credentials, because the name proves them', async () => {
  // An object is filed under the hash of its own bytes, so there is
  // nothing an attacker can put there that is not exactly what the name
  // says. Requiring a signature would add a key to a path that does not
  // need one.
  const archive = new BroadcastArchive(new FakeStorage());
  const bytes = new Uint8Array([1, 2, 3, 4]);
  const { sha256Hex } = await import('../src/broadcast.js');
  const hash = await sha256Hex(bytes);
  const response = await archive.handle(
    { kind: 'object', hash, shard: `o:${hash.slice(0, 2)}` },
    'PUT',
    bytes,
    undefined,
  );
  assert.equal(response.status, 201);
});

test('authorizeDescriptorWrite reports false rather than throwing', async () => {
  const author = await newAuthor();
  assert.equal(
    await authorizeDescriptorWrite({
      authorId: author.authorId,
      descriptor: new Uint8Array(3),
      authHeader: author.header,
    }),
    false,
  );
});
