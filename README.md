# VoiceCallKit v2

A standards-based, resilient audio/video calling stack for degraded and
unstable network environments. Media is WebRTC (ICE/STUN/TURN, DTLS-SRTP),
signaling is WSS, configuration is an Ed25519-signed HTTPS manifest.
Standard protocols only — no custom traffic-shaping, no custom cryptography, no runtime code download —
enforced in CI by `tool/architecture_guard.dart`.

## Current status (2026-07-16)

Phase numbers follow `docs/EXECUTION_PLAYBOOK.md`. A phase is only marked
closed once its declared gate has passed with evidence — "code exists" is
not the same as "closed" (see `security/THREAT_MODEL.md` for the same
evidence discipline applied to security claims specifically).

- **Phase 0 (Freeze/Baseline/doc honesty) — closed.**
- **Phase 1 (Buildable foundation + CI) — closed.**
- **Phase 2 (Deterministic core tests + concurrency) — closed.**
- **Phase 3 (First runnable vertical slice) — loopback-closed, with dated
  blockers.** Signaling server, adapters, and the full pure-Dart E2E
  signaling loopback are done and tested (100-cycle soak, no leak). Two
  blockers remain open and dated (2026-07-15): native media (`flutter_webrtc`)
  needs full Xcode (only CommandLineTools installed); the real-2-device
  call test needs physical hardware. Neither blocks the loopback-scope work
  that has landed.
- **Phase 4 (Security + identity base) — in progress.** Real Ed25519
  identity keys, TOFU trust store, log redaction, manifest verification
  logic, and TURN credential issuance logic exist with test coverage
  (see `security/THREAT_MODEL.md` for the per-item evidence and honest
  gaps — notably: the real-crypto manifest verifier has 2 failing tests
  as of this review, and platform Keystore/Keychain-backed key storage is
  blocked pending the app shell). Threat model and data-flow diagram are
  current as of this date (`security/THREAT_MODEL.md`, `docs/DATA_FLOW.md`).
- **Phases 5-11 — not started** (media quality, path continuity, signed
  discovery, restored v1 values, mobile integration, observability,
  chaos/scale/audit/rollout).

## Repository layout (Dart monorepo, melos-style)

```
voice_call_kit_v2/
├── apps/reference_app/         # Flutter app shell (UI, permissions, adapters)
├── packages/
│   ├── call_core/              # call state machine, controller, reconnect policy
│   ├── media_webrtc/           # media engine, stats sampler, adaptive quality
│   ├── signaling/              # envelopes, reliable outbox, WSS client
│   ├── adaptive_transport/    # EWMA health, channel router, circuit breaker
│   ├── signed_config/          # signed endpoint manifest: model/verifier/cache
│   ├── device_link/             # consent-gated nearby link (degraded mode only)
│   ├── privacy_telemetry/      # opt-in aggregate-only telemetry
│   └── security/               # identity store (TOFU), log redactor
├── server/                     # signaling + config services
├── infra/                      # coturn, monitoring
├── integration_test/
├── security/                   # THREAT_MODEL, SECURITY, INCIDENT_RESPONSE
├── docs/                       # ARCHITECTURE, PRIVACY, ACCESSIBILITY, HUMAN_RIGHTS_DESIGN
├── tool/architecture_guard.dart
└── UPGRADE_BLUEPRINT_V2.md     # v1 → v2 migration map
```

## Package conventions

- Package name == directory name under `packages/` (snake_case); e.g. the
  transport package is `name: adaptive_transport` and is imported as
  `package:adaptive_transport/adaptive_transport.dart`.
- Each package exposes one barrel file `lib/<package_name>.dart` that
  exports everything under `lib/src/`; nothing imports another package's
  `src/` directly.
- Cross-package dependencies are path dependencies within the workspace
  (melos links them at bootstrap); packages are pure Dart — platform
  plugins are wrapped behind ports (`PeerConnectionPort`,
  `SignalingSocket`, `LocalLinkPort`, storage/crypto adapters) implemented
  in `apps/`.
