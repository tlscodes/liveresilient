/**
 * The long-poll ceiling is drawn per request, uniformly from
 * [15000, 25000] ms, via the session's injectable `random` source.
 * These tests stub that source and capture the wait value handed to
 * `waitForFrames`, so nothing here ever actually sleeps.
 */

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { RelaySession } from '../src/worker.js';

const MIN_CEILING_MS = 15_000;
const MAX_CEILING_MS = 25_000;

function sessionCapturing(randomSource) {
  const session = new RelaySession({});
  session.random = randomSource;
  const captured = [];
  session.waitForFrames = (_role, wait) => {
    captured.push(wait);
    return Promise.resolve();
  };
  return { session, captured };
}

function pollUrl(waitMs) {
  return new URL(`https://relay.test/http?session=s1&role=a&wait=${waitMs}`);
}

test('per-request ceiling stays within [15000, 25000] over many draws and never exceeds 25000', async () => {
  // A deterministic sweep of the unit interval, including both edges.
  const draws = [];
  for (let i = 0; i <= 1000; i++) draws.push(i / 1000);
  draws.push(0.999999999, Math.nextafter ? Math.nextafter(1, 0) : 1 - 1e-16);

  for (const r of draws) {
    const { session, captured } = sessionCapturing(() => r);
    // Request far above any possible ceiling so the drawn ceiling wins.
    await session.handlePoll(pollUrl(10_000_000), 'a');
    assert.equal(captured.length, 1);
    const ceiling = captured[0];
    assert.ok(
      ceiling >= MIN_CEILING_MS,
      `ceiling ${ceiling} below ${MIN_CEILING_MS} for draw ${r}`,
    );
    assert.ok(
      ceiling <= MAX_CEILING_MS,
      `ceiling ${ceiling} above ${MAX_CEILING_MS} for draw ${r}`,
    );
  }
});

test('a requested wait of 5000 is honored unchanged regardless of the draw', async () => {
  for (const r of [0, 0.25, 0.5, 0.75, 1 - 1e-16]) {
    const { session, captured } = sessionCapturing(() => r);
    await session.handlePoll(pollUrl(5000), 'a');
    assert.deepEqual(captured, [5000]);
  }
});
