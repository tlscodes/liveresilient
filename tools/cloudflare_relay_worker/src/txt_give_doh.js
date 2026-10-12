/**
 * The `give` lane, as a DoH (RFC 8484) endpoint on the existing relay.
 *
 * A locked phone whose only reachable path is its own resolver carries the
 * SAME relay GET/PUT over DNS-over-HTTPS: it POSTs (or GETs `?dns=`) an
 * ordinary DNS/TXT query whose name encodes one chunk of a `give` request,
 * polls for the answer, and the relay replays the request against its own
 * broadcast routes and queues the answer back down the lane.
 *
 * This is a byte-for-byte port of the two proven Python pieces:
 *   - tools/t2/txt_query_wire.py   (the DNS/TXT wire codec)
 *   - tools/t2/txt_query_server.py (reassembly, the downstream queue, probes)
 *   - tools/t2/txt_give.py         (the give envelope + relay replay)
 * The Dart client (DohQueryTransport + TxtLaneBroadcastTransport) is already
 * proven against that Python server, so mirroring it exactly is what makes
 * the client work against the relay with no client change.
 *
 * It opens no port 53, invents no domain, and reaches only this relay's own
 * origin: the give path is relative and a scheme/host in it is refused, so
 * the lane is never an open proxy. All state is in memory in one singleton
 * Durable Object — the same shape as the single-process Python responder, and
 * a give exchange lasts seconds, well inside a warm object's life.
 */

// ---- constants, from txt_query_wire.py (do not change without the Python) ----
const LABEL_MARKER = 'q';
const LABEL_TUNNEL = 'tunnel';
const SEQ_CHARS = 2;
const SESSION_CHARS = 6;
const NONCE_CHARS = 4;
const SEQ_MAX = 1023;
const POLL_SEQ = SEQ_MAX; // a query at this seq is a read-only poll; stores nothing
const FRAME_HDR = 2;
const QTYPE_TXT = 16;
const QCLASS_IN = 1;
const OPT_TYPE = 41;
const EDNS0_UDP_SIZE = 1232;
const RCODE_NOERROR = 0;
const RCODE_NXDOMAIN = 3;
const RCODE_REFUSED = 5;
const RCODE_SERVFAIL = 2;

// ANSWER_FIXED_OCTETS = 12 (header) + 4 (qtype/qclass) + 12 (answer rr w/ ptr) + 11 (OPT)
const ANSWER_FIXED_OCTETS = 12 + 4 + 12 + 11;
const FQDN_MAX = 253;
// DOWNSTREAM_BUDGET: the constant the Python server uses for both the slice
// size and frame_down(down) (its _handle passes question_name=None). Derived
// at the FQDN_MAX worst case so it holds for every legal question name.
const _WORST_CASE_RDATA_ROOM = EDNS0_UDP_SIZE - ANSWER_FIXED_OCTETS - (FQDN_MAX + 2);
const DOWNSTREAM_BUDGET =
  _WORST_CASE_RDATA_ROOM - Math.ceil(_WORST_CASE_RDATA_ROOM / 256) - FRAME_HDR; // 932

// Session lifetime, mirroring TxtQueryServer defaults.
const SESSION_TTL_MS = 60_000;
const MAX_SESSION_AGE_MS = 300_000;

// give envelope magics (txt_give.py)
const GIVE_GET = 1;
const GIVE_PUT = 2;
const REQ_MAGIC = [0x47, 0x31]; // 'G1'
const RESP_MAGIC = [0x67, 0x31]; // 'g1'
const RELAY_UNREACHABLE = 502;
const FORWARD_HEADERS = ['x-broadcast-auth'];

// path probe (TxtLetterProbe). payload "PRB1" + group(8) + nonce(8).
const PROBE_MAGIC = [0x50, 0x52, 0x42, 0x31]; // 'PRB1'
const PROBE_ID = 8;
const MAX_PROBE_GROUPS = 4096;

const B32ALPH = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

class WireError extends Error {}

// ---- small byte helpers ----
function u16(n) {
  return [(n >>> 8) & 0xff, n & 0xff];
}
function u32(n) {
  return [(n >>> 24) & 0xff, (n >>> 16) & 0xff, (n >>> 8) & 0xff, n & 0xff];
}
function readU16(b, o) {
  return (b[o] << 8) | b[o + 1];
}
function concatBytes(arrays) {
  let total = 0;
  for (const a of arrays) total += a.length;
  const out = new Uint8Array(total);
  let off = 0;
  for (const a of arrays) {
    out.set(a, off);
    off += a.length;
  }
  return out;
}
function bytesEqual(a, start, lit) {
  for (let i = 0; i < lit.length; i++) if (a[start + i] !== lit[i]) return false;
  return true;
}

