# The blackout gate: from 34-68 % to ≥ 90 % window utilization — the plan and its gates

State on 2026-09-05 (commits f365b24, b512976): a signed queue of 20 bundles (411,600 B) crosses
four 90 s windows shaped at 16 kbit/s with per-window utilization 34.0 / 59.8 / 44.3 / 67.5 %
(self-test, 0.221 h). The hours-scale run (20-40 min cuts) reproduced window 1 exactly:
15 bundles, 76,600 B, 34.1 %. A 16 kbit/s window of 90 s is 180,000 B; the measured open time is
~112 s because the close is a shape call after a 1 s poll, so the denominator is the measured
open time.

Every step below is one rig run away from a number. The measurement is the same each time:
`JOURNEY_BLACKOUT_V=2 tools/t2/journey_run.sh blackout` (self-test flags:
`JOURNEY_BLACKOUT_MIN_M=1 JOURNEY_BLACKOUT_MAX_M=2 JOURNEY_BLACKOUT_WINDOWS=4`), the row
`blackout_gate` and its `util=` list. Read the failure before designing the fix.

## Step 0 — measure where the 66 % went (evidence first, no edits)
From tools/dossier/logs/journey/blackout.phone.jsonl and blackout.hub.log of the self-test:
- probe latency: first `bundle_received.received_ms` minus the window's open time (≤ 2 s expected);
- per-bundle cost: 15 small bundles in window 1 took ~112 s for 76,600 B ⇒ ~5 s per bundle at
  ~5.1 KB each, while 76,600 B at 2,000 B/s is 38 s — so ~74 s of window 1 was per-request
  overhead (TCP handshake + slow start + one round trip per POST on an inflated pipe);
- chunk cost: window 3 carried one 100,000 B video in 13 chunks of 8,192 B: 100 KB at 2,000 B/s
  is 50 s; the window's measured open time was 112 s ⇒ ~60 s of request overhead.
Measured 2026-09-05 (self-test run 07:15:44Z, from blackout.phone.jsonl + blackout.hub.log lines 28-131):

| window | bytes | ideal s (bytes/2000) | measured s | overhead s | requests (whole+have+chunk) | s per request |
|---|---|---|---|---|---|---|
| 1 | 76,600 | 38.3 | 112.6 | 74.3 | 29 (14+2+13) | 2.56 |
| 2 | 135,000 | 67.5 | 112.9 | 45.4 | 24 (0+4+20) | 1.89 |
| 3 | 100,000 | 50.0 | 112.8 | 62.8 | 22 (0+2+20) | 2.85 |
| 4 | 100,000 | 50.0 | 74.1 | 24.1 | 14 (0+1+13) | 1.72 |
| all | 411,600 | 205.8 | 412.4 | 206.6 | 89 (14+9+66) | 2.32 |

