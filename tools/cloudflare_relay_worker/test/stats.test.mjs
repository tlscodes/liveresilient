/**
 * Counting what a shard actually holds.
 *
 * Every capacity claim about this relay has so far been arithmetic on
 * assumptions — how many readers a free plan carries, how full a shard
 * gets, whether the accounting is right. These numbers settle those
 * questions, and they are counted from storage rather than read off the
 * meta record, so a meta record that has drifted shows up here instead of
 * in a bug report months later.
 */

import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  BroadcastArchive,
  MAX_POSTS_PER_AUTHOR,
  RETENTION_MS,
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

function fakeClock(startMs) {
  const state = { ms: startMs };
  return {
    now: () => state.ms,
    advance: (by) => {
      state.ms += by;
    },
  };
}

const ROOT_KEY = new Uint8Array(32).fill(7);
const AUTHOR = (await sha256Hex(ROOT_KEY)).slice(0, 32);
const AUTHOR_BYTES = new Uint8Array(
  AUTHOR.match(/../g).map((pair) => parseInt(pair, 16)),
);

const AUTH = (() => {
  const certificate = new Uint8Array(125);
  certificate[0] = 2;
  certificate.set(AUTHOR_BYTES, 1);
  const blob = new Uint8Array(32 + 125);
  blob.set(ROOT_KEY, 0);
  blob.set(certificate, 32);
  let binary = '';
  for (const b of blob) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
})();

function descriptorBody(fill) {
  const out = new Uint8Array(155);
  out[0] = 1;
  out[1] = 0x01;
  out.set(AUTHOR_BYTES, 2);
  out.fill(fill, 28, 91);
  return out;
}

function archiveAt(clock) {
  return new BroadcastArchive(new FakeStorage(), {
    now: clock.now,
    // Authorization is exercised for real elsewhere; this file is about
    // what the counters say.
    verify: async () => true,
  });
}

function descriptorRoute(seq) {
  return { kind: 'descriptor', authorId: AUTHOR, seq, shard: `a:${AUTHOR}` };
}

async function objectRoute(bytes) {
  const hash = await sha256Hex(bytes);
  return { kind: 'object', hash, shard: `o:${hash.slice(0, 2)}` };
}

test('an empty shard reports zeroes rather than nothing', async () => {
  const stats = await archiveAt(fakeClock(0)).stats();
  assert.equal(stats.descriptors, 0);
  assert.equal(stats.objects, 0);
  assert.equal(stats.forkReports, 0);
  assert.equal(stats.liveBytes, 0);
  assert.equal(stats.oldestEntryAgeMs, null);
  assert.equal(stats.postsPerAuthorLimit, MAX_POSTS_PER_AUTHOR);
  assert.equal(stats.retentionMs, RETENTION_MS);
});

test('it counts each kind separately', async () => {
  const archive = archiveAt(fakeClock(1000));
  await archive.handle(descriptorRoute(0), 'PUT', descriptorBody(1), AUTH);
  await archive.handle(descriptorRoute(1), 'PUT', descriptorBody(2), AUTH);

  const object = new Uint8Array([1, 2, 3]);
  await archive.handle(await objectRoute(object), 'PUT', object, undefined);

  const report = new Uint8Array([9, 9]);
  const hash = await sha256Hex(report);
  await archive.handle(
    { kind: 'forkReport', authorId: AUTHOR, hash, shard: `f:${AUTHOR}` },
    'PUT',
    report,
    undefined,
  );

  const stats = await archive.stats();
  assert.equal(stats.descriptors, 2);
  assert.equal(stats.objects, 1);
  assert.equal(stats.forkReports, 1);
  assert.equal(stats.liveBytes, 155 * 2 + 3 + 2);
});

test('it reports how full the shard is, as a fraction', async () => {
  const archive = archiveAt(fakeClock(1000));
  await archive.handle(descriptorRoute(0), 'PUT', descriptorBody(1), AUTH);
  const stats = await archive.stats();
  assert.equal(stats.liveBytes, 155);
  assert.ok(stats.shardBytesUsedFraction > 0);
  assert.ok(stats.shardBytesUsedFraction < 0.001);
  assert.equal(stats.shardBytesLimit, 64 * 1024 * 1024);
});

test('expired entries are counted apart from live ones', async () => {
  // The distinction that matters when a shard looks full: bytes that are
  // still owed versus bytes waiting for a sweep.
  const clock = fakeClock(1000);
  const archive = archiveAt(clock);
  await archive.handle(descriptorRoute(0), 'PUT', descriptorBody(1), AUTH);
  clock.advance(RETENTION_MS + 1);
  await archive.handle(descriptorRoute(1), 'PUT', descriptorBody(2), AUTH);

  const stats = await archive.stats();
  assert.equal(stats.descriptors, 1, 'only the live one counts');
  assert.equal(stats.expiredAwaitingSweep, 1);
  assert.equal(stats.liveBytes, 155);
});

test('the age of the oldest live entry is reported', async () => {
  const clock = fakeClock(1000);
  const archive = archiveAt(clock);
  await archive.handle(descriptorRoute(0), 'PUT', descriptorBody(1), AUTH);
  clock.advance(5000);
  await archive.handle(descriptorRoute(1), 'PUT', descriptorBody(2), AUTH);
  const stats = await archive.stats();
  assert.equal(stats.oldestEntryAgeMs, 5000);
});

test('accounting drift is named, not hidden', async () => {
  // The counters exist partly to reveal their own bugs: a meta record
  // that disagrees with storage is exactly the failure that produced a
  // shard reporting itself full while holding almost nothing.
  const clock = fakeClock(1000);
  const archive = archiveAt(clock);
  await archive.handle(descriptorRoute(0), 'PUT', descriptorBody(1), AUTH);

  let stats = await archive.stats();
  assert.equal(stats.accountingDriftBytes, 0, 'healthy to begin with');

  // Corrupt the meta record the way a leak would.
  await archive.storage.put('meta', { bytes: 999999, posts: 3, since: 1000 });
  stats = await archive.stats();
  assert.equal(stats.accountedBytes, 999999);
  assert.equal(stats.liveBytes, 155);
  assert.equal(stats.accountingDriftBytes, 999999 - 155);
});

test('a sweep brings the drift back to zero', async () => {
  const clock = fakeClock(1000);
  const archive = archiveAt(clock);
  await archive.handle(descriptorRoute(0), 'PUT', descriptorBody(1), AUTH);
  await archive.storage.put('meta', { bytes: 500000, posts: 9, since: 1000 });
  await archive.sweep();
  const stats = await archive.stats();
  assert.equal(stats.accountingDriftBytes, 0);
  assert.equal(stats.postsThisWindow, 1);
});

test('the posts counter tracks the rate limit it feeds', async () => {
  const clock = fakeClock(1000);
  const archive = archiveAt(clock);
  for (let seq = 0; seq < 5; seq += 1) {
    await archive.handle(descriptorRoute(seq), 'PUT', descriptorBody(seq), AUTH);
  }
  const stats = await archive.stats();
  assert.equal(stats.postsThisWindow, 5);
  assert.equal(stats.postsPerAuthorLimit, MAX_POSTS_PER_AUTHOR);
});