// ---- Base32 (RFC 4648, unpadded, case-insensitive); "0" means empty ----
function b32decode(text) {
  const up = text.toUpperCase();
  if (up === '0') return new Uint8Array(0);
  let bits = 0;
  let value = 0;
  const out = [];
  for (const ch of up) {
    const idx = B32ALPH.indexOf(ch);
    if (idx < 0) throw new WireError(`bad Base32 char ${ch}`);
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.push((value >>> bits) & 0xff);
    }
  }
  return new Uint8Array(out);
}
function decodeInt(label) {
  let n = 0;
  for (const ch of label.toUpperCase()) {
    const idx = B32ALPH.indexOf(ch);
    if (idx < 0) throw new WireError(`illegal Base32 char ${ch}`);
    n = (n << 5) | idx;
  }
  return n;
}

// ---- DNS name codec ----
function encodeName(name) {
  const out = [];
  for (const label of name.split('.')) {
    if (!label) continue;
    const raw = [];
    for (let i = 0; i < label.length; i++) {
      const c = label.charCodeAt(i);
      if (c > 0x7f) throw new WireError(`non-ASCII label ${label}`);
      raw.push(c);
    }
    if (raw.length > 63) throw new WireError(`label too long ${label}`);
    out.push(raw.length, ...raw);
  }
  out.push(0);
  return new Uint8Array(out);
}

function decodeName(buf, offset, depth = 0) {
  if (depth > 10) throw new WireError('compression loop');
  const labels = [];
  let pos = offset;
  let jumped = false;
  let end = offset;
  for (;;) {
    if (pos >= buf.length) throw new WireError('name past end');
    const length = buf[pos];
    if (length === 0) {
      if (!jumped) end = pos + 1;
      break;
    }
    if ((length & 0xc0) === 0xc0) {
      if (pos + 1 >= buf.length) throw new WireError('truncated pointer');
      const target = ((length & 0x3f) << 8) | buf[pos + 1];
      if (!jumped) end = pos + 2;
      jumped = true;
      const [inner] = decodeName(buf, target, depth + 1);
      labels.push(inner);
      break;
    }
    if (length & 0xc0) throw new WireError('bad label type');
    pos += 1;
    if (pos + length > buf.length) throw new WireError('label past end');
    let s = '';
    for (let i = 0; i < length; i++) {
      const c = buf[pos + i];
      if (c > 0x7f) throw new WireError('non-ASCII label');
      s += String.fromCharCode(c);
    }
    labels.push(s);
    pos += length;
    if (!jumped) end = pos;
  }
  return [labels.join('.'), end];
}

function optRr() {
  // 0x00 owner, then type(41) class(=udp size) ttl(0) rdlen(0)
  return new Uint8Array([0x00, ...u16(OPT_TYPE), ...u16(EDNS0_UDP_SIZE), ...u32(0), ...u16(0)]);
}

function parseDnsQueryPacket(packet) {
  if (packet.length < 12) throw new WireError('short header');
  const txid = readU16(packet, 0);
  const qdcount = readU16(packet, 4);
  if (qdcount !== 1) throw new WireError(`qdcount ${qdcount}`);
  const [name, pos] = decodeName(packet, 12);
  if (pos + 4 > packet.length) throw new WireError('truncated question');
  const qtype = readU16(packet, pos);
  const qclass = readU16(packet, pos + 2);
  if (qtype !== QTYPE_TXT || qclass !== QCLASS_IN) {
    throw new WireError(`expected TXT/IN got ${qtype}/${qclass}`);
  }
  return { txid, name };
}

function txtRdata(payload) {
  if (!payload.length) return new Uint8Array([0x00]);
  const out = [];
  for (let i = 0; i < payload.length; i += 255) {
    const piece = payload.subarray(i, i + 255);
    out.push(piece.length, ...piece);
  }
  return new Uint8Array(out);
}

