// Silent-push module: JWT, request shape, register → fire. No live APNs.
import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';

import {
  apnsJwt,
  backgroundPushRequest,
  handlePushShard,
  parsePushPath,
  _test,
} from '../src/apns_push.js';

const subtle = webcrypto.subtle;

async function freshKey() {
  const pair = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const der = new Uint8Array(await subtle.exportKey('pkcs8', pair.privateKey));
  const b64 = Buffer.from(der).toString('base64').replace(/(.{64})/g, '$1\n');
  return { pem: `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`, pub: pair.publicKey };
}

function fromB64url(s) {
  return new Uint8Array(Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64'));
}

class MemStorage {
  constructor() { this.m = new Map(); }
  async get(k) { return this.m.get(k); }
  async put(k, v) { this.m.set(k, v); }
}

test('path parse: author, probe, refusals', () => {
  const a = 'ab'.repeat(16);
  assert.deepEqual(parsePushPath(`/p/${a}`), { kind: 'push', authorId: a, shard: `p:${a}` });
  assert.deepEqual(parsePushPath('/p/probe'), { kind: 'probe' });
  assert.equal(parsePushPath('/p/XYZ'), null);
  assert.equal(parsePushPath(`/p/${a}/x`), null);
  assert.equal(parsePushPath(`/a/${a}`), null);
});

test('JWT: ES256 header, claims, verifiable 64-byte signature, cached', async () => {
  _test.resetJwtCache();
  const { pem, pub } = await freshKey();
  const env = { APNS_KEY_P8: pem, APNS_KEY_ID: 'KEY1234567', APNS_TEAM_ID: 'TEAM123456' };
  const now = 1_790_000_000_000;
  const jwt = await apnsJwt(env, now, subtle);
  const [h, c, s] = jwt.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(fromB64url(h)).toString()), { alg: 'ES256', kid: 'KEY1234567' });
  assert.deepEqual(JSON.parse(Buffer.from(fromB64url(c)).toString()), { iss: 'TEAM123456', iat: now / 1000 });
  const sig = fromB64url(s);
  assert.equal(sig.length, 64);
  const ok = await subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, pub, sig, new TextEncoder().encode(`${h}.${c}`));
  assert.equal(ok, true);
  assert.equal(await apnsJwt(env, now + 39 * 60_000, subtle), jwt, 'reused inside 40 min');
  assert.notEqual(await apnsJwt(env, now + 41 * 60_000, subtle), jwt, 'renewed after 40 min');
});

test('background push request: headers and body', () => {
  const { url, init } = backgroundPushRequest('J', 'aa'.repeat(32), 'sandbox');
  assert.equal(url, `https://api.sandbox.push.apple.com/3/device/${'aa'.repeat(32)}`);
  assert.equal(init.headers['apns-push-type'], 'background');
  assert.equal(init.headers['apns-priority'], '5');
  assert.equal(init.headers['apns-topic'], 'com.tlscodes.referenceApp');
  assert.equal(init.headers.authorization, 'bearer J');
  assert.deepEqual(JSON.parse(init.body), { aps: { 'content-available': 1 } });
  assert.match(backgroundPushRequest('J', 'aa', 'production').url, /^https:\/\/api\.push\.apple\.com\//);
});

test('shard: register, GET hides the token, fire records push_last', async () => {
  _test.resetJwtCache();
  const { pem } = await freshKey();
  const env = { APNS_KEY_P8: pem, APNS_KEY_ID: 'K', APNS_TEAM_ID: 'T' };
  const st = new MemStorage();
  const a = 'cd'.repeat(16);
  const token = 'ef'.repeat(32);
  const none = await handlePushShard(new Request('https://x/__push_fire', { method: 'POST' }), st, env);
  assert.deepEqual(await none.json(), { fired: false });
  const bad = await handlePushShard(
    new Request(`https://x/p/${a}`, { method: 'PUT', body: '{"token":"nothex"}' }), st, env);
  assert.equal(bad.status, 400);
  const reg = await handlePushShard(
    new Request(`https://x/p/${a}`, { method: 'PUT', body: JSON.stringify({ token, env: 'sandbox' }) }), st, env);
  assert.equal(reg.status, 201);
  const sent = [];
  const fakeFetch = async (url, init) => {
    sent.push({ url, init });
    return new Response('', { status: 200, headers: { 'apns-id': 'ID-1' } });
  };
  const fired = await handlePushShard(
    new Request('https://x/__push_fire', { method: 'POST' }), st, env, Date.now(), fakeFetch);
  const fj = await fired.json();
  assert.equal(fj.fired, true);
  assert.equal(fj.last.status, 200);
  assert.equal(fj.last.apns_id, 'ID-1');
  assert.equal(sent.length, 1);
  assert.ok(sent[0].url.endsWith(token));
  const view = await handlePushShard(new Request(`https://x/p/${a}`), st, env);
  const vt = await view.text();
  assert.ok(!vt.includes(token), 'GET never shows the token');
  assert.equal(JSON.parse(vt).registered, true);
  // Expired registration does not fire.
  const late = await handlePushShard(
    new Request('https://x/__push_fire', { method: 'POST' }), st, env, Date.now() + 5 * 86400_000, fakeFetch);
  assert.deepEqual(await late.json(), { fired: false });
  assert.equal(sent.length, 1);
});
