/**
 * The relay's side of the shared wire vectors.
 *
 * The Dart client generates `packages/broadcast/test/conformance/
 * wire_vectors.json` and checks itself against it; this checks the relay
 * against the very same bytes. Two implementations of one format drift
 * silently otherwise — nothing fails until a deployment mixes an old
 * reader with a new writer, which is the one moment nobody can debug it.
 *
 * What is verified here is specifically what the relay depends on: that it
 * parses the client's paths, finds the author id at the offset it expects
 * inside a real descriptor, and accepts a real credential blob built by
 * the client's own encoder.
 */

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import {
  AUTH_BYTES,
  BroadcastArchive,
  authorizeDescriptorWrite,
  parseBroadcastPath,
  sha256Hex,
} from '../src/broadcast.js';

const VECTORS = JSON.parse(
  readFileSync(
    new URL(
      '../../../packages/broadcast/test/conformance/wire_vectors.json',
      import.meta.url,
    ),
    'utf8',
  ),
);

function fromHex(hex) {
  return new Uint8Array(hex.match(/../g).map((pair) => parseInt(pair, 16)));
}

function toBase64Url(bytes) {
  let binary = '';
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

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

test('the vectors are a format version this relay speaks', () => {
  assert.equal(VECTORS.version, 1);
});

test('the author id is the truncated hash of the root key', async () => {
  // The relay derives this itself to authorize a write, so if the two
  // sides ever disagree about the derivation, every publish fails.
  const rootKey = fromHex(VECTORS.keys.rootPublicKeyHex);
  const hash = await sha256Hex(rootKey);
  assert.equal(hash.slice(0, 32), VECTORS.keys.authorIdHex);
});

test('the client paths are the paths this relay routes', () => {
  const descriptor = parseBroadcastPath(VECTORS.addresses.descriptorPath);
  assert.equal(descriptor?.kind, 'descriptor');
  assert.equal(descriptor.authorId, VECTORS.keys.authorIdHex);
  assert.equal(descriptor.seq, 41);
  assert.equal(descriptor.shard, `a:${VECTORS.keys.authorIdHex}`);

  const object = parseBroadcastPath(VECTORS.addresses.objectPath);
  assert.equal(object?.kind, 'object');
  assert.equal(object.shard, `o:${object.hash.slice(0, 2)}`);
});

test('the credential blob the client sends is the size this relay expects',
  () => {
    const blob = fromHex(VECTORS.keys.rootPublicKeyHex + VECTORS.certificate.encodedHex);
    assert.equal(blob.length, AUTH_BYTES);
    assert.equal(toBase64Url(blob), VECTORS.authHeader.value);
    assert.equal(VECTORS.authHeader.name, 'x-broadcast-auth');
  });

test('a real descriptor and credentials authorize a real write', async () => {
  // End to end across both languages: bytes the Dart encoder produced,
  // verified by the relay's own Ed25519 path with no stub anywhere.
  for (const record of VECTORS.descriptors) {
    const authorized = await authorizeDescriptorWrite({
      authorId: VECTORS.keys.authorIdHex,
      descriptor: fromHex(record.encodedHex),
      authHeader: VECTORS.authHeader.value,
    });
    assert.equal(authorized, true, `${record.name} must authorize`);
  }
});

test('the recorded descriptor lengths match the format the relay caps', () => {
  for (const record of VECTORS.descriptors) {
    assert.equal(fromHex(record.encodedHex).length, record.byteLength);
    // The relay's descriptor ceiling has to leave room for the largest
    // real descriptor, or a legitimate publish is refused.
    assert.ok(record.byteLength <= 512, `${record.name} fits the cap`);
  }
});

test('a real post is stored and read back byte for byte', async () => {
  const archive = new BroadcastArchive(new FakeStorage());
  const record = VECTORS.descriptors[1];
  const bytes = fromHex(record.encodedHex);
  const route = parseBroadcastPath(VECTORS.addresses.descriptorPath);

  const write = await archive.handle(
    route,
    'PUT',
    bytes,
    VECTORS.authHeader.value,
  );
  assert.equal(write.status, 201);

  const read = await archive.handle(route, 'GET', null);
  assert.equal(read.status, 200);
  assert.deepEqual(new Uint8Array(await read.arrayBuffer()), bytes);
  assert.equal(
    read.headers.get('cache-control'),
    VECTORS.addresses.immutableCacheControl,
  );
});

test('a descriptor from these vectors cannot be written to another author',
  async () => {
    const archive = new BroadcastArchive(new FakeStorage());
    const otherAuthor = 'aabbccddeeff0011aabbccddeeff0011';
    const response = await archive.handle(
      { kind: 'descriptor', authorId: otherAuthor, seq: 41, shard: `a:${otherAuthor}` },
      'PUT',
      fromHex(VECTORS.descriptors[1].encodedHex),
      VECTORS.authHeader.value,
    );
    assert.equal(response.status, 403);
  });
