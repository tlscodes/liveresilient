# TXT query lane — security review, 2026-09-12

A Workflow of Fable 5.1 agents reviewed the DNS-message transport module for
security and correctness defects, every finding went through an independent
3-vote adversarial refutation pass, and the seven that survived are fixed and
tested below. This file is that research turned into a record, honestly
including what the review could not cover.

## Scope and method

Six files, one reviewer each, findings pooled and then each one judged by
three independent "try to refute this" agents (majority-not-refuted survives):

```
packages/adaptive_transport/lib/src/resilient/txt_query_wire.dart
packages/adaptive_transport/lib/src/resilient/txt_query_transport.dart
packages/adaptive_transport/lib/src/resilient/txt_query_lane.dart
tools/t2/txt_query_wire.py
tools/t2/txt_query_server.py
tools/t2/txt_query_client.py
```

24 candidate findings, 7 confirmed, 17 refuted as false positives.

## Coverage is not 100%, and this section says exactly where it is not

Of 78 agent calls, **29 failed outright** with `Fable 5.1's safeguards
flagged this message ([cyber])` — a server-side content-safety pass, not a
judgment about this code. Concretely:

- **All three Python-file reviewers failed.** `tools/t2/txt_query_wire.py`,
  `tools/t2/txt_query_server.py` and `tools/t2/txt_query_client.py` were
  never actually reviewed this round — their zero-findings count means
  "not checked," not "clean." All 24 candidates and all 7 confirmed
  findings come from the three Dart files only.
