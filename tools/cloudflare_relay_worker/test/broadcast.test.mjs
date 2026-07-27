import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  BroadcastArchive,
  MAX_DESCRIPTOR_BYTES,
  MAX_OBJECT_BYTES,
  MAX_POSTS_PER_AUTHOR,
  RETENTION_MS,
  parseBroadcastPath,
  sha256Hex,
} from '../src/broadcast.js';

/** A stand-in for Durable Object storage: same async surface, plain Map. */
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

/** A clock the test moves by hand. */
function fakeClock(startMs) {
  const state = { ms: startMs };
  return {
    now: () => state.ms,
    advance: (by) => {
      state.ms += by;
    },
  };
}

const AUTHOR = '0102030405060708';

function archiveAt(clock) {
  return new BroadcastArchive(new FakeStorage(), { now: clock.now });
}

async function objectRoute(bytes) {
  const hash = await sha256Hex(bytes);
  return { kind: 'object', hash, shard: `o:${hash.slice(0, 2)}` };
}

function descriptorRoute(seq, authorId = AUTHOR) {
  return { kind: 'descriptor', authorId, seq, shard: `a:${authorId}` };
}

test('a descriptor path parses to its author, sequence and shard', () => {
  const route = parseBroadcastPath(`/a/${AUTHOR}/41`);
  assert.deepEqual(route, {
    kind: 'descriptor',
    authorId: AUTHOR,
    seq: 41,
    shard: `a:${AUTHOR}`,
  });
});

test('an object path shards by the first byte of its own hash', () => {
  const hash = 'ab'.padEnd(64, '0');
  const route = parseBroadcastPath(`/o/${hash}`);
  assert.equal(route.kind, 'object');
  assert.equal(route.hash, hash);
  assert.equal(route.shard, 'o:ab');
});

test('only one spelling of an address is accepted', () => {
  // A second name for the same bytes would split the cache and let one
  // post be served twice.
  for (const path of [
    `/a/${AUTHOR}/007`,
    `/a/${AUTHOR}/+7`,
    `/a/${AUTHOR}/ 7`,
    '/a/AABBCCDDEEFF0011/7',
    `/o/${'AB'.padEnd(64, '0')}`,
  ]) {
    assert.equal(parseBroadcastPath(path), null, `must refuse ${path}`);
  }
});

test('a non-broadcast or malformed path is not a broadcast path', () => {
  for (const path of [
    '/',
    '/ws',
    '/http',
    '/health',
    `/a/${AUTHOR}`,
    `/a/${AUTHOR}/1/2`,
    '/a/short/1',
    `/a/${AUTHOR}/4294967296`,
    `/a/${AUTHOR}/-1`,
    '/o/abc',
    `/o/${'0'.repeat(63)}`,
    `/b/${AUTHOR}/1`,
  ]) {
    assert.equal(parseBroadcastPath(path), null, `must refuse ${path}`);
  }
});

test('sequence zero and the maximum are both addressable', () => {
  assert.equal(parseBroadcastPath(`/a/${AUTHOR}/0`).seq, 0);
  assert.equal(parseBroadcastPath(`/a/${AUTHOR}/4294967295`).seq, 4294967295);
});

test('a stored descriptor reads back with an immutable cache directive',
  async () => {
    const clock = fakeClock(1_000_000);
    const archive = archiveAt(clock);
    const bytes = new Uint8Array([1, 2, 3, 4]);

    const write = await archive.handle(descriptorRoute(0), 'PUT', bytes);
    assert.equal(write.status, 201);

    const read = await archive.handle(descriptorRoute(0), 'GET', null);
    assert.equal(read.status, 200);
    assert.equal(
      read.headers.get('cache-control'),
      'public, max-age=31536000, immutable',
    );
    assert.deepEqual(new Uint8Array(await read.arrayBuffer()), bytes);
  });

test('a missing address is a 404, not an empty success', async () => {
  const archive = archiveAt(fakeClock(0));
  const read = await archive.handle(descriptorRoute(7), 'GET', null);
  assert.equal(read.status, 404);
});

test('HEAD answers without a body', async () => {
  const archive = archiveAt(fakeClock(0));
  await archive.handle(descriptorRoute(0), 'PUT', new Uint8Array([9]));
  const head = await archive.handle(descriptorRoute(0), 'HEAD', null);
  assert.equal(head.status, 200);
  assert.equal(head.headers.get('content-length'), '1');
  assert.equal((await head.arrayBuffer()).byteLength, 0);
});

test('an object must hash to the name it is filed under', async () => {
  const archive = archiveAt(fakeClock(0));
  const bytes = new Uint8Array([1, 2, 3]);
  const route = await objectRoute(bytes);

  const wrong = await archive.handle(route, 'PUT', new Uint8Array([4, 5, 6]));
  assert.equal(wrong.status, 400);

  const right = await archive.handle(route, 'PUT', bytes);
  assert.equal(right.status, 201);
});

test('a rewrite with identical bytes is a quiet retry', async () => {
  const archive = archiveAt(fakeClock(0));
  const bytes = new Uint8Array([1, 2, 3]);
  assert.equal(
    (await archive.handle(descriptorRoute(0), 'PUT', bytes)).status,
    201,
  );
  assert.equal(
    (await archive.handle(descriptorRoute(0), 'PUT', bytes)).status,
    204,
  );
});

test('a rewrite with different bytes is refused, so a fork stays visible',
  async () => {
    const archive = archiveAt(fakeClock(0));
    await archive.handle(descriptorRoute(0), 'PUT', new Uint8Array([1]));
    const conflict = await archive.handle(
      descriptorRoute(0),
      'PUT',
      new Uint8Array([2]),
    );
    assert.equal(conflict.status, 409);

    // The original is still what reads back.
    const read = await archive.handle(descriptorRoute(0), 'GET', null);
    assert.deepEqual(new Uint8Array(await read.arrayBuffer()), new Uint8Array([1]));
  });