function buildDnsAnswerPacket(txid, questionName, payload, rcode = RCODE_NOERROR) {
  const flags = 0x8400 | (rcode & 0x0f); // QR + AA
  const ancount = payload !== null && rcode === RCODE_NOERROR ? 1 : 0;
  const header = new Uint8Array([...u16(txid & 0xffff), ...u16(flags), ...u16(1), ...u16(ancount), ...u16(0), ...u16(1)]);
  const question = concatBytes([encodeName(questionName), new Uint8Array([...u16(QTYPE_TXT), ...u16(QCLASS_IN)])]);
  let answer = new Uint8Array(0);
  if (ancount) {
    const rdata = txtRdata(payload || new Uint8Array(0));
    // RFC 1035 4.1.4: owner name is a pointer back to the question at offset 12.
    const owner = new Uint8Array([0xc0, 0x0c]);
    answer = concatBytes([
      owner,
      new Uint8Array([...u16(QTYPE_TXT), ...u16(QCLASS_IN), ...u32(0), ...u16(rdata.length)]),
      rdata,
    ]);
  }
  return concatBytes([header, question, answer, optRr()]);
}

// ---- query name -> {seq, session, nonce, chunk}; domain-agnostic ----
// Structure is fixed: q.<seq2>.<session6>.<nonce4>.<payload>.tunnel.<domain...>
// so the five head labels and the fixed 'tunnel' separator are located by
// position, never by searching (a 6-char session can itself read as 'tunnel').
function parseQueryName(name) {
  const parts = name
    .toLowerCase()
    .replace(/^\.+|\.+$/g, '')
    .split('.');
  if (parts.length < 7) throw new WireError(`not a valve name: ${name}`);
  if (parts[0] !== LABEL_MARKER || parts[5] !== LABEL_TUNNEL) {
    throw new WireError(`not a valve name: ${name}`);
  }
  const seqL = parts[1];
  const sessionId = parts[2];
  const nonce = parts[3];
  const payloadL = parts[4];
  if (seqL.length !== SEQ_CHARS) throw new WireError(`seq label width ${seqL.length}`);
  if (sessionId.length !== SESSION_CHARS || nonce.length !== NONCE_CHARS) {
    throw new WireError('session/nonce width');
  }
  const seq = decodeInt(seqL);
  if (seq > SEQ_MAX) throw new WireError(`seq ${seq} out of range`);
  return { seq, sessionId, nonce, chunk: b32decode(payloadL) };
}

// ---- frames ----
function frameUp(payload) {
  if (payload.length > 0xffff) throw new WireError('payload exceeds u16');
  return concatBytes([new Uint8Array(u16(payload.length)), payload]);
}
function unframeUp(framed) {
  if (framed.length < FRAME_HDR) throw new WireError('truncated frame');
  const n = readU16(framed, 0);
  const body = framed.subarray(FRAME_HDR);
  if (body.length < n) throw new WireError(`incomplete frame have=${body.length} want=${n}`);
  return body.subarray(0, n);
}

// ---- give envelope (txt_give.py) ----
function decodeGiveRequest(payload) {
  if (payload.length < 5 || !bytesEqual(payload, 0, REQ_MAGIC)) {
    throw new WireError('not a give request');
  }
  const method = payload[2];
  if (method !== GIVE_GET && method !== GIVE_PUT) throw new WireError(`unknown method ${method}`);
  const pathLen = readU16(payload, 3);
  let pos = 5;
  if (payload.length < pos + pathLen + 1) throw new WireError('truncated path');
  const path = utf8Decode(payload.subarray(pos, pos + pathLen));
  pos += pathLen;
  const hdrCount = payload[pos];
  pos += 1;
  const headers = {};
  for (let i = 0; i < hdrCount; i++) {
    if (payload.length < pos + 1) throw new WireError('truncated header name length');
    const nl = payload[pos];
    pos += 1;
    if (payload.length < pos + nl + 2) throw new WireError('truncated header name');
    const nm = asciiDecode(payload.subarray(pos, pos + nl)).toLowerCase();
    pos += nl;
    const vl = readU16(payload, pos);
    pos += 2;
    if (payload.length < pos + vl) throw new WireError('truncated header value');
    headers[nm] = utf8Decode(payload.subarray(pos, pos + vl));
    pos += vl;
  }
  return { method, path, headers, body: payload.subarray(pos) };
}

function encodeGiveResponse(status, body) {
  return concatBytes([new Uint8Array(RESP_MAGIC), new Uint8Array(u16(status)), new Uint8Array(u32(body.length)), body]);
}

const _utf8 = new TextDecoder('utf-8');
function utf8Decode(bytes) {
  return _utf8.decode(bytes);
}
function asciiDecode(bytes) {
  let s = '';
  for (const c of bytes) s += String.fromCharCode(c);
  return s;
}