- Roughly half the verification votes on the three Dart files' findings
  also failed the same way; two confirmed findings below (#1 and #6) stand
  on 1–2 surviving votes instead of the intended 3, and are flagged as such.
- This is a known, previously-measured behavior of this project's content on
  this model (`~/.claude/knowledge/lessons/discipline/fable-cyber-flag...`),
  not something particular to this run.

**Follow-up still open:** a proper review of the three Python files above.

## Confirmed findings, fixes applied, and the tests that prove them

### 1 & 6 — an answer was accepted on a 16-bit transaction id alone

`txt_query_wire.dart` (`parseDnsAnswerPacket`) decoded and then discarded the
answer's question section, so `txt_query_lane.dart`'s `_query` could only
check `txid` — 16 bits — even though the question name it actually sent
carries a session id and nonce an off-path attacker cannot know. A flood of
~65536 spoofed datagrams, or a late answer to a timed-out query whose txid
collides with the current one, would have been accepted as the real reply.
(Votes: 2/3 and 1/3 respectively surviving refutation — the two Fable
verify calls that didn't complete were `[cyber]`-flagged, not dissenting.)

**Fix:** `ParsedDnsAnswer` now carries `questionName`, decoded alongside
`txid`; `_query` rejects an answer whose question name does not match the
name it sent, in addition to the txid check (RFC 5452 §9.1 question-section
matching).

**Test:** `txt_query_lane_test.dart` — *an answer under the wrong question
name is not an answer*.

### 2 — DoH response body had no size cap

`txt_query_transport.dart`'s `_collect` accumulated the response body with
no limit and never checked `Content-Length`, while the default `HttpClient`
has `autoUncompress` on. An endpoint (or a trusted intercepting proxy) could
answer 200 with a small compressed body that inflates far past what a DNS
message can legally be, exhausting memory before the txid check ever runs.

**Fix:** `Content-Length` is checked against the DNS-message ceiling
(65535 bytes) before the body is read; a running byte count during
accumulation enforces the same cap independent of any header.

**Tests:** *a declared size past a DNS message's own limit is refused before
the body*, *a body that keeps sending past the size limit is cut off,
declared or not*.

### 3 — a stalled request left its socket held open

When the shared deadline fired during `postUrl` or `request.close()`, the
`HttpClientRequest` was dropped without being aborted, so the connection
stayed occupied in `HttpClient` until `dispose()` — one held socket per
retry on the filtered network this lane exists for.

**Fix:** the request is now aborted on any failure path (best-effort — a
failing abort itself is caught so it can never mask the real error being
propagated).

**Verified by:** full regression pass (16 pre-existing `DohQueryTransport`
tests exercise every one of these failure paths); no new dedicated test
asserts the socket is released, since the fakes model the request object,
not a real held connection.

### 4 — the UDP source filter compared address spelling, not bytes

`InternetAddress.tryParse` in `_resolve()` keeps the caller's exact spelling,
while a received datagram's address is always the canonical form. A
resolver configured as `2001:4860:4860:0:0:0:0:8888` would never match a
reply from `2001:4860:4860::8888`, and every exchange would time out against
a perfectly healthy resolver.

**Fix:** the source filter now compares `InternetAddress.rawAddress` bytes
(`_sameAddress`), the same fix already applied to resolv.conf parsing
elsewhere in the file.

**Verified by:** `dart analyze` + full regression pass. `Udp53QueryTransport`
has no injection seam for a fake socket (a pre-existing, documented gap —
see `docs/OPEN_DEFECTS_txt_query_lane.md`), so this fix is not covered by a
new automated test; it is a straightforward two-line arithmetic change to
byte comparison, reviewed by inspection.

### 5 — one brief outage could decide the valve is down forever

Every transport rotation on the first chunk was counted against
`failThreshold` individually. With the phone default of exactly 5
transports and `failThreshold: 5`, a single `send()` call whose first chunk
timed out on all five would declare the valve permanently DOWN — from one
outage, not five.

**Fix:** rotations within one `send()` now count as a single failure against
the threshold, charged only once all candidates are exhausted.

**Test:** *rotating through every candidate on one send counts as one
failure*.

### 7 — a bad domain threw past the health tracker

`encodeQueries(payload, domain)` was called outside any `try`, so a domain
the wire layer refuses (empty label, FQDN too long) made `send()`/`probe()`
throw `TxtQueryWireException` instead of returning a failed `SendResult` —
`health.observe()` was never reached, and a fabric awaiting `probe()` on
every lane got an unhandled exception from this one.

**Fix:** the call is now inside a `try`/`on TxtQueryWireException` that
returns `SendResult(SendStatus.transient, ...)`, matching every other
failure path in `_carry`.

**Verified by:** full regression pass; the pre-existing commented-out test
this defect was already noted against (end of `txt_query_lane_test.dart`)
was not re-enabled in this pass — a follow-up, not forgotten.

## Rejected findings

17 of 24 candidates were refuted by majority vote — mostly deliberate
tradeoffs the reviewers read as defects on a first pass (e.g. `rtt`
computed the same way in every lane in the package, not unique to this
file). Full per-finding refutation reasoning is in the workflow's journal,
not duplicated here.

## Result

```
dart test (packages/adaptive_transport)   730 passed, 2 skipped, 0 failed
dart analyze lib/src/resilient/           No issues found!
```

7 of 7 confirmed findings fixed; 4 new tests added proving 4 of them
directly, 3 verified by full regression + inspection (noted above). Python
side of the lane: not reviewed this round.

## Follow-up record, 2026-09-13

### The lane on the phone, under the rig's shaper

`tools/t2/txt_lane_phone_matrix.sh` runs
`apps/reference_app/integration_test/txt_query_lane_on_device_test.dart` on
the rig iPhone against the Python responder on the Mac, one impairment
profile at a time (the same `net_shape.sh` numbers as the app journey
matrix; the shaper refuses `T2_PEER=` through sudo, so all UDP on
bridge100 is shaped, as `journey_run.sh` falls back to). Rows:
`tools/dossier/txt_lane_phone_matrix.tsv`; logs `tools/dossier/logs/txt_lane/`.

```
profile    verdict   one chunk   four chunks   strict 5x100B      retry(3) 5x100B
clean      PASS      2 ms        7 ms          5/5   34 ms        5/5   28 ms
normal     PASS      87 ms       344 ms        5/5   1.29 s       5/5   1.30 s
latency    PASS      1807 ms     7229 ms       5/5   27.1 s       5/5   27.1 s
loss10     FAIL      lost        13 ms         3/5   6.05 s       5/5   0.35 s
bandwidth  PASS      73 ms       339 ms        5/5   1.27 s       5/5   1.26 s
narrow     PASS
loss60     FAIL      lost        lost          harness aborted mid-suite: unmeasured
extreme    FAIL      2146 ms     lost          2/5   28.5 s       5/5   43.2 s
```

Every red case is the strict policy (one attempt per chunk): a single lost
datagram ends the send. The retry policy delivered 5/5 in every profile
where it was measured, and 17× faster than strict at 10 % loss because a
retry waits the measured round trip, not the whole timeout.

### The lane's second generation (uncommitted; one file awaits the user)

- `TxtQueryRto`: RFC 6298 estimator per transport. Backoff holds at twice
  the estimate while the estimate is fresh (`freshFor`, 3 s) — a sender with
  one datagram in flight cannot congest the link it measures — and doubles
  toward the ceiling once stale, so a stepped round trip can be found again.
- `TxtQueryLane`: `attemptsPerChunk` (count; app default 24, the cap) under
  `chunkBudget` (time, the limiter) =
  `(responderSessionTtl 60 s − 2·timeout) / candidates`, floor one timeout,
  charged in timer values; the next attempt after a fast negative answer is
  paced by the estimate; negatives feed the backoff and never the
  estimator; rotation mid-session; one failure per send unchanged.
- A Fable 5.1 second lens on the design caught three holes that are now
  folded in (fast-negative spin, a hard 2× cap stopping the RTT search,
  budget × candidates crossing the responder's session TTL). Its further
  step — racing late replies of earlier attempts so a reply at 2.5× RTO
  still lands and teaches the estimator — is recorded, not done.
- Unit suites: 101 of 102 green at the last run; the last planned edit of
  `txt_query_lane.dart` was stopped by the repository's per-file edit
  guard. The finished file is `.backups/NEXT-txt_query_lane.dart.patched`;
  until it is copied over, the lane has three analyzer errors and the
  phone re-run of clean / loss10 / loss60 / extreme is pending.

### The second generation on the phone (re-run after the user applied the lane)

The matrix now launches the app unshaped and applies the shaper once the
test's `TXTLANE shaped=` marker appears (the loss60 launch handshake never
completed while shaped: 22 min in "Installing and launching"). Retry policy
= `attemptsPerChunk 24` under the derived budget; strict = 1.

```
profile   verdict   strict 5x100B          retry 5x100B            note
clean     PASS      5/5   37 ms            5/5   28 ms
loss10    PASS      1/5   12.1 s           5/5   45 ms             one lost datagram, one 45 ms re-send
loss60    5/6       0/5   15.0 s  DOWN     5/5   39.0 s  (65 att)  echo one-chunk send: 24 attempts, 0 replies
extreme   5/6       2/5   26.3 s           4/5   148 s   (53 att, 12 replies)   REGRESSION vs count-3: 5/5 in 43 s
```

The extreme row is the finding of the day and it is against this design:
with a round trip of 2.1–2.5 s against a 3 s ceiling on a 16 kbit/s link,
a retransmit sent at the ceiling lands behind the previous attempt still in
the pipe, the reply arrives after the timer, and the transport discards it
because that transaction id is no longer pending — 12 replies to 53
attempts. The retries then queue the very link they are measuring, which
the second lens had warned "cannot congest" is false at this project's
rates. The count-3 policy simply retried less. The correction is the step
the consult named and this row now motivates: keep every attempt of a
chunk pending for the chunk's whole budget and accept the first reply that
matches any of them (sampling the round trip from its own send time), so a
late reply is a delivered chunk and a learned round trip rather than a
loss; and pace retransmits on a thin link by the measured round trip, not
the ceiling. Until that lands, `forValve` on a link whose round trip is
within a second of the timeout is no better than count-3 — and on every
other profile it is the difference between 0–3 of 5 and 5 of 5.

### The Python side, reviewed

Three Opus reviewers (Fable's safeguard stopped every Fable attempt on
these files, on 2026-09-12 and again on 2026-09-13), 26 candidates, 3-vote
refutation, 12 confirmed and fixed by two surgeons with new suites
(`test_txt_query_server.py`, `test_txt_query_client.py`,
`test_txt_query_wire_hardening.py`): unbounded reassembly table (global
and per-source caps, absolute age), unbounded `_down` / `_complete`,
prefix-based assembly, read-only poll (`POLL_SEQ`), question-name match,
RDLENGTH and TXT-string bounds, non-ASCII labels as `WireError`, seq-label
width, random txid and a fresh socket per query, source filter, one
deadline per exchange, `stop()` joins its thread. `run_python_suites.py`
19 of 19; the Dart golden-parity gate 114 green. 11 lower-severity
candidates were not put to the vote (cap of 15) and 3 were refuted; one
parity divergence is open: a TXT string running past its rdata is clamped
by the Dart parser and refused by the Python one.

### Lane visibility

`apps/reference_app/lib/src/ui/path_card.dart` renders
`Path: <lane> · <mode>` from `ConnectivitySnapshot.bestLaneId` on the call
screen (the lane the next message takes; not a delivery receipt). Wired in
`main.dart`; 5 new tests, the 47 existing call-screen tests unchanged.

### The lane in the journey matrix (2026-09-13 → 2026-09-14): PASS on the phone

The journey peer never had a ConnectionFabric (it builds its call through
`E2eCallStack.build`), so the DNS defines baked into it were inert. A `dns_valve`
job branch now builds its own fabric (wss, https, valve), reports `lane` and
`lane_chat` events to the hub, and the `dnsvalve` profile of `journey_run.sh`
runs it under the whitelist filter with UDP/5300 to the Mac responder added.
Three rig runs were needed; each one measured a defect the previous one hid.

```
rig filter   the whitelist anchor never enforced: Internet Sharing's stateful
             `pass on bridge100 all keep state` created states the anchor's
             rules were never consulted for (inbound drop: Evaluations 0).
             Fix in net_shape.sh: stateless pass-out, interface-wide inbound
             drop, both inet6 directions, peer states killed at load.
             Probe: allowed=refused 72 ms, blocked=timeout 3002 ms, verdict pass.
run 1        valve registered, WAN probe refused, responder assembled the
             payload (session IH3B66) — but the fabric named the dead relay
             best: 0 − 0.05 = −0.05 beat the live valve's 0.044 − 0.15.
             Fix: _Lane.score() ranks health <= 0 at −1.0 − 0.05·costRank.
run 2        valve SELECTED (−0.138 vs wss −1.05, https −1.10) and deliver()
             still returned queuedForLater; the valve's counters stayed at
             attempts 1 / replies 1 (the selection probe). deliver() feeds the
             planner RAW health; the planner ranked the dead relay first again,
             and an urgent plan with nothing credible held only [ids.first] —
             replicate has no failover, the plan is the attempt set.
             Fix: one deadLaneScore() with two callers (fabric ranking and
             planner blend); urgent-with-nothing-credible replicates over the
             LIVE lanes (cap 2), the cheapest dead lane only when none is live;
             LaneScoreBreakdown.noPath keeps the explanation honest; the peer's
             lane_chat event carries the plan's strategy, lane ids and grounds.
run 3        2026-09-13T22:05:13Z — dns_valve_chat PASS (row time 166.3 s from
             the Mac's run start; the carry itself completed in under a second
             on the unshaped bridge). session 77BU2V, sha256 123264e2…,
             200 bytes; responder: `complete session=77bu2v bytes=200 sha256=
             123264e2…`; valve attempts 7 / replies 7 (one probe, six chunks);
             plan grounds: "replicate: urgent; 0 of 3 lanes at or above
             credibleFloor 0.20; replicating over 1 live lane(s)
             [resilient.dns-valve]". Evidence manifest: 139 rows, 0 mismatched.
```

Gates in the same pass: connection_orchestrator 440 tests, journey peer 15,
`test_journey_run_whitelist.py` 61 checks, `test_net_shape_whitelist.py`,
analyzer clean on every touched file.

Honest limits of that row. The `dnsvalve` profile is unshaped (the filter is the
condition under test); the media rows of the same run fail by design, since no
call can connect with the relay filtered off. The UDP path to port 5300 is not
probed from the Mac; the phone's own events and the responder's log line, matched
on session id and payload hash within the run window, are its witnesses. The
lesson is recorded as one-invariant-fixed-in-one-of-two-rankings: a ranking fix
is proven by the send counter of the lane that should carry, never by a snapshot.

Switching from the local `valve.test` rig zone to a real operational domain (once
one is actually provisioned) is one build flag, read in
`apps/reference_app/lib/src/call_session.dart`: pass
`--dart-define=DNS_VALVE_DOMAIN=<your-zone>` at build time (falls back to the
`DNS_VALVE_DOMAIN` process env var, then to the local test zone) — no code
change needed. This is the app-side switch only; it does not by itself stand up
a public responder or an NS delegation, which is separate infrastructure work.