test('an empty body is refused', async () => {
  const archive = archiveAt(fakeClock(0));
  const result = await archive.handle(
    descriptorRoute(0),
    'PUT',
    new Uint8Array(0),
  );
  assert.equal(result.status, 400);
});

test('an oversized descriptor is refused', async () => {
  const archive = archiveAt(fakeClock(0));
  const tooBig = new Uint8Array(MAX_DESCRIPTOR_BYTES + 1);
  const result = await archive.handle(descriptorRoute(0), 'PUT', tooBig);
  assert.equal(result.status, 413);
});

test('an oversized object is refused before it is hashed', async () => {
  const archive = archiveAt(fakeClock(0));
  const tooBig = new Uint8Array(MAX_OBJECT_BYTES + 1);
  const route = { kind: 'object', hash: '0'.repeat(64), shard: 'o:00' };
  const result = await archive.handle(route, 'PUT', tooBig);
  assert.equal(result.status, 413);
});

test('an object at exactly the limit is accepted', async () => {
  const archive = archiveAt(fakeClock(0));
  const bytes = new Uint8Array(MAX_OBJECT_BYTES).fill(7);
  const result = await archive.handle(await objectRoute(bytes), 'PUT', bytes);
  assert.equal(result.status, 201);
});

test('an unsupported method is refused', async () => {
  const archive = archiveAt(fakeClock(0));
  const result = await archive.handle(descriptorRoute(0), 'DELETE', null);
  assert.equal(result.status, 405);
});

test('an author is rate limited within one retention window', async () => {
  const archive = archiveAt(fakeClock(0));
  for (let seq = 0; seq < MAX_POSTS_PER_AUTHOR; seq += 1) {
    const result = await archive.handle(
      descriptorRoute(seq),
      'PUT',
      new Uint8Array([seq & 0xff, 1]),
    );
    assert.equal(result.status, 201, `post ${seq} should be accepted`);
  }
  const overflow = await archive.handle(
    descriptorRoute(MAX_POSTS_PER_AUTHOR),
    'PUT',
    new Uint8Array([1, 2]),
  );
  assert.equal(overflow.status, 429);
});

test('the rate limit resets with the window it belongs to', async () => {
  // Otherwise an author who published a lot once stays locked out long
  // after those posts have already been forgotten.
  const clock = fakeClock(0);
  const archive = archiveAt(clock);
  for (let seq = 0; seq < MAX_POSTS_PER_AUTHOR; seq += 1) {
    await archive.handle(descriptorRoute(seq), 'PUT', new Uint8Array([1, seq & 0xff]));
  }
  clock.advance(RETENTION_MS + 1);
  const after = await archive.handle(
    descriptorRoute(MAX_POSTS_PER_AUTHOR),
    'PUT',
    new Uint8Array([3]),
  );
  assert.equal(after.status, 201);
});

test('an entry past retention is gone, and a read does not resurrect it',
  async () => {
    const clock = fakeClock(0);
    const archive = archiveAt(clock);
    await archive.handle(descriptorRoute(0), 'PUT', new Uint8Array([1]));

    clock.advance(RETENTION_MS - 1);
    assert.equal(
      (await archive.handle(descriptorRoute(0), 'GET', null)).status,
      200,
      'still inside the window',
    );

    clock.advance(2);
    assert.equal(
      (await archive.handle(descriptorRoute(0), 'GET', null)).status,
      404,
      'past the window',
    );
  });

test('a sweep removes only what has expired', async () => {
  const clock = fakeClock(0);
  const archive = archiveAt(clock);
  await archive.handle(descriptorRoute(0), 'PUT', new Uint8Array([1]));
  clock.advance(RETENTION_MS - 1000);
  await archive.handle(descriptorRoute(1), 'PUT', new Uint8Array([2]));

  clock.advance(2000);
  assert.equal(await archive.sweep(), 1);
  assert.equal((await archive.handle(descriptorRoute(0), 'GET', null)).status, 404);
  assert.equal((await archive.handle(descriptorRoute(1), 'GET', null)).status, 200);
});

test('a sweep with nothing expired reports no work', async () => {
  const archive = archiveAt(fakeClock(0));
  await archive.handle(descriptorRoute(0), 'PUT', new Uint8Array([1]));
  assert.equal(await archive.sweep(), 0);
});

test('an expired address can be written again with different bytes',
  async () => {
    // Write-once holds for as long as the relay remembers, which is the
    // most it can honestly promise. Durability is the readers' job.
    const clock = fakeClock(0);
    const archive = archiveAt(clock);
    await archive.handle(descriptorRoute(0), 'PUT', new Uint8Array([1]));
    clock.advance(RETENTION_MS + 1);
    const again = await archive.handle(
      descriptorRoute(0),
      'PUT',
      new Uint8Array([2]),
    );
    assert.equal(again.status, 201);
  });

test('descriptors of two authors do not collide', async () => {
  const archive = archiveAt(fakeClock(0));
  const other = 'aabbccddeeff0011';
  await archive.handle(descriptorRoute(0), 'PUT', new Uint8Array([1]));
  const second = await archive.handle(
    descriptorRoute(0, other),
    'PUT',
    new Uint8Array([2]),
  );
  assert.equal(second.status, 201);
  const read = await archive.handle(descriptorRoute(0, other), 'GET', null);
  assert.deepEqual(new Uint8Array(await read.arrayBuffer()), new Uint8Array([2]));
});

test('sha256Hex matches the published digest of the empty input', async () => {
  assert.equal(
    await sha256Hex(new Uint8Array(0)),
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
  );
});