// ---- the stateful responder (port of TxtQueryServer + the give drain) ----
//
// `forward(req)` is injected so this class stays free of any runtime: the unit
// test passes a stub, the Durable Object passes the real relay replay.
export class GiveState {
  constructor() {
    this.sessions = new Map(); // id -> {chunks: Map<seq,Uint8Array>, created, lastSeen}
    this.down = new Map(); // id -> Uint8Array queued downstream
    this.probes = new Map(); // group(hex) -> [nonce(hex), ...]
  }

  _gc(now) {
    for (const [id, buf] of this.sessions) {
      if (now - buf.lastSeen > SESSION_TTL_MS || now - buf.created > MAX_SESSION_AGE_MS) {
        this.sessions.delete(id);
      }
    }
  }

  _tryAssemble(buf) {
    const head = buf.chunks.get(0);
    if (!head || head.length < FRAME_HDR) return null;
    const need = FRAME_HDR + readU16(head, 0);
    const parts = [];
    let have = 0;
    for (let i = 0; i <= SEQ_MAX; i++) {
      if (have >= need) break;
      const chunk = buf.chunks.get(i);
      if (chunk === undefined) return null;
      parts.push(chunk);
      have += chunk.length;
    }
    if (have < need) return null;
    try {
      return unframeUp(concatBytes(parts).subarray(0, need));
    } catch (e) {
      if (e instanceof WireError) return null;
      throw e;
    }
  }

  _probeReply(payload) {
    if (payload.length !== 4 + 2 * PROBE_ID || !bytesEqual(payload, 0, PROBE_MAGIC)) return null;
    const group = payload.subarray(4, 4 + PROBE_ID);
    const nonce = payload.subarray(4 + PROBE_ID);
    const gk = hex(group);
    const nk = hex(nonce);
    let seen = this.probes.get(gk);
    if (seen === undefined) {
      if (this.probes.size >= MAX_PROBE_GROUPS) this.probes.delete(this.probes.keys().next().value);
      seen = [];
      this.probes.set(gk, seen);
    }
    if (!seen.includes(nk)) seen.push(nk);
    const rank = seen.indexOf(nk) + 1;
    const winner = unhex(seen[0]);
    return concatBytes([new Uint8Array(PROBE_MAGIC), group, winner, new Uint8Array([Math.min(rank, 255)])]);
  }

  _queueDown(id, payload) {
    const existing = this.down.get(id);
    this.down.set(id, existing ? concatBytes([existing, payload]) : payload);
  }

  _takeDown(id) {
    const d = this.down.get(id);
    this.down.delete(id);
    return d || new Uint8Array(0);
  }

  /**
   * One DoH query packet in, one DoH answer packet out. `forward` is only ever
   * awaited AFTER the answer to return has been captured, so a chunk-carrying
   * query answers with the pre-existing downstream (empty for a fresh give) and
   * the give response is drained by the client's following polls — exactly the
   * order the Python server+serve loop produced.
   */
  async handle(packet, forward, now) {
    let q;
    try {
      q = parseDnsQueryPacket(packet);
    } catch (e) {
      if (e instanceof WireError) {
        return buildDnsAnswerPacket(packet.length >= 2 ? readU16(packet, 0) : 0, '', null, RCODE_SERVFAIL);
      }
      throw e;
    }
    let parsed;
    try {
      parsed = parseQueryName(q.name);
    } catch (e) {
      if (e instanceof WireError) return buildDnsAnswerPacket(q.txid, q.name, null, RCODE_NXDOMAIN);
      throw e;
    }

    this._gc(now);
    const id = parsed.sessionId;
    let pendingGive = null;

    if (parsed.seq !== POLL_SEQ) {
      let buf = this.sessions.get(id);
      if (buf === undefined) {
        buf = { chunks: new Map(), created: now, lastSeen: now };
        this.sessions.set(id, buf);
      }
      buf.chunks.set(parsed.seq, parsed.chunk);
      buf.lastSeen = now;
      const assembled = this._tryAssemble(buf);
      if (assembled !== null) {
        const probe = this._probeReply(assembled);
        if (probe !== null) {
          // a path probe: queued now, returned in THIS answer
          this._queueDown(id, probe);
        } else {
          let req = null;
          try {
            req = decodeGiveRequest(assembled);
          } catch (e) {
            if (!(e instanceof WireError)) throw e;
            // not a give request: ignored (no downstream), like the Python drain
          }
          if (req !== null) pendingGive = req;
        }
        this.sessions.delete(id);
      }
    }

    // Capture the answer to return BEFORE the give is forwarded/queued, so the
    // completing chunk returns empty and the response waits for the next poll.
    let down = this._takeDown(id);
    if (down.length > DOWNSTREAM_BUDGET) {
      const leftover = down.subarray(DOWNSTREAM_BUDGET);
      down = down.subarray(0, DOWNSTREAM_BUDGET);
      const rest = this._takeDown(id);
      this._queueDown(id, concatBytes([leftover, rest]));
    }

    if (pendingGive !== null) {
      const { status, body } = await this._replay(pendingGive, forward);
      this._queueDown(id, encodeGiveResponse(status, body));
    }

    return buildDnsAnswerPacket(q.txid, q.name, frameUp(down));
  }

