# VoiceCallKit V3 — Execution Playbook (Sandwich + CI, all phases)

This is the operating manual for building `UPGRADE_BLUEPRINT_V3.md`. It sets one
repeatable **sandwich** loop, wires **CI as the mechanical gate** at the very start,
and applies the same loop to every phase (0→11). Hand this file to the model that
runs each wave. It changes *how* the work is executed; the *what* stays exactly the
blueprint.

---

## 0. Read-me-first: how this playbook is used
- The blueprint (`UPGRADE_BLUEPRINT_V3.md`) is the source of truth for **what** to build.
- This playbook is the source of truth for **how** each phase is executed.
- One phase = one or more **sandwich waves**. A phase closes only when its blueprint
  **Gate خروج** passes as a **green CI run** — never on a "looks done".
- Golden rule: **no code lands that a red gate would reject.** CI runs first, always.

---

## 1. CI — the mechanical gate (set up BEFORE any feature work)

CI is not a late step; it is the floor everything else stands on. Status: **already
scaffolded** in this repo.

### 1.1 What exists now
```
.github/workflows/ci.yml   → the gate: pub get · format · analyze · test · guard · secret-scan
.gitignore                 → dart/flutter + backups
git repo + baseline commit → Phase-0 reversible snapshot (da22170)
```

### 1.2 The gate steps (mirror of Phase-1 Gate خروج)
| Step | Command | Meaning |
|------|---------|---------|
| resolve | `flutter pub get` | native pub `workspace:` resolves all packages |
| format | `dart format --output=none --set-exit-if-changed .` | style is enforced, not debated |
| analyze | `dart analyze --fatal-infos --fatal-warnings` | 0 issues or the gate is red |
| test | `flutter test` per package with a `test/` dir | testers' work runs here |
| guard | `dart run tool/architecture_guard.dart` | architecture rules enforced |
| secrets | grep for key patterns in the diff | no secret ever lands |

### 1.3 Local prerequisite (one time)
```
brew install --cask flutter          # installs the Dart+Flutter SDK
flutter --version && dart --version   # confirm it's on PATH
```
CI in GitHub Actions installs Flutter itself — local install is only so you can run
the same gate on your machine before pushing.

### 1.4 Branch + gate policy
- `main` is always green. Work happens on a branch per wave: `phase-<n>/<short>`.
- A wave merges to `main` only when the CI gate is green on its branch.
- Every phase begins by re-confirming `main` is green (no building on red).

---

## 2. The sandwich loop (identical every wave)

```
① BRIEF   (Fable, thin)   → 150–400-token task brief for THIS wave:
                            hidden contradictions · decision criteria · trap list ·
                            one worked success path · mechanical acceptance checklist.
                            Generate the worker protocol with:
                            route-task.py --protocol coding

② EXECUTE (parallel, Sonnet) → disjoint targets, one SURGEON + one TESTER each:
     • SURGEON writes the code for its target, ends with `dart analyze` (VERIFY-1).
     • TESTER (≠ surgeon) writes/extends tests for the SAME target (VERIFY-2).
     Surgeons run ≤5-wide; targets must not overlap the same file region.

③ GATE    (mechanical)    → merge the wave's diff on its branch → CI runs §1.2.
                            Red = the wave is not done. No exceptions.

④ FINISH  (Fable)         → reads the merged diff, repairs residual, signs off.
                            This is active repair, not just a score.
```

### Roles (who runs what)
| Role | Model/tier | Job |
|------|------------|-----|
| Conductor / brief / finish | Fable 5 | thin brief per wave; final repair + sign-off |
| Surgeon (builder) | Sonnet 5 (medium→high) | writes code for one disjoint target |
| Tester (collaborator) | Sonnet 5 (medium) | writes tests for the same target; author ≠ tester |
| Cross-critic | Sonnet 5 (low→medium) | reviews merged diff when a wave is risky |
| Scout (read-only) | Sonnet 5 (low) | maps a subsystem before a wave; never mutates |

