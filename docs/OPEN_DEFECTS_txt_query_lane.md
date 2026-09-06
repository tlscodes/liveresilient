# Open defects — the TXT query lane, found 2026-09-07

Six defects in `packages/adaptive_transport/lib/src/resilient/txt_query_*.dart`, found by the
suites written for those files on 2026-09-07 and recorded there as commented-out failing cases
with their measured evidence. None is fixed. This file is the ready patch: each entry carries
the anchor, the measurement, the fix, and the tests that must move with it.

**Why they are not fixed here.** Four of the fixes were applied and verified locally, then
reverted, because a repository guard blocks a fifth edit to one file inside a single working
phase and the remaining work was test-expectation updates that could not land without it. The
tree is therefore at the last fully green state — `dart test` in `packages/adaptive_transport`
reports 717 passed, 2 skipped — rather than half-fixed. The whole set below is a single
sitting's work when applied in one pass.

**Apply them together.** Defect 3 changes a constant that
`test/resilient/txt_query_wire_test.dart` pins against golden vectors generated from
`tools/t2/txt_query_wire.py`, and that Python module carries the same defect with the same
number. Fixing one side alone turns the byte-identity test red — which is exactly what it is
for, and it did catch this within one run.

---

## 1. `parseQueryName` never pins the seq label width

`txt_query_wire.dart:263-278`. The parser pins the session label and the nonce label but not
`head[1]`, so `'aab'`, `'b'` and `'ab'` all decode to sequence 1, and `''` decodes to 0,
aliasing `'aa'`. Two names can then claim the same chunk of one payload; reassembly either
raises a conflict or silently accepts the wrong bytes. Pinning the width is the same protection
the two neighbouring labels already have.

**Fix** — beside the existing session/nonce check:

```dart
if (head[1].length != seqChars) {
  throw TxtQueryWireException(
    'seq label "${head[1]}" is ${head[1].length} chars, want $seqChars',
  );
}
```

**Tests that move with it.** `test/txt_query_wire_test.dart`, case
`an empty interior label parses, though no builder emits one` — it pins today's behaviour and
becomes a refusal case.

## 2. `buildQueryName` builds names its own parser refuses

`txt_query_wire.dart:228-256`. Every label is checked for emptiness and the 63-octet ceiling,
but the session and nonce labels are never checked against `sessionChars` / `nonceChars`, which
`parseQueryName` requires. Measured: `buildQueryName([], 0, 'ABC23', '7XYZ', 'valve.example')`
yields `q.AA.ABC23.7XYZ.0.tunnel.valve.example`, which `parseQueryName` then rejects with
`session/nonce width`. `encodeQueries` passes `sessionId` straight through, so a caller reusing
an id from anywhere but `newSessionId` emits a whole batch of names the far side drops — and it
surfaces as silence, not as an error.

**Fix** — before the label loop, two width checks mirroring the parser's, each naming the value
and both widths.

**Tests that move with it.** `an empty or over-long label is refused` expects `bad label ""` for
an empty session id; the new check fires first with a more specific message.

## 3. `downstreamBudget` does not fit inside `ednsUdpSize`

`txt_query_wire.dart:60-62` and `:487-520`. The doc says 1150 is "kept under `ednsUdpSize` with
room for the question, the TXT record header and the OPT record". It is not: `buildDnsAnswerPacket`
writes the owner name twice uncompressed — once for the question and again for the answer record —
and the budget accounts for neither copy.

```
measured, payload at the budget, three realistic names
  1256, 1292 and 1398 octets   against the 1232 the query itself advertised
                               24 to 166 octets over
```

1232 is the RFC 9715 figure that keeps an answer inside the common 1280-octet IPv6 MTU, so going
over is the fragmentation the number exists to prevent — on exactly the links this lane is for.

**Fix, in two parts.** First, the answer record's owner name becomes a compression pointer to the
question name at offset 12 (`0xC0 0x0C`, RFC 1035 §4.1.4). Both parsers already follow pointers —
Dart at `_decodeName`, Python at `txt_query_wire.py:244` — so this is compatible in every
direction. Second, the budget becomes arithmetic rather than an assertion:

```
   12  header
 + L+2 question owner name (a presentation name of L characters is L+2 octets
       on the wire: one length octet per label, plus the root)
 +   4 qtype and qclass
 +  12 answer record: 2-octet pointer, type, class, ttl, rdlength
 +   R TXT rdata: the framed payload in 255-octet strings, each with its own
       length octet
 +  11 OPT record
 <= 1232
```

