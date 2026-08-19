# Privacy Design — VoiceCallKit v2

Principle: **data that is never collected cannot be leaked, sold, or
seized.** Every design decision below follows from that.

## What the system knows, component by component

| Component | Knows | Does NOT know / keep |
|---|---|---|
| App (device) | Contacts the user granted, call history kept locally, identity keys | Nothing leaves the device except the flows below |
| Signaling service | Which key ids exchanged envelopes and when (routing metadata) | Envelope payload semantics (opaque), media content, address book |
| Config service | That an app instance fetched a manifest (IP, coarse version) | Who the user is, who they call |
| TURN | Relay of encrypted SRTP between two addresses | Media content (DTLS-SRTP keys never reach TURN) |
| Push provider | That a wake-up was sent to a device token | Caller name/number, call content (payloads are wake-up signals only) |
| Telemetry endpoint | Opt-in aggregate counters/histograms with app version | Identifiers, raw events, timing of individual actions |

## Mechanisms (code-level, not policy-level)

- **Media**: WebRTC DTLS-SRTP end to end; the operator's servers relay
  ciphertext at most (TURN).
- **Telemetry** (`packages/privacy_telemetry`): opt-in gate checked at
  record time (not export time), fixed event allowlist as a Dart enum
  (adding one is a reviewed code change), on-device aggregation, aggregate-
  only export, `purgeLocalData()` on consent revocation.
- **Logs** (`packages/security/.../log_redactor.dart`): every sink sits
  behind `RedactingLogger`; IPs, emails, phone numbers, tokens, key blobs,
  SDP connection/candidate lines are masked at write time. A redaction
  failure drops the line rather than failing open.
- **Local peer path** (`packages/device_link`): radio-visible connectivity
  to nearby devices is privacy-sensitive; therefore it is off by default,
  behind an explicit consent object queried live (revocation is
  immediate), active only in degraded network conditions, and frame
  forwarding is a separate additional opt-in.
- **Identity** (`packages/security/.../identity_store.dart`): identity is
  a device-local key pair, not a phone number or account requirement; key
  ids in envelopes are short fingerprints, not user identifiers.
- **Signaling envelopes**: carry only what routing needs (key id, call id,
  sequence). Deployments that add end-to-end encryption of signaling
  payloads place ciphertext in the envelope `payload` — the schema is
  already opaque-payload-ready.

## Data retention

- Device: call history and pinned identities are user-deletable in place.
- Signaling service: operational logs ≤ 30 days, redacted at write time;
  no envelope payload retention.
- Config service: standard web logs ≤ 30 days, no account linkage.
- Telemetry: aggregates only; the exporter schema has no room for
  identifiers by construction.

## Consent surface

Two independent, revocable, default-off consents, each with a plain-
language explanation in the UI:

1. Nearby-device connectivity (and separately, relaying for others).
2. Telemetry.

Neither is required to make calls.

## What we deliberately do not build

- No address-book upload.
- No server-side call recording of any kind.
- No advertising or analytics SDKs.
- Transparent network behavior: the app uses standard WebRTC/WSS traffic and users are told honestly what that
  behavior looks like to an observer (see `security/THREAT_MODEL.md` §R1).