  async _replay(req, forward) {
    // Only path+query are honored; a scheme or host in the path is refused, so
    // the lane can never be aimed anywhere but this relay (txt_give.forward).
    if (/^[a-z][a-z0-9+.-]*:/i.test(req.path) || req.path.startsWith('//')) {
      throw new WireError('path must be relative to the relay');
    }
    try {
      return await forward(req);
    } catch {
      return { status: RELAY_UNREACHABLE, body: new Uint8Array(0) };
    }
  }
}

function hex(bytes) {
  let s = '';
  for (const b of bytes) s += b.toString(16).padStart(2, '0');
  return s;
}
function unhex(s) {
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(s.substr(i * 2, 2), 16);
  return out;
}

// ---- base64url for the DoH GET ?dns= form ----
function base64urlDecode(s) {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4);
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// ---- entry point used by worker.js ----
export async function handleDnsQuery(request, env) {
  const url = new URL(request.url);
  let packet;
  if (request.method === 'POST') {
    packet = new Uint8Array(await request.arrayBuffer());
  } else if (request.method === 'GET') {
    const dns = url.searchParams.get('dns');
    if (!dns) {
      return new Response('dns-query expects a ?dns= query or an application/dns-message POST\n', {
        status: 400,
        headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' },
      });
    }
    try {
      packet = base64urlDecode(dns);
    } catch {
      return new Response('bad ?dns= base64url\n', { status: 400, headers: { 'content-type': 'text/plain; charset=utf-8' } });
    }
  } else {
    return new Response('method not allowed\n', { status: 405 });
  }
  // One singleton object holds all give state, like the single Python process.
  const id = env.GIVE_SESSION.idFromName('txt-give-v1');
  const inner = new Request('https://give.internal/handle', {
    method: 'POST',
    body: packet,
    headers: { 'x-relay-origin': url.origin },
  });
  return env.GIVE_SESSION.get(id).fetch(inner);
}

/**
 * The singleton Durable Object: one live GiveState and the real relay replay.
 * The replay is a subrequest to this relay's own origin, which re-enters the
 * worker and routes the give's broadcast path to the archive object — the
 * in-process equivalent of txt_give replaying over HTTP against the relay base.
 */
export class GiveSession {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.give = new GiveState();
  }

  async fetch(request) {
    const origin = request.headers.get('x-relay-origin') || new URL(request.url).origin;
    const packet = new Uint8Array(await request.arrayBuffer());
    const now = Date.now();
    const answer = await this.give.handle(packet, (req) => this._forward(origin, req), now);
    return new Response(answer, {
      status: 200,
      headers: { 'content-type': 'application/dns-message', 'cache-control': 'no-store' },
    });
  }

  async _forward(origin, req) {
    const target = new URL(req.path, origin);
    const method = req.method === GIVE_PUT ? 'PUT' : 'GET';
    const headers = {};
    for (const name of FORWARD_HEADERS) {
      if (req.headers[name]) headers[name] = req.headers[name];
    }
    // Cloudflare rejects some default agents before the worker sees them.
    headers['user-agent'] = 'voice-call-kit-give/1';
    const init = { method, headers };
    if (method === 'PUT') init.body = req.body;
    const resp = await fetch(target, init);
    const body = new Uint8Array(await resp.arrayBuffer());
    return { status: resp.status, body };
  }
}

// Exposed for the unit test; not part of the worker's public surface.
export const _internals = {
  GiveState,
  parseQueryName,
  parseDnsQueryPacket,
  buildDnsAnswerPacket,
  decodeGiveRequest,
  encodeGiveResponse,
  frameUp,
  unframeUp,
  b32decode,
  DOWNSTREAM_BUDGET,
  POLL_SEQ,
};
