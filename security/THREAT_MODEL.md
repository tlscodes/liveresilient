# Threat Model — VoiceCallKit v2

Scope: the v2 calling stack (apps/, packages/, server/, infra/) as laid out
in `docs/ARCHITECTURE.md`. Method: STRIDE per component, plus an explicit
adversary catalogue because this product is designed for degraded and
unreliable, high-packet-loss network environments.

## 1. Assets

- A1. Call audio/video content (highest value).
- A2. Signaling metadata: who calls whom, when, for how long.
- A3. Device identity private key (Ed25519, hardware-backed where available).
- A4. Pinned peer identities (TOFU database).
- A5. Endpoint manifest signing keys (server side, offline/HSM).
- A6. TURN credentials.
- A7. User consent state (nearby connectivity, telemetry).

## 2. Adversaries

- ADV1. **Passive network observer** on any path segment.
- ADV2. **Active network attacker**: injection, replay, connection resets,
  selective packet loss, throttling.
- ADV3. **Malicious or compromised signaling server** (we operate it, but
  the design must not require trusting it for content confidentiality).
- ADV4. **Malicious nearby device** attempting to join the local peer path.
- ADV5. **Compromised config service** attempting to point clients at
  attacker infrastructure.
- ADV6. **Device thief / forensic access** to a powered-off device.
- ADV7. **Malicious app update or supply-chain compromise** of a dependency.

Out of scope: a fully compromised OS/device while unlocked (no client
design survives that), and legal/policy responses to service blocking —
v2 deliberately implements only standard IETF transport (ICE/TURN/WSS); if the
service is unreachable, the app reports that honestly to the user.

## 3. Trust boundaries

- TB1. Device ⇄ signaling service (WSS).
- TB2. Device ⇄ config service (HTTPS + manifest signature).
- TB3. Device ⇄ TURN/STUN (standard ICE; media is DTLS-SRTP end to end).
- TB4. Device ⇄ nearby device (local link; consent-gated).
- TB5. Device ⇄ push provider (wake-up only; payloads carry no content).

## 4. Key threats and mitigations

| # | Threat (STRIDE) | Asset | Mitigation | Where |
|---|---|---|---|---|
| T1 | Spoofed signaling peer (S) | A1, A2 | Device identity keys; session fingerprints signed by identity keys; safety-number comparison; key-change alerts | `security/identity_store.dart`, call UI |
| T2 | Tampered endpoint config (T) | A1, A2 | Ed25519-signed manifest, keys pinned in build, revision monotonicity (anti-rollback), HTTPS-only fetch | `signed_config/*` |
| T3 | Media interception (I) | A1 | WebRTC native DTLS-SRTP; certificate digests bound to identity keys (T1) | `media_webrtc/*` |
| T4 | Metadata harvesting by observer (I) | A2 | TLS everywhere; padding/timing analysis is **accepted residual risk** — documented, not masked | — |
| T5 | Replay of signaling frames (T) | A2 | Envelope `messageId` de-duplication + staleness window | `signaling/*` |
| T6 | Malicious signaling server drops/reorders (D) | A1 | Reliable outbox with acks and retransmission; multi-path failover via PathSelector; user-visible degradation states | `signaling/reliable_outbox.dart`, `adaptive_transport/*` |
| T7 | Rogue nearby device (S/E) | A1, A4 | Local path off by default; explicit consent gate; Ed25519-authenticated envelopes; replay + freshness checks; forwarding disabled by default with hop/TTL caps when enabled | `device_link/*` |
| T8 | Config-service compromise (E) | A5 | Signing keys offline/HSM, never on the serving host; compromise of the web tier cannot mint valid manifests; key rotation + revocation via pinned key set | `signed_config/manifest_verifier.dart`, ops runbook |
| T9 | Device theft (I) | A3, A4 | Identity keys in platform secure storage/hardware; no call content stored; logs redacted | `security/*` |
| T10 | Push-payload leakage (I) | A2 | Push messages are wake-up signals only (no names, numbers, or content); fetch-on-wake over TLS | app layer |
| T11 | Malicious update / dependency (T) | all | Reproducible-build goal, dependency review, `tool/architecture_guard.dart` in CI (blocks excluded legacy components), no runtime code download, no AI-generated runtime code updates | CI |
| T12 | Telemetry as a side channel (I) | A2 | Opt-in only, fixed allowlist, aggregate-only export, no identifiers | `privacy_telemetry/*` |
| T13 | TURN credential abuse (E) | A6 | Short-lived credentials minted per session by config service | server/config_service |
| T14 | Log exfiltration (I) | A2 | Mandatory `LogRedactor` in front of every sink; SDP/candidate summarization | `security/log_redactor.dart` |

## 5. Residual risks (accepted, stated honestly)

- R1. Traffic analysis of encrypted flows can reveal that a call is
  happening and approximate duration. v2 uses standard, observable transport and does not reshape its
  traffic as something else.
- R2. The signaling server necessarily learns call metadata (A2). Server
  data-minimization and retention limits (see `SECURITY.md`) reduce, but
  cannot eliminate, this.
- R3. TOFU pinning is vulnerable at first contact; safety-number
  verification exists precisely to close this when users perform it.
- R4. A total network outage or complete service block stops calls. The
  local peer path only helps devices within radio range of each other.

## 6. Review cadence

This document is reviewed at every milestone release and whenever a new
component crosses a trust boundary. Changes require security sign-off per
`INCIDENT_RESPONSE.md` ownership.
