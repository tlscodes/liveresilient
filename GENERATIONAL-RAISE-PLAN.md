# Generational-raise plan — voice_call_kit_v3

Authored 2026-08-06 by the standing Fable 5 consultant (read-only survey);
lands as edits ONLY after the running T2 device matrix closes. Doctrine:
leap-on-failure — every item names only the raise directions its evidence
implicates. Execution order = list order (correctness first).

Surveyed: call_core, reference_app (session wiring, e2e support, SLA test),
tools/t2, signaling config, adaptive_transport knobs, pt_transport_darwin.
NOT reached (honest gap): the other ~17 packages, server/, infra/, relay
worker, DTN queue, engine repo. Flagged untraced: SignalingClient's internal
reconnect ladder vs CallController's policy (two stacked give-up authorities).

## 1. Production still runs the pre-model timeouts (CRITICAL)
call_session.dart:238-251 constructs CallController WITHOUT the adaptive
per-class timeouts — the proven failure mode of latency/loss60/extreme is
fixed in the harness getters (e2e_support.dart:207-231) but NOT in
production. Raise: hoist the class mapping into AdaptiveConnectionBudget
(signalingOperationTimeout(liveness), connectionWaitTimeout); call_session
passes them; e2e_support delegates and deletes its local formula; harness's
hand-built ExponentialBackoffReconnectPolicy (e2e_support.dart:423-431)
folds into toReconnectPolicy(). Verify: unit test pinning equality with
operationBudget; prover table unchanged by construction; 154+ tests green.
Risk: sequence WITH item 2 — production liveness 45 s makes class A ~50 s,
which is honest but must be understood.

## 2. SignalingClientConfig: two divergent hand-tuned configs, none derived
signaling_client.dart:48-82 defaults (15/45 s) vs e2e_support.dart:233-239
(2/8 s); production passes no config at all (call_session.dart:203-216).
Raise: SignalingClientConfig.fromConditions(NetworkConditions) — heartbeat
clamp(rtt,2..15 s); liveness max(3*heartbeat + 2*rtt*lossFactor, floor);
reconnect delays from budget base/maxDelay. Verify: property test pinning
liveness > heartbeat + rtt over rtt 0..5 s, loss 0..0.9. Risk: too-tight
liveness under loss = false socket deaths; keep harness's proven 2/8 unless
derived numbers differ materially.

## 3. media.start() wrongly shares the fixed engine bound
call_controller.dart:1109 puts start (contains getUserMedia = HUMAN latency,
30 s TCC rationale in e2e_support.dart:224-256) under the 15 s compute
bound: fresh install + slow mic grant = first call severed. Raise: separate
mediaStartTimeout (default 30 s) at the start site only; compute calls keep
fixed 15 s; document classes A/B/C/start in one place. Verify: two
fake-async tests (start hung 20 s succeeds; setLocalDescription hung 15 s
fails fast). Risk: wedged native stack takes 30 s to classify on start.

## 4. Budget never learns from the measured path (HIGHEST TOUCH — land alone)
call_session.dart:191-202 builds the budget once from initialConditions; the
path monitor (252-260) already reads RTC stats but only triggers recovery.
Raise: between recovery episodes (never mid-episode), if measured EWMA
conditions depart >2x from the budget's, rebuild budget + swap policy/
timeouts for the next episode, reusing network_quality_policy.dart
hysteresis; log every swap with old/new conditions. Verify: scripted-stats
unit test forcing exactly one swap and proving none mid-episode; recovery
soak stays green. Risk: oscillation — hysteresis and episode boundaries are
load-bearing; own soak run.

## 5. "Reconnect budget exhausted" carries no numbers
reconnect_policy.dart:157-160. Raise: giveUp reason names the binding cap +
budget basis (elapsed vs maxElapsed, attempt n/m, attemptCost, rtt, loss)
via optional provenance filled by toReconnectPolicy(); flows through
CallState.error into SLA_SUMMARY and the h2 note column with zero harness
changes. Verify: unit test incl. the 256-char giveUp validation (truncate,
don't throw). Risk: near zero.

## 6. Simulator rows exercise Rosetta x86_64, not device arm64
PtTransport.xcframework lacks an arm64-simulator slice; Podfile:53 exclusion
is the standing workaround. Raise: rebuild with ios-arm64_x86_64-simulator
universal slice in the ENGINE repo (make_xcframework.sh — repo not present
here), vendor, delete exclusion. Verify: lipo -archs; native arm64 sim
loopback green. Risk: EXTERNALLY BLOCKED on the engine repo — dated blocker
until available.

## 7. Probe counts are name-keyed constants
h2_run.sh:357-364 (40 for latency|extreme|loss60, else 20; born of the
2026-08-05 latency underrun 256/347 vs floor 300). Raise: derive probes =
max(20, ceil(floor_per_dir / (50 pps * (1-p)) / expected_probe_seconds));
50 pps from 20 ms ptime; print a predicted-vs-floor table at run start; WARN
if derived > 60 (breaks the re-summed @Timeout). Verify: one shaped run per
tier, predicted ~= observed within 2x.

## 8. The profile table exists in three hand-synced encodings
profile_args (h2_run.sh:49-73) vs budget_conditions (389-403, rtt must equal
2*delay — unchecked) vs the prover's built-in table. Raise: single
tools/t2/profiles.tsv; both shell readers parse it; rtt derived as 2*delay;
prover gains --profiles mode that fails on disagreement (built-in stays for
standalone runs). Verify: prover --profiles exit 0 in the verify chain.

## Deliberately NOT raised (judgment, not omission)
- Routed-packet floors 300/600: the 2026-08-05 decision stands — the floor
  guards against rig self-certification; deriving it from the guarded
  assumptions would be that self-certification. Sufficiency proven via #7.
- Stress tier's +15 s detection allowance: declared deliberate double-entry;
  single-sourcing would defeat the independence the user mandated.
- engineOperationTimeout 15 s for compute calls: stays fixed (see #3 — the
  defect is one mislabeled site, not the constant).
- adaptive_transport's 5/8/12/15 s timeout ladder: no confirmed consumer
  wires it to the controller — investigate before ranking, don't raise on
  an unverified claim.