With `L = fqdnMax = 253` that leaves 938 octets for R; R carries the 2-octet frame header as
well, so the payload ceiling is **932**, not 1150. A `maxDownstreamPayloadFor(String
questionName)` gives a caller that knows its own name the several hundred octets a short zone
earns back, and `frameDown` should take an optional `questionName` so that room is usable — with
the constant remaining the safe default for a caller that does not know the name.

**Tests that move with it.**
- `the downstream budget is a hard edge` hardcodes `'downstream 1151 > 1150'`; it should read the
  constant instead of a literal, which is why it broke on a legitimate change.
- Two new properties are worth adding: an answer built at `maxDownstreamPayloadFor(name)` is
  `<= ednsUdpSize` for a short, a long and an at-the-limit name; and the constant equals the
  derived room at the worst possible name. (A name at the FQDN limit must be built from labels of
  at most 63 characters — `'x' * 253` is one illegal label, not a legal name.)
- `test/resilient/txt_query_wire_test.dart`: `an answer is byte-identical to the Python packet`
  and `a compressed answer name is followed, not mistaken for data` both move when the Python
  responder changes.

**The Python half.** `tools/t2/txt_query_wire.py:35` carries `DOWNSTREAM_BUDGET = 1150` and the
same double name write. Both sides change together, and the golden vectors are regenerated from
the Python module afterwards. A constant duplicated in two languages is the thing that drifts;
if one formula can serve both, that is the better shape.

## 4. The caller's `timeout` is applied three times over

`txt_query_transport.dart:160, 165, 166`. `exchange` applies the same timeout to `postUrl`, to
`request.close()` and to reading the body, so one call can take nearly three times its budget,
while the interface promises a `TimeoutException` "inside [timeout]" at `:20-24`. `TxtQueryLane`
hands every attempt the same single `_timeout` at `:258`, so a DoH transport can hold the lane
about three times as long as the lane budgeted — on a link where the whole point is a bounded
failure window.

```
measured   2800 ms elapsed against a 1000 ms budget
```

**Fix** — one deadline for the whole exchange: take `DateTime.now().add(timeout)` once and give
each stage the remaining time, or wrap the whole future in a single `.timeout(timeout)`.

## 5. A failing status is reported only after the whole body is spent

`txt_query_transport.dart:166-172`. The entire body is collected before `response.statusCode` is
read, so a 502 whose body never ends costs the full caller budget and surfaces
`TimeoutException('doh:... body timed out')` instead of the `HttpException` the status check
exists to produce. An endpoint refusing service is precisely the one most likely to hang its
body.

```
measured   failure still null at 1 ms, TimeoutException at 2 s
```

**Fix** — check the status as soon as the response headers arrive, and drain or abort the body
on a failing status instead of collecting it first.

## 6. `parseResolvConf` dedupes on spelling, not on address

`txt_query_transport.dart:269-272`. Entries are validated with `InternetAddress.tryParse` but
stored and deduped as `address.address`, and on this SDK that returns the exact string it parsed
for every accepted form. So `2001:0DB8:0000:...:0053`, `2001:DB8::53` and the same address in
another spelling all survive as separate resolvers, and the lane spends attempts on one endpoint
believing it is several.

**Fix** — dedupe on the parsed `InternetAddress` (its `rawAddress` bytes, or the canonical form),
not on the text.

---

## What the suites still do not cover

Recorded so the next reader knows where the floor is, not as a promise to fix.

- **`Udp53QueryTransport` has no injection seam.** It binds a real `RawDatagramSocket` at `:61`
  while its sibling `DohQueryTransport` takes an `HttpClient`. So the source-address filter, the
  short-datagram guard, the transaction-id demux, the short-send path, dispose-with-pending-waiters,
  resolver caching and the bind choice are all untested. One constructor parameter would change
  that, and it is the single highest-value change in this file.
- **`TxtQueryLane` calls `DateTime.now()` directly** at `:214, :247, :279`, so the failure-window
  slide is pinned only at zero and at long windows, and `rttMs` on a delivered send can be
  asserted present but never pinned.
- **`forValve`'s discovery branch** reads the host's `resolv.conf` when no resolvers are given, so
  the discovered order is unpinned; every case passes explicit candidates.
- **Answer/query size agreement is unpinned end to end**: `_optRecord`'s `udpPayloadSize` is only
  ever called with its default and `parseDnsQueryPacket` never reads it back.
- **`parseDnsQueryPacket` never inspects the flags word**, so a response parses as a query.
