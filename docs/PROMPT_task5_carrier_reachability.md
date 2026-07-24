# Work order — Task 5: consented carrier delivery + active path reachability

## Role
Senior Dart engineer in the `voice_call_kit_v3` monorepo. Work strictly
through existing abstract ports. The core packages stay neutral and
platform-free: no sockets, no radio, no connectivity plugin, no `dart:io` in
the neutral core. Every change ships with unit tests and passes the full
workspace gate in the same step.

## What already exists (build on it; do not rewrite)
- `packages/device_link` — `DtnBundleQueue` (RFC 9171 store-carry-forward:
  priority, lifetime, de-dup, bounded shedding, `BundleStore` seam),
  `BundleCarrierPort` / `BundleContact` / `BundleExchange` / `RetainPolicy`
  (pure-Dart contact-exchange policy over two queues), `SimulatedCarrierLink`
  (test carrier), `DeviceLinkConsent` (opt-in gate), `AuthenticatedEnvelope`.
- `packages/adaptive_transport` — `PathSelector` (EWMA scoring),
  `CircuitBreaker`, `NetworkQualityPolicy`.

## Objective
Complete the delay-tolerant delivery path end to end — a bundle queued while
offline is provably delivered once *any consented carrier contact* occurs —
and add active path discovery so the app learns which of its own reachable
endpoints is currently up instead of guessing. All pure Dart, all
CI-testable with no network and no device.

## Non-negotiable boundaries (state each is met in the code)
1. **Consent-gated.** No bundle is offered to any carrier without an explicit
   `DeviceLinkConsent` check for that contact. A carrier node is a
   *voluntary, opt-in* relay run by its owner; nothing here assumes access to
   a network the owner did not offer.
2. **Isolation-respecting.** The core never touches the carrier owner's
   private network; it only hands opaque bundles to the `BundleCarrierPort`
   the platform layer exposes for its guest/isolated interface.
3. **Opaque payloads.** A carrier never sees plaintext: `DtnBundle.payload`
   is end-to-end ciphertext; the exchange logic must never depend on payload
   contents, sender identity, or final-recipient identity.
4. **Own endpoints only.** `ReachabilityProber` probes a candidate list the
   app supplies; it never fabricates destinations and never attempts to reach
   an endpoint the app was not configured with.
5. **Radio stays out of the core.** All Bluetooth/Wi-Fi-Direct/SSID/USB
   discovery is a `BundleCarrierPort` *implementation* that lives in the
   plugins repo, wired through the abstract port only. This file's work adds
   none of that — only the pure-Dart policy, wiring, and tests.

## Tasks
1. **Review & invariants.** Read `dtn_bundle_queue.dart`,
   `bundle_carrier_port.dart`, `simulated_carrier_link.dart`. Confirm in
   writing: opaque payloads, priority/expiry consistency with
   `MeshMessageProcessor`, non-eviction of a higher-priority bundle, and that
   `BundleExchange` reuses `flush`'s stop-on-first-failure so an interrupted
   contact never half-removes a bundle.
2. **Consent gate in the exchange.** Ensure `BundleExchange.run` cannot move
   a bundle without a passing `DeviceLinkConsent` for the contact's peer; add
   a test proving a denied consent transfers nothing and leaves both queues
   unchanged.
3. **Durable store.** Add an append-log `BundleStore` in
   `packages/device_link/lib/src/durable_bundle_store.dart` (`dart:io` —
   device_link already permits it), with a test proving bundles and their
   priority/lifetime survive a store re-open, and that a truncated/corrupt
   trailing record is skipped without losing earlier bundles.
4. **End-to-end simulation.** In
   `packages/device_link/test/dtn_carrier_simulation_test.dart`, run ≥100
   randomized episodes on a fake clock: nodes drift in and out of contact,
   bundles have random priorities/lifetimes, some contacts interrupt
   mid-exchange. Assert: every non-expired bundle is delivered exactly once,
   in priority-then-age order, no duplicates across carry-and-keep hops, no
   queue exceeds its bounds, zero leaked timers.
5. **App fallback wiring.** Behind `SurvivalModeDriver` in `reference_app`,
   add an optional injected `DtnBundleQueue` so a voice-note clip that cannot
   reach the reliable outbox is stored as a bundle and later flushed through
   a `BundleCarrierPort` on the next consented contact. Off by default; add a
   driver-level test.
6. **ReachabilityProber** in
   `packages/adaptive_transport/lib/src/reachability_prober.dart`:
   - Accept a caller-supplied list of candidate endpoint `Uri`s.
   - Staggered parallel probes via an injected
     `Future<bool> Function(Uri)` and an injected clock — start each
     candidate a fixed stagger apart (e.g. 200 ms); the first success cancels
     the still-pending slower probes (happy-eyeballs); per-probe timeout.
   - Feed measured latency + pass/fail into `PathSelector` EWMA scoring so a
     dead candidate is shed by the existing `CircuitBreaker`.
   - Per-candidate **cooldown**: a result is cached and reused within the
     window; never probe from zero every call (bounds battery/data).
   - Re-probe on an injected `onNetworkChanged()` signal, invalidating the
     cooldown (no platform connectivity plugin in the core).
   - Expose ranked live candidates + a stream of ranking changes.
   - Full tests in
     `packages/adaptive_transport/test/reachability_prober_test.dart`:
     stagger order, fast-winner cancellation, cooldown suppression,
     re-probe-on-change, EWMA integration, all-fail handling, no leaked
     timers under a fake clock.
7. **Fix** any defect the review/simulation/tests reveal; one line each.

## Constraints
- Back up each edited file (`.backups/NNN-...`) before editing.
- No new third-party dependency without a stated reason.
- One logical change per commit; message states what changed and the test
  count. Keep the neutral core free of `dart:io` and any radio/socket code.

## Acceptance checklist (each mechanically checkable)
- [ ] `dart format --output=none --set-exit-if-changed .` exits 0.
- [ ] `dart analyze --fatal-infos --fatal-warnings` clean in every touched dir.
- [ ] Full workspace test gate green, grown by the new tests.
- [ ] A denied `DeviceLinkConsent` moves zero bundles (test).
- [ ] The durable store survives a re-open and skips a corrupt trailing
      record without losing earlier bundles (test).
- [ ] The ≥100-episode carrier simulation asserts exactly-once, in-order,
      bounded, leak-free delivery.
- [ ] `ReachabilityProber` core imports no socket/radio/connectivity plugin;
      its tests run fully under a fake clock with an injected probe callback.
- [ ] Stagger, fast-winner cancellation, cooldown, and re-probe-on-change are
      each asserted with no leaked timers.

## Self-check questions (answer with a proof, not a claim)
- Can a bundle move to a carrier whose consent was denied? Prove not.
- Across a carry-and-keep hop then a later contact, can the same bundle be
  delivered to the *same* receiver twice? Prove not.
- If a fast candidate wins, are the slower staggered probes actually
  cancelled rather than run to completion? Prove cancellation.
- Within the cooldown window, is a repeat probe suppressed and the cached
  result returned? After `onNetworkChanged()`, is it invalidated? Prove both.
- Does an expired bundle ever reach a carrier or a forwarder? Prove not.

## One worked path
Read-only invariant map → consent gate + test → durable store + test →
carrier simulation → app fallback wiring + test → `ReachabilityProber` on the
existing `PathSelector`/`CircuitBreaker` + tests → run the gate → fix, re-run.
