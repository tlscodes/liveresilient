# UPGRADE_BLUEPRINT_V2 — v1 → v2 Migration Map

v2 is a ground-up restructuring of VoiceCallKit v1 into a standards-
only calling stack. The v1 codebase contributed two genuinely valuable
mechanisms — the EWMA path-health model and the multi-path router — which
were ported intact. Everything that relied on custom traffic-shaping was
excluded, not ported, and CI (`tool/architecture_guard.dart`) fails any
build that reintroduces it.

## Ported from v1 (algorithms preserved)

| v1 file | v2 location | What was kept | What changed |
|---|---|---|---|
| `transport_channel.dart` | `packages/adaptive_transport/lib/src/transport_channel.dart` | EWMA availability smoothing, jitter EWMA, composite score formula, `TransportChannel` contract | Field describing traffic-shape survivability renamed to `reliabilityPrior` (pure delivery-reliability prior); `SendStatus` gains a distinct `duplicate` value for idempotent fanout delivery; runtime range validation added |
| `path_selector.dart` | `packages/adaptive_transport/lib/src/path_selector.dart` | Ranked selection, failover budget, fanout batching, probe/refresh half-life rule, telemetry stream | Per-path `CircuitBreaker` integration; duplicate-aware success accounting; config hot-swap via `applyPolicy` |
| `region_policy.dart` | folded into `path_selector.dart` as `NetworkConditionPolicy` | The `redundancy()` table (stable/congested/degraded/isolated → maxFailover+fanout) | v1 location/level scoring dropped — v2 reacts only to *measured* conditions, never to geography |
| `push_channel.dart` | app-layer adapter (implements `TransportChannel`) | Health prior shape, size-limit guard, one-way push semantics | Payloads restricted to wake-up signals (see `docs/PRIVACY.md`) |
| `mesh_channel.dart` | `packages/device_link/` (rewritten, not ported) | The idea of a nearby-device last-resort path | Now consent-gated, degraded-mode-only, every hop Ed25519-authenticated, replay-protected, forwarding off by default with hop/TTL caps |

## Replaced (same need, honest mechanism)

| v1 mechanism | v2 replacement |
|---|---|
| `resilient_provisioning.dart` / `dynamic_provisioning.dart` (unauthenticated dynamic endpoint discovery) | `packages/signed_config/`: HTTPS fetch of an Ed25519-**signed** endpoint manifest, keys pinned in the build, monotonic revision (anti-rollback), verified cache with last-known-good grace |
| `secure_channel.dart` (custom channel crypto) | WebRTC native DTLS-SRTP for media; WSS/HTTPS for signaling and config; no custom cryptography anywhere (audited-library adapters only) |
| v1 ad-hoc reconnect behavior | `call_core/reconnect_policy.dart`: bounded exponential backoff issuing standards-based ICE restarts |

## New in v2 (no v1 equivalent)

- `packages/media_webrtc/` — media engine, RTC stats sampling, adaptive
  quality ladder (v1 had no media layer).
- `packages/signaling/` — versioned envelopes, reliable at-least-once
  outbox, reconnecting WSS client.
- `packages/adaptive_transport/lib/src/circuit_breaker.dart` — explicit
  closed/open/half-open path resting.
- `packages/security/` — device identity (TOFU, safety numbers), log
  redaction.
- `packages/privacy_telemetry/` — opt-in aggregate-only telemetry.
- `security/` + `docs/` governance set; `tool/architecture_guard.dart` CI
  gate.

## Excluded legacy (must never return)

Per the v2 blueprint, the v2 core must not contain:

- domain fronting;
- Host-header override pointing at an unrelated connection target;
- SNI mismatch techniques;
- browser fingerprint imitation;
- VLESS/Reality configuration embedded as the call transport;
- content-review evasion instructions;
- AI-generated runtime code updates.

These are excluded by policy **and** by mechanism: the architecture guard
scans `lib/`, platform folders, and pubspecs on every CI run and fails the
build on any matching dependency, import, or configuration string. The v1
files implementing them were left behind in the v1 archive and have no v2
descendants.

## Migration order for an existing v1 integration

1. Swap transport imports to `package:adaptive_transport/...`; the
   `TransportChannel`/`PathSelector` APIs are source-compatible except the
   renamed health field and the richer `SendStatus`.
2. Replace provisioning calls with `ManifestCache.get()`; ship pinned
   manifest keys in the build.
3. Move any custom channel encryption to plain WSS + the new envelope
   layer; media moves to `WebRtcMediaEngine`.
4. Delete v1 mesh usage; adopt `DeviceLinkAdapter` only if the product
   genuinely needs nearby-device fallback, and wire its consent UI first.
5. Turn on `tool/architecture_guard.dart` in CI before the first v2 build
   ships.
