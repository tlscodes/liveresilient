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
Gate: a table `window | bytes | bytes/2000 | measured s | overhead s | requests` from the logs.
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
