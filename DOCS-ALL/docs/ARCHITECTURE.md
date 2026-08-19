# Architecture — VoiceCallKit v2

A standards-based, resilient audio/video calling stack for degraded and
unstable network environments. Everything the app does on the network is a
plain, honestly-labelled standard protocol: WebRTC (ICE, STUN, TURN,
DTLS-SRTP) for media, WSS for signaling, HTTPS for configuration, and an
Ed25519-signed manifest for endpoint discovery.

## Layering

```
┌──────────────────────────────────────────────────────────┐
│ apps/resilient_call        Flutter UI, permissions, UX   │
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

## Design rules (enforced)

- Standards only; `tool/architecture_guard.dart` runs in CI and fails the
  build on any excluded legacy transport component (see
  `UPGRADE_BLUEPRINT_V2.md` §Excluded legacy).
- Runtime validation over asserts at every trust boundary.
- No custom cryptography; audited libraries behind narrow adapters.
- Ports-and-adapters at every platform edge (`PeerConnectionPort`,
  `SignalingSocket`, `LocalLinkPort`, `ManifestFetcher`, storage adapters)
  so packages stay pure Dart and unit-testable.
- Every claim the UI makes about connectivity reflects measured state
  (channel scores, breaker states, manifest freshness) — no optimistic
  status.