- All packages are `publish_to: none` and versioned in lockstep (2.x).

## Getting started

```
dart pub global activate melos
melos bootstrap
melos run analyze
melos run test
melos run guard      # architecture guard (also a required CI check)
```

`tools/workspace_gate.sh` runs analysis and tests over every package and
the app in one pass, choosing `flutter test` for Flutter packages, and
prints a per-package count with a total.

## Fallback lanes and the border relay

When the live WebRTC path dies, `ConnectionFabric` fails over to the
resilient lanes: direct UDP, a WebSocket relay, an HTTP long-poll, and a
local peer mesh. Each lane is registered only when it has an endpoint —
a lane aimed at nowhere would look healthy to the ranker while delivering
nothing, which is worse than no lane at all.

The two WAN lanes terminate on a border relay. One is deployed:

```
voice-call-relay.tlscodes-com.workers.dev
```

Source is `tools/cloudflare_relay_worker/` (see its README for the
protocol and for the deploy command). The app uses it by default, keying
the relay session on the call id and the role on the call role. Anything
in the environment overrides that:

```
FALLBACK_RELAY_HOST      swap the relay host
FALLBACK_RELAY_SESSION   relay session id (a shared secret, not a call number)
FALLBACK_RELAY_ROLE      a | b
FALLBACK_WS_ENDPOINT     override that one lane with a full URI
FALLBACK_HTTP_ENDPOINT   override that one lane with a full URI
FALLBACK_UDP_ENDPOINT    host:port for a direct media endpoint
```

Because the call id doubles as the relay session id, call ids must be
unguessable: anyone holding one can attach to the relay as the missing
side. `newSecureCallId()` mints one from `Random.secure()` — 128 bits in
the relay's own alphabet, so it needs no sanitising. Payloads are sealed
by the call's own session keys before they reach the relay, so what leaks
is the connection, not the content.

### Behaviour at the bottom of the link

The floor these lanes are built for is Hamseda v4's warm rate: **31.8 bps,
roughly four bytes per second.** At that budget the framing is not a
rounding error — a 4-byte media frame carries a 5-byte gRPC header, so it
costs 9 bytes, more than two seconds of link. That header is the
protocol's and cannot be tuned to zero here; what this code guarantees is
that it sends the frame **once**, unpadded and unre-framed, and that the
HTTP lane's liveness probe (`HEAD`) never consumes a queued frame.

What the fabric adds at that floor is survival rather than speed. Under a
simulated 4 bytes/sec budget with 90% loss, every frame is either sent or
parked in the delay-tolerant queue — never rejected, never dropped, never
timed out — and the backlog drains **in order** the moment capacity
returns. That is asserted, not asserted-by-comment, in
`packages/connection_orchestrator/test/resilient_fallback_lanes_test.dart`
under "ultra-low bitrate survival".

### Running the fallback simulations

Both suites are in-memory or loopback only — neither reaches the deployed
relay, because a test pointed at it would be measuring Cloudflare's uptime
rather than this code.

```
# failover: media keeps its sequence when the live path dies mid-stream
cd apps/reference_app && flutter test test/fallback_lane_failover_e2e_test.dart

# relay protocol: the real lanes against a loopback server implementing
# the same routes as the worker
cd packages/connection_orchestrator && dart test test/cloudflare_relay_protocol_test.dart
```

## Design and governance documents

- `docs/ARCHITECTURE.md` — layering, package responsibilities, call flow.
- `docs/PRIVACY.md` — what each component can and cannot see.
- `docs/ACCESSIBILITY.md` — WCAG 2.2 AA requirements for the app.
- `security/` — threat model, security policy, incident-response runbook.
- `docs/DATA_FLOW.md` — data-flow diagram, trust boundaries, key-material
  locations (companion to `security/THREAT_MODEL.md`).
- `UPGRADE_BLUEPRINT_V2.md` — what was ported from v1, what was replaced,
  and the excluded legacy list.