Reading (bytes/measured s from the TSV row, timestamps from the phone jsonl, requests from the hub log; "inferred" marks a derivation):
- Windows: received_ms clusters with gaps > 45 s at events 15|16 (167.3 s), 18|19 (179.7 s), 19|20 (214.7 s); cluster bytes 76,600 / 135,000 / 100,000 / 100,000 match window_bytes. Requests come from walking the hub log in arrival order: a `GET /health` lands only while a window is open, so the four probes (file lines 36, 66, 91, 114; line 29 is the runner's own check) mark the window starts. Chunk splits inferred from that: a578 all 8 chunks in W1 (lines 51-59); 86f7 chunks 0-4 in W1 (60-65) and 5-7 in W2 after a fresh `/have` (67-70); fb89 and c605 whole in W2 (71-88); f6e3 chunk 0 in W2 (89-90) and 1-16 in W3 (92-108); 0a94 chunks 0-3 in W3 (109-113) and 4-16 in W4 (115-128). 14 + 9 + 66 = 89.
- The overhead column is three things. (a) Credit shift: W1 carried 40,960 B of 86f7 (+20.5 s) it is not credited for; W3 carried 32,768 B of 0a94 (+16.4 s) and inherited 8,192 B of f6e3 from W2; the shifts sum to zero. (b) Envelope inflation: chunks=8 for 45,000 B and chunks=17 for 100,000 B at chunk_bytes=8192 mean envelopes of 57,345-65,536 B and 131,073-139,264 B, i.e. ~4/3 of payload, and `ended.wire_bytes`=553,764 vs bytes=411,600 (x1.345) says the same — inferred, the encoding itself is not in the inputs. That is 68.6 s of the 412.4 s at 2,000 B/s. (c) The rest is idle pipe: 41.1 / 39.3 / 33.8 / 23.8 s = 138.0 s over 89 requests, 1.55 s per request (W1 1.42, W2 1.64, W3 1.54, W4 1.70).
- The per-request cost is visible raw in the phone timestamps: the eight 200-B bundles landed 0.70-0.92 s apart against ≤ 0.25 s of transfer (~0.6 s fixed per POST); the 5,000-B bundles 4.0-4.7 s apart against 3.3 s (one outlier, 87a9, 8.5 s); each 45,000-B chunked bundle (a578, fb89, c605) took 44.2-44.8 s for ~60,000 wire B (30 s), i.e. ~14.5 s over 9 requests, 1.6 s per chunk request — a chunk request costs about twice a whole-bundle POST.
- The probe is not the story: 4 of 67 probes reached, probe_s=2, so ≤ 8 s of 412.4 s (< 2 %). The first-byte delay by the stated method (open = first received_ms minus the bundle's own transfer time) is circular and gives 0.1 s for W1; the usable bound is: armed at created_ms 1788592549563, first bundle at 1788592613757 (64.2 s later) with cuts of ≥ 60 s, so W1's first byte came ≤ ~4 s after open (inferred). Inferred opens after armed: W1 ≈ +64 s, W2 ≈ +296 s, W3 ≈ +492 s, W4 ≈ +723 s; the four inferred cuts sum to ~384 s vs cut_total_s=375 (±3 s per boundary).
- What dominates on the 412.4 s of open pipe: payload 205.8 s (49.9 %), per-request idle 138.0 s (33.5 %), envelope inflation 68.6 s (16.6 %), probes ≤ 8 s (≤ 2 %) inside the idle share. Steps 1-3 address the 138 s only; with a x1.345 wire/payload envelope the payload-basis utilization cannot exceed 74.3 % even at zero request cost, so a payload-basis 90 % gate needs the envelope counted or shrunk — that number is checked before Step 3's gate is set.
The hub can log one line per accepted TCP connection to make `requests` exact.

## Step 1 — one connection per flush (expected: +20-30 points)
tools/t2/journey_hub.py uses `BaseHTTPRequestHandler` at HTTP/1.0: every response closes the
socket, so every bundle and every chunk pays a fresh TCP handshake and slow start on the
16 kbit/s pipe. Set `protocol_version = "HTTP/1.1"` on the handler and make `_send` always
write Content-Length (it does) so keep-alive holds; on the phone `HttpClient` reuses idle
connections by default — keep the bulk client's `idleTimeout` ≥ 60 s. Gate: the hub's
connection log shows ≤ 2 connections per window; window-1 utilization ≥ 60 %.

## Step 2 — chunk size from the measured delivery rate (expected: +5-10 points)
8,192 B fixed costs one request per ~4 s of link. Size chunks the way the lane governor sizes
its budget: `chunk = clamp(rate_bytes_per_s × 5 s, 8 KB, 64 KB)` where `rate` is the peer's own
delivery rate over the last window (bytes acked / open time, kept in the durable store);
64 KB is the hub's cap. On a cut, at most one chunk is lost. Gate: requests per window halve;
utilization of a video-only window ≥ 80 %.

## Step 3 — one streaming POST per window (expected: reach ≥ 90 %)
Replace "one request per bundle/chunk" with one request per window: `POST /stream?run=…` with a
length-prefixed sequence of envelopes (small bundles whole, large ones as chunk records
`id, idx, n, sha, bytes`); the hub parses records as they arrive, stores/completes/verifies
exactly as /bundle and /chunk do, and appends events per completed bundle; when the link dies
mid-stream the connection breaks and the peer resumes from `/have` on the next window. This
removes every per-record round trip; the remaining loss is the probe (≤ 2 s) and the last
partial chunk. Gate: utilization ≥ 90 % on every non-final window of a queue 3× the window
(≈ 1.2 MB across ≥ 8 windows); hours-to-all reported; every signature verified.

## Step 4 — beacon instead of probe (expected: +1-2 points, and radio sleep)
The hub sends a 40-byte UDP beacon every second on the bridge; the phone listens instead of
polling, so the window is noticed within ~1 s and no probe bytes are spent while cut. Gate:
first byte of the first bundle within 1.5 s of the window open.

## Step 5 — the gate under a live call (the real scenario)
Run the gate while the survival audio call (8 kbit/s at 120 ms) shares the same 16 kbit/s
window: the queue must yield to voice through the lane governor's measured budget. Expected
utilization of the RESIDUAL (~570 B/s) ≥ 80 %, audio loss below the call's own survival bound
(the monitor bar row), no reconnects caused by the flush. This is the row that goes in the
dossier as "messages keep flowing while the call stays up".

## Step 6 — the same gate over a domestic host, not the rig's Mac
Move the hub role to a small process on a domestic VPS or a fixed-line router (the three roles
from the design note: mailbox, reflexive echo, relay), both phones behind carrier NAT, and
measure the same table. This is where tools/natprobe's numbers decide whether the phones
punch or relay.

## Honesty gates that bind every step
- Utilization is always over the MEASURED open time and the SHAPED rate; never over a nominal
  window or an unshaped link.
- The row PASSes only with N/N delivered and every Ed25519 signature verified on the Mac.
- Numbers in this document are the rig's; a step is not "done" until its gate row is in
  tools/dossier/app_journey_results.tsv.
