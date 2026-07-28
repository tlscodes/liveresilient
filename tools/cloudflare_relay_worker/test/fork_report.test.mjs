/**
 * Fork reports on the relay.
 *
 * The point of the route is that it is open: anyone may publish evidence
 * that an author's key was duplicated, because the author is precisely the
 * party who may no longer be able to speak. That is safe for exactly one
 * reason — the report proves itself on the reader's side, so a false one
 * is bytes that fail on arrival and the relay needs no opinion about it.
 *
 * What the relay does enforce is what it can check without any key: the
 * report is filed under the hash of its own bytes, and one report never
 * overwrites another.
 */

import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  BroadcastArchive,
  MAX_FORK_REPORT_BYTES,
  parseBroadcastPath,
  sha256Hex,
} from '../src/broadcast.js';

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

const AUTHOR = 'd3c05ab2093cb220';

function archive() {
  return new BroadcastArchive(new FakeStorage(), { verify: async () => true });
}

async function routeFor(bytes) {
  const hash = await sha256Hex(bytes);
  return { kind: 'forkReport', authorId: AUTHOR, hash, shard: `f:${AUTHOR}` };
}

test('a fork report path parses to its author and its own hash', async () => {
  const hash = await sha256Hex(new Uint8Array([1]));
  const route = parseBroadcastPath(`/f/${AUTHOR}/${hash}`);
  assert.deepEqual(route, {
    kind: 'forkReport',
    authorId: AUTHOR,
    hash,
    shard: `f:${AUTHOR}`,
  });
});

test('a malformed fork path is not a route', async () => {
  const hash = await sha256Hex(new Uint8Array([1]));
  for (const path of [
    `/f/${AUTHOR}`,
    `/f/${AUTHOR}/short`,
    `/f/short/${hash}`,
    `/f/${AUTHOR}/${hash}/extra`,
    `/f/${AUTHOR.toUpperCase()}/${hash}`,
  ]) {
    assert.equal(parseBroadcastPath(path), null, `must refuse ${path}`);
  }
});

test('anyone may publish one — no credentials are asked for', async () => {
  // The whole reason the route exists. A report needs no permission
  // because it carries its own proof.
  const store = archive();
  const bytes = new Uint8Array([1, 2, 3, 4, 5]);
  const response = await store.handle(
    await routeFor(bytes),
    'PUT',
    bytes,
    undefined,
  );
  assert.equal(response.status, 201);
});

test('a report must hash to the name it is filed under', async () => {
  const store = archive();
  const bytes = new Uint8Array([1, 2, 3]);
  const response = await store.handle(
    await routeFor(bytes),
    'PUT',
    new Uint8Array([9, 9, 9]),
    undefined,
  );
  assert.equal(response.status, 400);
});

test('one report never overwrites another', async () => {
  // Two readers may witness different forks by the same author, and the
  // relay has no way to judge between them — so it keeps both.
  const store = archive();
  const first = new Uint8Array([1, 1, 1]);
  const second = new Uint8Array([2, 2, 2]);
  assert.equal(
    (await store.handle(await routeFor(first), 'PUT', first, undefined)).status,
    201,
  );
  assert.equal(
    (await store.handle(await routeFor(second), 'PUT', second, undefined))
      .status,
    201,
  );

  const readFirst = await store.handle(await routeFor(first), 'GET', null);
  const readSecond = await store.handle(await routeFor(second), 'GET', null);
  assert.deepEqual(new Uint8Array(await readFirst.arrayBuffer()), first);
  assert.deepEqual(new Uint8Array(await readSecond.arrayBuffer()), second);
});

test('a report reads back with the immutable cache directive', async () => {
  const store = archive();
  const bytes = new Uint8Array([7, 7]);
  await store.handle(await routeFor(bytes), 'PUT', bytes, undefined);
  const read = await store.handle(await routeFor(bytes), 'GET', null);
  assert.equal(read.status, 200);
  assert.equal(
    read.headers.get('cache-control'),
    'public, max-age=31536000, immutable',
  );
});

test('an oversized report is refused', async () => {
  const store = archive();
  const bytes = new Uint8Array(MAX_FORK_REPORT_BYTES + 1);
  const response = await store.handle(
    { kind: 'forkReport', authorId: AUTHOR, hash: '0'.repeat(64), shard: `f:${AUTHOR}` },
    'PUT',
    bytes,
    undefined,
  );
  assert.equal(response.status, 413);
});

test('reports do not collide with descriptors or objects', async () => {
  const store = archive();
  const bytes = new Uint8Array([4, 4, 4]);
  const hash = await sha256Hex(bytes);

  await store.handle(await routeFor(bytes), 'PUT', bytes, undefined);
  await store.handle(
    { kind: 'object', hash, shard: `o:${hash.slice(0, 2)}` },
    'PUT',
    bytes,
    undefined,
  );

  const asReport = await store.handle(await routeFor(bytes), 'GET', null);
  const asObject = await store.handle(
    { kind: 'object', hash, shard: `o:${hash.slice(0, 2)}` },
    'GET',
    null,
  );
  assert.equal(asReport.status, 200);
  assert.equal(asObject.status, 200);
});
