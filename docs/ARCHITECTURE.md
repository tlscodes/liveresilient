# Architecture — VoiceCallKit v3

A standards-based, resilient audio/video calling stack for degraded and
unstable network environments. Everything the app does on the network is a
plain, honestly-labelled standard protocol: WebRTC (ICE, STUN, TURN,
DTLS-SRTP) for media, WSS for signaling, HTTPS for configuration and for the
relay/long-poll fallback lanes, and an Ed25519-signed manifest for endpoint
discovery.

> **Scope correction, 2026-07-31 (documented contradictions 8 and 9).** Two
> things in this document were behind the code:
>
> - The app directory is **`apps/reference_app`**, not `apps/resilient_call`.
>   Ground truth is the filesystem and the workspace gate, which report
>   `reference_app`; the old name is gone.
> - The sections below described only the WebRTC + WSS path. v3 also ships a
>   deployed HTTPS relay, an HTTP long-poll lane, a store-and-forward DTN
>   queue, a broadcast layer, and a low-rate codec as a last-resort audio
>   path. They are listed in §"v3 layers" below rather than left out.
>
> Still true, and enforced: `tool/architecture_guard.dart` fails CI on any
> excluded legacy transport component, and the project makes **no attempt to
> disguise its traffic as another protocol**. Every lane named here is a
> standard protocol used as itself.

## Layering

```
┌──────────────────────────────────────────────────────────┐
│ apps/reference_app         Flutter UI, permissions, UX   │
├──────────────────────────────────────────────────────────┤
│ call_core                  Call state machine, controller│
│                            ICE-restart reconnect policy  │
├───────────────┬──────────────────────┬───────────────────┤
│ media_webrtc  │ signaling            │ signed_config     │
│ engine, stats │ WSS client, envelope │ manifest model,   │
│ sampler,      │ reliable outbox      │ Ed25519 verifier, │
│ adaptive      │ (at-least-once +     │ verified cache    │
│ media policy  │ de-duplication)      │ (anti-rollback)   │
├───────────────┴──────────────────────┴───────────────────┤
│ adaptive_transport        TransportChannel abstraction, │
│                            EWMA health, PathSelector    │
│                            (failover + fanout), circuit  │
│                            breaker                       │
├──────────────────────────────────────────────────────────┤
│ device_link                 consent-gated nearby link     │
│ (degraded mode only)       authenticated envelopes, link │
│                            processor (forwarding opt-in) │
├──────────────────────────────────────────────────────────┤
│ security                   identity store (Ed25519/TOFU) │
│ privacy_telemetry          log redactor; opt-in aggregate│
│                            telemetry                     │
└──────────────────────────────────────────────────────────┘
   server/signaling      server/config_service     infra/coturn
```

## Package responsibilities

- **call_core** — platform-independent call orchestration: `CallState`
  machine, `CallController` driving offer/answer over signaling, and
  `ReconnectPolicy` (bounded exponential backoff producing standards-based
  ICE restarts, never custom transport tricks).
- **media_webrtc** — `WebRtcMediaEngine` wraps the platform peer
  connection behind `PeerConnectionPort` (no plugin dependency in the
  package); `RtcStatsSampler` turns cumulative `getStats()` counters into
  smoothed per-interval samples; `AdaptiveMediaPolicy` walks a
  high→audio-only quality ladder with fast-down/slow-up hysteresis;
  `media_adaptation.dart` provides an adaptive jitter buffer for
  non-WebRTC datagrams.
- **signaling** — `SignalEnvelope` (versioned, validated),
  `ReliableOutbox` (at-least-once with acks, backoff, persistence hook,
  receiver-side de-duplication), `SignalingClient` (WSS, reconnect with
  jittered backoff, heartbeats, liveness timeout).
- **adaptive_transport** — the v1 crown jewels, ported: `ChannelHealth`
  EWMA availability/RTT/jitter scoring, `PathSelector` with ranked
  failover and fanout redundancy, `NetworkConditionPolicy` mapping observed
  conditions to redundancy levels, plus a new per-path `CircuitBreaker`
  and strict `HostPort` parsing.
- **signed_config** — replaces all v1 dynamic-provisioning machinery with
  one primitive: fetch manifest over HTTPS → verify Ed25519 signature
  against build-pinned keys → enforce validity window and monotonic
  revision → cache with last-known-good grace.