### Escalation
- A target fails its gate twice → re-brief with the new evidence (log/analyzer output).
- Third failure → stop; the approach is wrong, redesign that target (don't re-roll).

---

## 3. Per-phase execution (blueprint phase → sandwich wave)

Each row: the phase's disjoint targets (→ parallel surgeon+tester pairs) and the
**gate** that closes it. Detail lives in `UPGRADE_BLUEPRINT_V3.md`; this is the wave map.

### Phase 0 — Freeze / Baseline / doc honesty  ✅ done
- Targets: git snapshot · package/API/dep inventory · README trimmed to proven claims.
- Gate: reversible snapshot exists; no unbuilt feature claimed as delivered. **(closed — commit da22170)**

### Phase 1 — Buildable Foundation + CI  ← START HERE
- Pairs: (A) `call_core` export conflict · (B) real pinned deps + SDK · (C) concurrency fixes: sampler race, negotiation timeout, circuit-breaker half-open · (D) architecture_guard root + redaction order.
- Gate: `flutter pub get` · `dart format` · `dart analyze --fatal-infos` = 0 · `flutter test` · guard — all green in CI.
- Brief already written: `docs/PHASE1_SANDWICH_BRIEF.md`.

### Phase 2 — Deterministic core tests + concurrency
- Pairs: Clock/Timer/random abstraction · state machine · reconnect backoff · EWMA score · reliable outbox + dedup · signed-manifest cache/expiry/rollback (one pair per module).
- Gate: ≥85% line / ≥75% branch coverage on stateful modules · 0 real timers in unit tests · no flake across random seeds.

### Phase 3 — First runnable vertical slice
- Pairs: `apps/reference_app` · real `WebRtcMediaAdapter` · minimal signaling server · coturn config · call invite/accept/reject/hangup.
- Gate: 100 setup/teardown cycles no leak · 10× 30-min calls no state lock · real 2-device call · TURN fallback proven · 0 SDP/token/key in logs.
- **STATUS 2026-07-15 — loopback mode active; 2 dated blockers:** (1) full Xcode not installed (only CommandLineTools) → `flutter_webrtc` native build blocked; user action: install Xcode from the App Store, then `sudo xcode-select -s /Applications/Xcode.app`. (2) real-2-device gate item needs physical devices. Everything pure-Dart (signaling server, adapters, E2E signaling loopback, coturn config) proceeds now; media loopback + device call run in the scheduled slot after Xcode/devices arrive.

### Phase 4 — Security + identity base
- Pairs: verifier · signer · identity key engine · manifest verification · anti-replay (nonce+window) · anti-rollback (one pair each). Keys in Keystore/Keychain.
- Gate: 100% tampered manifests rejected · 100% replays rejected · no secret in storage/log · threat-model + data-flow diagram complete.
- **STATUS 2026-07-15 — pure-Dart scope CLOSED (419 tests green):** real Ed25519 everywhere (identity engine, manifest verifier + signer/keygen CLIs, envelope/mesh-frame auth), TURN short-lived credentials (known-vector pinned), threat model T1-T19 + DATA_FLOW.md complete. All tamper/replay tests reject 100%. **1 dated blocker:** OS Keystore/Keychain adapter needs the Flutter app shell → same Xcode blocker as Phase 3; scheduled for the Xcode slot. Dev key stores (`InMemoryKeyStore`/`DevFileKeyStore`) are loudly dev-only.

### Phase 5 — Media quality + stability
- Pairs: audio policy (Opus/DTX/FEC/PLC, audio-first degrade) · video policy (bitrate→fps→resolution→audio-only) · JitterBuffer/FEC scoping.
- Gate: normal net setup ≥99%, P95 ≤6s · at 10% loss/80ms jitter/300ms RTT setup ≥95% + graceful audio-only, no crash · at 30–40% loss no deadlock/crash.
- **STATUS 2026-07-16 — pure-Dart scope CLOSED (60 tests green in media_webrtc, +38 new):** AdaptiveJitterBuffer + XorFec fully tested (previously zero tests — wraparound, late/duplicate/overflow, single-loss recovery, two-loss graceful refusal); simulated G5 impaired matrix green over the real engine→sampler→policy chain (normal stays `high`; 10%/80ms/300ms degrades stepwise to audioOnly; 35% loss completes + recovers to `high` with slow-up hysteresis; oscillation bounded ≤4 transitions). Simulated results prove policy/stability behavior only — the numeric gate (setup %, P95) is a real-device claim. **Dated blockers (2026-07-16):** real Opus DTX/in-band FEC/PLC engagement + real-device G5 numbers need the flutter_webrtc native stack → Xcode slot (Xcode 26.6 staged in /Applications, awaiting user sudo activation).

### Phase 6 — Path continuity + relay diversity
- Pairs: `RelayPool` multi-region · TURN over UDP/TCP/TLS + short-lived creds · health check + EWMA + hysteresis · ICE restart · last-known-good manifest cache.
- Gate: kill a signaling node → service survives · kill a TURN region → new calls move · Wi-Fi→mobile recovers P95 ≤8s · duplicate signaling doesn't corrupt state · no path flapping.
- **STATUS 2026-07-16 — pure-Dart scope CLOSED (64 tests green in adaptive_transport, +30 new):** `RelayPool` built — multi-region selection with EWMA health (`RegionHealth`), anti-flapping hysteresis, per-region circuit breaker, `fromManifest(relayRegions)` consuming signed manifest schema v2, short-lived-credential glue (`RelayGrant` with pinned coturn vector); region-kill → selection moves (simulated) proven. TURN cost pre-gate artifact created: `docs/OPERATIONS.md` (formula, scenario grid, 50 GB/month soft cap recorded). **Remaining, dated 2026-07-16:** (1) provider budget ALERT — only creatable in the provider console at first coturn deploy; deploying without it is forbidden per blueprint :842. (2) signaling multi-node clustering + real node/region-kill chaos, TURN-TLS listener, Wi-Fi→mobile P95≤8s — need real deployment/devices; scheduled for the deploy slot after the Xcode/device slot.

### Phase 7 — Signed endpoint discovery
- Pairs: ≥2 HTTPS origins (Host/SNI match) · signed manifest (version/iat/exp/keyID/regions/endpoints/min-version/flags) · last-known-good + grace window · key rotation. No runtime code download.
- Gate: origin-1 failure covered by origin-2 · offline last-known-good works in window · older/tampered manifest rejected · rotation without outage.
- **STATUS 2026-07-16 — CLOSED (95 tests green in signed_config):** manifest schema v2 (relayRegions, bounded featureFlags, multi-origin `configServiceUris` — all canonical-signed); real `IoManifestFetcher` (strict TLS, no badCertificateCallback, size cap, https-only redirects); multi-origin failover with per-origin isolation proven over two real `HttpServer.bindSecure` origins (origin-1 down AND origin-1 tampered → origin-2 serves; both down → last-known-good in grace; past grace → unavailable); zero-outage key rotation proven with real Ed25519 (revocation beats freshness and rollback); threat model extended T20-T24. All gate items pass.

### Phase 8 — Restore the old-version values (plainly named)
- Pairs: `PushWakeup` (FCM/APNs wake only, opaque call-id) · `NearbyTransport` (BLE discovery + Wi-Fi Direct/local) · `LocalDissemination` (signed+encrypted store-and-forward, TTL/quota/consent) · `NetworkQualityPolicy` (healthy/constrained/degraded/locallyConnected).
- Gate: duplicate push → no duplicate call · expired push rejected · dup local envelope not reprocessed · TTL/quota held on 5/10/20 devices · battery measured vs baseline · no-gateway enables local-only clearly.
- **STATUS 2026-07-16 — pure-Dart scope CLOSED (79 tests green in device_link, 86 in adaptive_transport):** `PushWakeupPayload`/`PushWakeupProcessor` built — opaque call-id only, unknown-key rejection by construction (no room for SDP/contacts), 512 B cap, dedup via bounded seen-cache (duplicate push → announced once; expired rejected; replay stays rejected); `GuardedMeshProcessor` adds the blueprint's missing per-peer quota + global rate limit + 3-level priority shedding over the existing TTL/dedup/kill-switch mesh core, held under simulated 5/10/20-peer load (G7 simulated); `NetworkQualityPolicy` with the four blueprint profiles, dwell hysteresis, and one-call bridge to `PathSelector` (no-gateway + local-peers → locallyConnected/isolated proven). **Dated blockers (2026-07-16):** real FCM/APNs delivery + native BLE/Wi-Fi-Direct `LocalLinkPort`/`PushWakeupPort` implementations and the battery-vs-baseline measurement need Xcode + physical devices → Xcode/device slot.

### Phase 9 — Real mobile integration + UX
- Pairs: Android (ConnectionService, foreground service, permissions, Doze, audio focus, BT routing) · iOS (CallKit, AVAudioSession, PushKit, background modes, route change) · UX (Connecting/Reconnecting, audio-only indicator, plain privacy state, low-data mode, telemetry off).
- Gate: tested on 2 major Android + 2 major iOS · headset/BT/speaker · background/foreground · lock screen · concurrent with a cellular call · 0 permission loop.

### Phase 10 — Observability + abuse controls
- Pairs: allowed telemetry (setup duration, ICE type, region bucket, RTT/jitter/loss buckets, reconnect count, codec, failure category) · forbidden-data guard · infra dashboards (signaling, TURN bandwidth, region health, cost/relayed-min) · abuse controls (rate-limit, short-lived creds, invite-spam guard, device revoke, audit trail).
- Gate: automated no-secret-in-log test · runbooks complete · test alert fires · manifest rollback works · cost dashboard live.
- **STATUS 2026-07-16 — pure-Dart scope CLOSED (21 tests green privacy_telemetry, 57 security, 15 signaling_server):** telemetry allowlist extended to the full blueprint list (ICE-type events, fixed RTT/jitter/loss/bitrate buckets, closed codec enum, double-gated anonymized region, failure-category enums) with forbidden-data negative tests pinning the schema; automated no-secret-in-log gate test landed and EXPOSED+FIXED two real redactor leaks (bearer-JWT passthrough, TURN username half-leak); signaling server got application-level abuse controls (per-connection rate limit 4429, invite-spam session limit 4430, room caps, idle-room reap 4408, privacy-aware counters — legit reconnect stays quota-free); region-outage runbook added (INCIDENT_RESPONSE.md §4.5); manifest rollback already proven by Phase 7. **Remaining, dated 2026-07-16 (deploy-blocked):** infra dashboards, live test-alert firing, cost dashboard — need the cloud deployment; scheduled with the Phase-6 deploy slot. Device-revoke flow needs the app identity UX → Xcode slot.

### Phase 11 — Chaos / scale / audit / rollout
- Pairs: load 100→1k→10k · chaos (node/region kill, DNS fail, cert rotate, clock skew, reorder, burst loss, DB restart, process kill, net transition, suspend, manifest corruption) · security (dep audit, SBOM, fuzz parsers/signaling, replay+downgrade, independent threat-model review, pen test) · gradual rollout (dogfood→1%→5%→25%→50%→100% with auto-rollback).
- Gate: SLOs met under load + chaos · independent audit done and critical findings closed · rollback tested.

---

## 4. Progressive test ladder (which gate level each phase reaches)
```
G0 static (compile/lint/arch/deps)      ← Phase 1
G1 unit deterministic                   ← Phase 2
G2 simulated network (fake clock)       ← Phase 2
G3 loopback (signaling+media one machine) ← Phase 3
G4 two real devices (LAN/mobile/TURN)   ← Phase 3
G5 impaired-network matrix              ← Phase 5
G6 infra failure (region/node/DNS)      ← Phase 6
G7 local continuity (discovery/TTL/battery) ← Phase 8
G8 load/soak (100/1k/10k)               ← Phase 11
G9 canary (limited real users, rollback) ← Phase 11
G10 production (SLO/incident/audit)     ← Phase 11
```
Passing a level requires the previous level green.

## 5. SLO targets (recalibrate on real devices after Phase 3)
crash-free ≥99.9% · setup ≥99% & P95 ≤6s · net-switch recovery P95 ≤8s ·
one-way audio <0.5% · tampered-manifest accept = 0 · replay accept = 0 ·
secret-in-log = 0 · single-signaling-node loss total-failure = 0 · battery regression ≤10%.

## 6. Version roadmap (what "grown" looks like)
```
v2.1.0 Foundation          ← Phase 1 (green build + CI)
v2.2.0 Secure Audio Alpha  ← Phases 2–4 (real 2-device secure call)
v2.3.0 Network Resilience  ← Phases 5–7 (relay diversity, ICE restart, signed discovery)
v2.4.0 Local Continuity    ← Phase 8 (PushWakeup, NearbyTransport, local)
v3.0.0 Audited Production  ← Phases 9–11 (mobile, chaos, audit, rollout)
```
Realistic solo cut-line: **v2.2.0 is the honest near-term target**; multi-region infra,
device farm, 10k-load and independent pen-test (v3.0.0) are multi-person-effort + cost.

## 7. Definition of Done (v3.0.0)
All packages compile · real app makes a two-way call · ≥1 real signaling+TURN deploy ·
no critical security interface unimplemented · unit/integration/device/impairment/chaos
tests green · docs match code exactly · threat-model + privacy review done · no false
E2EE claim for group calls · rollback + incident response tested · independent audit's
critical findings closed.

## 8. Non-goals (state up front, don't drift into these)
- No "unblockable under any condition" / "unhackable" claims — physics + honesty forbid it.
- No domain fronting or non-standard proxy engine in core (fragile / policy-violating).
- No custom cryptography.
- No group-call E2EE claim before audited SFrame/MLS.
- A dedicated pluggable-transport plugin for heavily-filtered networks is **out of core**
  — if ever built, it is a separate, independently reviewed module, not part of this plan.

## 9. Open gaps to close before Phase 3 (from the v3 review)
1. **User addressing / discovery model** — how two users find each other (registration,
   contact exchange, opaque IDs). Without it, Phase 3 only works between pre-paired devices.
2. **Resource cut-line** — declare the solo-realistic target (v2.2.0) explicitly.
3. **TURN cost estimate** — rough egress cost before Phase 6 (relay egress is the main cost).
4. **Explicit group-call Non-goal** — already in §8; keep it visible so no false expectation.
```
