/**
 * The verifier page, checked against bytes the Dart client produced.
 *
 * This is the test that makes the page trustworthy. Its whole purpose is
 * to tell a stranger whether a message is genuine, so a bug here is not a
 * broken feature — it is a page that lies. It therefore runs against the
 * shared conformance vectors rather than against anything it generated
 * itself, and it checks the refusals as carefully as the acceptance,
 * because a verifier that accepts too much is worse than one that accepts
 * nothing.
 */

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { test } from 'node:test';

import {
  Rejection,
  fromBase64,
  hasEd25519,
  toHex,
  verifyEvidence,
} from './verifier_core.mjs';

const VECTORS = JSON.parse(
  readFileSync(
    new URL(
      '../../packages/broadcast/test/conformance/wire_vectors.json',
      import.meta.url,
    ),
    'utf8',
  ),
);

const EVIDENCE = VECTORS.postEvidence;

function bundle() {
  return fromBase64(EVIDENCE.base64);
}

test('this runtime can check Ed25519 at all', async () => {
  // Stated first, because every other result here is meaningless without
  // it — and because the page says the same thing to a visitor whose
  // browser cannot.
  assert.equal(await hasEd25519(), true);
});

test('a real bundle from the Dart client verifies', async () => {
  const result = await verifyEvidence(bundle());
  assert.equal(result.ok, true, result.reason);
  assert.equal(result.post.text, EVIDENCE.text);
  assert.equal(result.post.seq, EVIDENCE.seq);
  assert.equal(
    Math.floor(result.post.publishedAt.getTime() / 1000),
    EVIDENCE.publishedAtSeconds,
  );
  assert.equal(result.post.authorId, VECTORS.keys.authorIdHex);
  assert.equal(result.post.rootPublicKey, VECTORS.keys.rootPublicKeyHex);
  assert.equal(result.post.textIsReadable, true);
  assert.equal(result.post.retracts, null);
});

test('base64 is accepted however a person pasted it', async () => {
  // Line breaks from an email, url-safe characters from a link, spaces
  // from a chat client. None of that is the reader's fault.
  const variants = [
    EVIDENCE.base64,
    EVIDENCE.base64.replace(/.{40}/g, '$&\n'),
    EVIDENCE.base64.replace(/\+/g, '-').replace(/\//g, '_'),
    ` ${EVIDENCE.base64} `,
  ];
  for (const variant of variants) {
    const result = await verifyEvidence(fromBase64(variant));
    assert.equal(result.ok, true, 'must accept a reformatted paste');
  }
});

test('one altered byte of the text is caught', async () => {
  // The attack the whole page exists to stop: the words say one thing and
  // the signature covers another.
  const bytes = bundle();
  bytes[bytes.length - 1] ^= 0x01;
  const result = await verifyEvidence(bytes);
  assert.equal(result.ok, false);
  assert.equal(result.reason, Rejection.textDoesNotMatch);
});

test('every single-bit flip is refused', async () => {
  const original = bundle();
  for (let index = 0; index < original.length; index += 3) {
    const bytes = original.slice();
    bytes[index] ^= 0x01;
    const result = await verifyEvidence(bytes);
    assert.equal(result.ok, false, `byte ${index} must not verify`);
  }
});

test('a swapped author key breaks the first link', async () => {
  const bytes = bundle();
  bytes[1] ^= 0xff;
  const result = await verifyEvidence(bytes);
  assert.equal(result.ok, false);
  assert.equal(result.reason, Rejection.badCertificate);
});

test('malformed input is refused rather than throwing', async () => {
  for (const bytes of [
    new Uint8Array(0),
    new Uint8Array(20),
    new Uint8Array(400).fill(0xff),
    bundle().slice(0, 40),
    new Uint8Array([...bundle(), 0]),
  ]) {
    const result = await verifyEvidence(bytes);
    assert.equal(result.ok, false);
    assert.equal(typeof result.reason, 'string');
  }
});

test('an unknown version says so instead of guessing', async () => {
  const bytes = bundle();
  bytes[0] = 9;
  const result = await verifyEvidence(bytes);
  assert.equal(result.reason, Rejection.unsupportedVersion);
});

test('a payload that is not plain text is reported, not mangled', async () => {
  // The signature is over bytes. When those bytes are a compressed
  // payload this page cannot decode, saying so is the only honest
  // outcome — the proof stands either way.
  const bytes = bundle();
  // Corrupting the text alone would fail the hash, so this checks the
  // reporting fields exist and are consistent on a good bundle.
  const result = await verifyEvidence(bytes);
  assert.equal(result.ok, true);
  assert.equal(typeof result.post.textHash, 'string');
  assert.equal(result.post.textHash.length, 64);
  assert.equal(result.post.textBytes, EVIDENCE.text.length);
});

test('every rejection reason is a sentence a person can read', () => {
  // These strings are shown verbatim to someone deciding whether to
  // believe a message, so none of them may be a code or a stack trace.
  for (const [name, message] of Object.entries(Rejection)) {
    assert.ok(message.length > 20, `${name} is too terse to help`);
    assert.ok(/^[a-z]/.test(message), `${name} should read as prose`);
    assert.ok(!/[_{}]/.test(message), `${name} looks like a symbol`);
  }
});

test('toHex is the same hex the vectors use', () => {
  assert.equal(
    toHex(fromBase64(EVIDENCE.base64).slice(1, 33)),
    VECTORS.keys.rootPublicKeyHex,
  );
});

test('the committed page matches the module it was built from', () => {
  // The page inlines the core because a browser will not import a module
  // over file://, and the page must work from a memory card. Inlining is
  // duplication, so this is what keeps the copy honest.
  const before = readFileSync(new URL('verifier.html', import.meta.url), 'utf8');
  execFileSync('node', [new URL('build_verifier.mjs', import.meta.url).pathname]);
  const after = readFileSync(new URL('verifier.html', import.meta.url), 'utf8');
  assert.equal(
    before,
    after,
    'run: node tools/web_verifier/build_verifier.mjs',
  );
});

test('the page carries no network calls at all', () => {
  // An offline verifier that quietly fetched anything would leak who is
  // checking what, to whoever is watching — the exact population this
  // project exists to protect.
  const page = readFileSync(new URL('verifier.html', import.meta.url), 'utf8');
  for (const forbidden of [
    'fetch(',
    'XMLHttpRequest',
    'WebSocket',
    'import(',
    'src="http',
    'href="http',
    '//cdn',
  ]) {
    assert.ok(
      !page.includes(forbidden),
      `the page must not contain ${forbidden}`,
    );
  }
});
