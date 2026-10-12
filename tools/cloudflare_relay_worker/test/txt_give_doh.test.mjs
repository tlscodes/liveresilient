import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { _internals } from '../src/txt_give_doh.js';

const {
  GiveState,
  parseQueryName,
  b32decode,
  frameUp,
  unframeUp,
  encodeGiveResponse,
  decodeGiveRequest,
  DOWNSTREAM_BUDGET,
} = _internals;

const here = dirname(fileURLToPath(import.meta.url));
const fixture = JSON.parse(readFileSync(join(here, 'give_fixture.json'), 'utf8'));

const NOW = 1000;

function hexToBytes(h) {
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.substr(i * 2, 2), 16);
  return out;
}
function b64ToBytes(s) {
  const bin = Buffer.from(s, 'base64');
  return new Uint8Array(bin);
}
function eqBytes(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

// Walk a DNS answer packet exactly as the Python codec writes it:
// header(12) | question(name + qtype/qclass) | [answer owner-ptr(2)+type/class/ttl/rdlen(10)+rdata] | OPT.
// Returns the concatenated TXT rdata payload, or null when ancount==0.
function answerTxtPayload(pkt) {
  const an = (pkt[6] << 8) | pkt[7];
  // skip question name from offset 12
  let pos = 12;
  for (;;) {
    const len = pkt[pos];
    if (len === 0) {
      pos += 1;
      break;
    }
    if ((len & 0xc0) === 0xc0) {
      pos += 2;
      break;
    }
    pos += 1 + len;
  }
  pos += 4; // qtype + qclass
  if (an === 0) return null;
  // answer rr: owner(2 ptr) type(2) class(2) ttl(4) rdlen(2)
  pos += 2 + 2 + 2 + 4;
  const rdlen = (pkt[pos] << 8) | pkt[pos + 1];
  pos += 2;
  const rdata = pkt.subarray(pos, pos + rdlen);
  // concat the 255-byte TXT strings
  const out = [];
  let p = 0;
  while (p < rdata.length) {
    const l = rdata[p];
    p += 1;
    for (let i = 0; i < l; i++) out.push(rdata[p + i]);
    p += l;
  }
  return new Uint8Array(out);
}

test('base32 and query-name parse match the Python wire', () => {
  // "0" decodes to empty; a known vector round-trips through the fixture names.
  assert.equal(b32decode('0').length, 0);
  const first = fixture.cases[0];
  // reconstruct the DNS name from the first query packet and parse it
  const pkt = hexToBytes(first.queries[0]);
  // name starts at offset 12; decode labels to a dotted string
  let pos = 12;
  const labels = [];
  for (;;) {
    const len = pkt[pos];
    if (len === 0) break;
    labels.push(String.fromCharCode(...pkt.subarray(pos + 1, pos + 1 + len)));
    pos += 1 + len;
  }
  const parsed = parseQueryName(labels.join('.'));
  assert.equal(parsed.sessionId, first.session);
  assert.equal(parsed.seq, 0);
});

test('frame round-trips', () => {
  const body = new Uint8Array([1, 2, 3, 4, 5]);
  assert.ok(eqBytes(unframeUp(frameUp(body)), body));
  assert.ok(eqBytes(unframeUp(frameUp(new Uint8Array(0))), new Uint8Array(0)));
});

const jsAnswers = { cases: [] };

for (const c of fixture.cases) {
  test(`give exchange: ${c.name}`, async () => {
    const give = new GiveState();
    let seenReq = null;
    const relayBody = b64ToBytes(c.relay_body_b64);
    const forward = async (req) => {
      seenReq = req;
      return { status: c.relay_status, body: relayBody };
    };

    const recorded = []; // answer packet hexes, for the cross-direction python check

    // 1) send every uplink chunk in order; each answers with empty downstream
    for (const qhex of c.queries) {
      const ans = await give.handle(hexToBytes(qhex), forward, NOW);
      recorded.push(Buffer.from(ans).toString('hex'));
      const payload = answerTxtPayload(ans);
      assert.ok(payload !== null, 'chunk answer has a TXT record');
      // a chunk-carrying query returns the pre-response (empty) frame
      assert.equal(unframeUp(payload).length, 0, 'chunk answer downstream is empty');
    }

    // 2) the relay replay must have seen the exact reassembled request
    assert.ok(seenReq, 'forward was called once reassembly completed');
    assert.equal(seenReq.method === 1 ? 'GET' : 'PUT', c.expect.method);
    assert.equal(seenReq.path, c.expect.path);
    assert.ok(eqBytes(seenReq.body, b64ToBytes(c.expect.body_b64)), 'give body reassembled byte-for-byte');
    for (const [k, v] of Object.entries(c.expect.headers)) {
      assert.equal(seenReq.headers[k], v, `give header ${k}`);
    }

    // 3) drain the downstream over polls until the full give response is read
    const expected = b64ToBytes(c.give_response_b64);
    const acc = [];
    let polls = 0;
    const pollPkt = hexToBytes(c.poll);
    while (acc.length < expected.length) {
      polls += 1;
      assert.ok(polls < 20, 'downstream drains in a bounded number of polls');
      const ans = await give.handle(pollPkt, forward, NOW);
      recorded.push(Buffer.from(ans).toString('hex'));
      const frame = answerTxtPayload(ans);
      const slice = unframeUp(frame);
      assert.ok(slice.length <= DOWNSTREAM_BUDGET, 'no poll exceeds the downstream budget');
      for (const b of slice) acc.push(b);
    }
    const accBytes = new Uint8Array(acc);
    assert.ok(eqBytes(accBytes, expected), `downstream == give response envelope (${c.name})`);

    // 4) the response envelope itself must decode to the relay's status+body
    assert.deepEqual([accBytes[0], accBytes[1]], [0x67, 0x31], "'g1' response magic");
    const status = (accBytes[2] << 8) | accBytes[3];
    assert.equal(status, c.relay_status, 'decoded give status');
    const blen = (accBytes[4] << 24) | (accBytes[5] << 16) | (accBytes[6] << 8) | accBytes[7];
    assert.equal(blen, relayBody.length, 'decoded give body length');
    assert.ok(eqBytes(accBytes.subarray(8), relayBody), 'decoded give body bytes');

    // a multi-poll case must genuinely have spanned more than one poll
    if (expected.length > DOWNSTREAM_BUDGET) assert.ok(polls > 1, 'large downstream spanned >1 poll');

    jsAnswers.cases.push({ name: c.name, answers: recorded });
  });
}

test('emit JS answers for the cross-direction Python check', () => {
  writeFileSync(join(here, 'js_answers.json'), JSON.stringify(jsAnswers));
});

// a non-valve name must be refused with NXDOMAIN, not swallowed
test('non-valve query name -> NXDOMAIN', async () => {
  const give = new GiveState();
  // build a minimal TXT query for "www.example.com"
  const name = 'www.example.com';
  const labels = name.split('.');
  const q = [0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01];
  for (const l of labels) {
    q.push(l.length);
    for (const ch of l) q.push(ch.charCodeAt(0));
  }
  q.push(0, 0x00, 0x10, 0x00, 0x01); // qtype TXT, qclass IN
  const ans = await give.handle(new Uint8Array(q), async () => ({ status: 200, body: new Uint8Array(0) }), NOW);
  assert.equal(ans[3] & 0x0f, 3, 'rcode NXDOMAIN');
});