- **device_link** — a last-resort path between nearby consenting devices:
  every frame Ed25519-signed (`AuthenticatedEnvelope`), replay-rejected,
  and the adapter activates only when the user opted in AND the network is
  degraded. Multi-hop forwarding exists (`LinkMessageProcessor`) but ships
  **off by default** with hop and lifetime caps.
- **security** — device identity (audited-crypto adapters, TOFU pinning,
  safety numbers, key-change alerts) and mandatory log redaction.
- **privacy_telemetry** — opt-in, allowlisted, aggregate-only.

## Data flow of a call

1. App boots → `ManifestCache.get()` returns verified endpoints.
2. `SignalingClient` connects to the first healthy WSS endpoint.
3. `CallController` creates an offer via `WebRtcMediaEngine`; the offer
   travels as a `SignalEnvelope` through the `ReliableOutbox`.
4. ICE gathers candidates against the manifest's STUN/TURN servers; media
   flows peer-to-peer or via TURN, encrypted with DTLS-SRTP.
5. `RtcStatsSampler` feeds `AdaptiveMediaPolicy`; quality steps down under
   loss and recovers conservatively.
6. On path loss, `ReconnectPolicy` schedules ICE restarts; signaling rides
   `PathSelector` failover (WSS endpoints, push wake-up, and — only with
   consent, only when degraded — the local peer path).

## v3 layers (added after the v2 text above)

- **connection_orchestrator** — one fabric over every lane. Ranks lanes by
  measured health and cost, delivers live-first, and falls back to a bounded
  store-and-forward queue (`DtnBundleQueue`) when every lane is down. It
  reports what it actually did (`sentLive` / `queuedForLater`) and never
  reports success on a caller's behalf. Invariants are pinned by a chaos
  suite over twelve fixed seeds plus a frozen-digest reproducibility gate
  (`test/chaos_fabric_test.dart`).
- **Resilient fallback lanes** (`adaptive_transport/lib/src/resilient/`) —
  UDP → WebSocket relay → HTTP long-poll → local mesh, each a plain standard
  protocol, tried in order as the preceding one dies. `PoissonPacer` spaces
  sends by an exponential distribution instead of a fixed timer.
- **Deployed relay** (`tools/cloudflare_relay_worker`) — pairs two peers by
  session id and passes bytes through untouched. Known limits, stated: no
  peer authentication, no persistence, 256-frame / 4 MB queue cap, 25 s hold.
  The session id is therefore a secret (see `security/THREAT_MODEL.md` T26).
- **broadcast / broadcast_media** — signed one-to-many publishing: a
  fixed-length descriptor commits to each layer's hash and is signed by a
  delegated publishing key chaining to a root key. No variable-length head,
  no "latest" pointer.
- **hamseda_codec** — a last-resort very-low-rate audio path for links too
  narrow for Opus. It is a survival path, not a privacy feature, and its
  31.8 bps figure is labelled "measured on a recording, not on a live call"
  wherever it appears.
- **device_link / carrier lanes** — consent-gated nearby and carrier paths,
  unchanged in kind from v2, now driven through the fabric.

Known open defect on this layer: `micro_datagram_lane.dart:32` overflows when
`mtuBlockSize > 224` (2026-07-27 framing audit,
`docs/AUDIT_PLAN_media_transport_framing.md` §1).

What v3 does **not** have, stated here so nobody infers it from the list
above: no measurement of how distinguishable this traffic is, and no
size/timing shaping. The fixed 25 s long-poll cadence is a known fingerprint.

## Design rules (enforced)

- Standards only; `tool/architecture_guard.dart` runs in CI and fails the
  build on any excluded legacy transport component (see
  `UPGRADE_BLUEPRINT_V3.md`; the v2 blueprint this line used to cite is not in
  this repo).
- Runtime validation over asserts at every trust boundary.
- No custom cryptography; audited libraries behind narrow adapters.
- Ports-and-adapters at every platform edge (`PeerConnectionPort`,
  `SignalingSocket`, `LocalLinkPort`, `ManifestFetcher`, storage adapters)
  so packages stay pure Dart and unit-testable.
- Every claim the UI makes about connectivity reflects measured state
  (channel scores, breaker states, manifest freshness) — no optimistic
  status.
