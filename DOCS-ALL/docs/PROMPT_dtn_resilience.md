# Work order — Delay-tolerant resilience & active path reachability

## Role
You are a senior Dart/Flutter engineer working in the `voice_call_kit_v3`
monorepo. Work only through the existing abstract ports; keep the core
package neutral and dependency-free (no platform or vendor code). Every
change ships with tests and a passing gate in the same step.

## Context — what already exists
The kit already implements a graceful-degradation ladder and a delay-tolerant
store-and-forward layer, all pure Dart:

- `packages/media_webrtc` — `AdaptiveMediaPolicy` quality ladder down to a
  `lowRateVoice` (~6 kbps) floor.
- `packages/call_core` — sealed `CallState` with a first-class
  `CallPhase.degraded` (`DegradedMode.lowRateVoice | voiceNotes`) plus
  `enterDegradedMode` / `exitDegradedMode`.
- `apps/reference_app` — `SurvivalModeDriver` (voice-note fallback through the
  reliable outbox), `CallMemory` (pre-drop audio tail replayed after
  reconnect), and receiver-side playback UI.
- `packages/device_link` — `DtnBundleQueue` (RFC 9171 store-carry-forward:
  priority + lifetime + de-dup + bounded shedding, `BundleStore` seam),
  `LinkMessageProcessor`, `GuardedLinkProcessor`, `AuthenticatedEnvelope`.

## Objective
Inspect, test, simulate, debug, and where needed extend the delay-tolerant
resilience layer so that a message queued while offline is provably delivered
once any transport returns, in priority then arrival order, without loss,
duplication, or unbounded growth.

## Assumptions to verify (do not take on faith)
1. The bundle payload is opaque to the queue and to any carrier — the queue
   never inspects or needs to decrypt it.
2. Priority ordering and lifetime expiry are consistent between
   `DtnBundleQueue` and `LinkMessageProcessor` (same `LinkMessagePriority`,
   same expiry semantics).
3. Capacity shedding never evicts a higher-priority bundle to store a
   lower-priority one.
4. `flush` stops at the first hand-off failure and leaves the remaining
   bundles queued in order.

## Tasks
1. Read `packages/device_link/lib/src/dtn_bundle_queue.dart` and its test.
   Confirm the four assumptions above with code references.
2. Add a durable `BundleStore` reference implementation backed by a simple
   append-log file format (pure Dart `dart:io`, in a NEW file), with a test
   proving bundles survive a store re-open. Keep it out of the neutral core
   if it needs `dart:io` — place it where `dart:io` is already used.
3. Write a simulation test: N offline/online episodes on a fake clock, random
   bundle priorities and lifetimes, asserting every non-expired bundle is
   delivered exactly once and in correct order, with zero leaked timers and
   bounded memory.
4. Wire `DtnBundleQueue` behind the existing `SurvivalModeDriver` voice-note
   path as an optional fallback store (injected, off by default), so a clip
   that cannot reach the reliable outbox is held as a bundle and flushed on
   reconnect. Add a driver-level test for this path.
5. Implement `ReachabilityProber` in
   `packages/adaptive_transport/lib/src/reachability_prober.dart` — active
   path discovery so the app learns, at run time, which of several candidate
   endpoints is currently reachable instead of guessing:
   - Accept a list of candidate endpoint `Uri`s (the app supplies its own
     reachable endpoints; the prober never invents destinations).
   - Perform **staggered** parallel connectivity probes through an injected
     probe callback `Future<bool> Function(Uri candidate)` — start each
     candidate a fixed stagger apart (e.g. 200 ms) so a fast winner cancels
     the slower probes (happy-eyeballs style), with a per-probe timeout.
   - Measure round-trip latency and pass/fail per candidate and feed both
     into `PathSelector`'s EWMA scoring, so a healthy candidate rises and a
     dead one is shed by the existing circuit breaker.
   - Enforce a configurable **cooldown** window per candidate (a result is
     cached and reused within the window) to bound battery and data use and
     avoid a repetitive probing pattern — never probe from zero every call.
   - Re-probe on an explicit `onNetworkChanged()` signal (injected; no
     platform connectivity plugin in the core), invalidating the cooldown.
   - Expose the ranked live candidates and a stream of ranking changes.
   - Comprehensive unit tests in
     `packages/adaptive_transport/test/reachability_prober_test.dart`:
     staggered start order, fast-winner cancellation, cooldown suppression,
     re-probe on network change, EWMA integration, all-fail handling, and no
     leaked timers under a fake clock.
6. Fix any defect the review, simulation, or prober tests reveal; note each
   in one line.

## Constraints
- Pure Dart in the core; `dart:io` only where already permitted.
- The `ReachabilityProber` core is transport-agnostic: it takes an injected
  probe callback and an injected clock, and contains no sockets, no platform
  connectivity plugin, and no destination list of its own — the app wires
  those. This keeps `adaptive_transport` neutral and unit-testable on CI
  hardware with no network.
- No new third-party dependency without stating why.
- Back up each file before editing (`.backups/NNN-...`).
- One logical change per commit, message stating what and the test count.

## Acceptance checklist (each mechanically checkable)
- [ ] `dart format --output=none --set-exit-if-changed .` exits 0.
- [ ] `dart analyze --fatal-infos --fatal-warnings` clean in every touched dir.
- [ ] The full workspace test gate stays green and grows by the new tests.
- [ ] The simulation test runs ≥100 episodes and asserts exactly-once,
      in-order delivery with no leaked timers.
- [ ] The durable store test proves survival across a re-open.
- [ ] No file in the neutral core imports `dart:io`.
- [ ] `ReachabilityProber` core imports no sockets/platform plugin; its tests
      run fully under a fake clock with an injected probe callback.
- [ ] The prober's staggered start, fast-winner cancellation, cooldown, and
      re-probe-on-network-change are each asserted, with no leaked timers.

## One worked path
Start read-only: map `DtnBundleQueue` + `LinkMessageProcessor` and list the
shared invariants → add the durable store + its test → add the simulation →
wire the driver fallback + its test → build `ReachabilityProber` on the
existing `PathSelector`/circuit-breaker + its tests → run the gate → fix and
re-run.

## Self-check questions
- Can a bundle be delivered twice across a flush that fails mid-way then
  retries? Prove not.
- Can the queue grow past its byte or count bound under a burst? Prove not.
- Does an expired bundle ever reach the forwarder? Prove not.
- If a fast candidate wins, are the slower staggered probes actually
  cancelled, or do they run to completion and waste battery? Prove
  cancellation.
- Within the cooldown window, is a repeat probe suppressed and the cached
  result returned? Prove it.
- After `onNetworkChanged()`, is the cooldown invalidated so the next call
  re-probes? Prove it.
