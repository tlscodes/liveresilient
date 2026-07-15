# Security Policy — VoiceCallKit v2

## Reporting a vulnerability

- Email: security@ (project operator address; see repository metadata).
- Please include reproduction steps, affected component/package, and an
  impact assessment if you have one.
- We acknowledge reports within **72 hours** and aim to provide a triage
  decision within **7 days**.
- Coordinated disclosure: we ask for 90 days or a mutually agreed timeline
  before publication. We credit reporters unless they ask to stay unnamed.
- Do not test against production infrastructure with real users' traffic;
  a staging environment is available on request.

## Cryptography inventory

| Purpose | Primitive | Implementation rule |
|---|---|---|
| Media encryption | DTLS-SRTP | WebRTC platform stack only; never re-implemented |
| Endpoint manifest signatures | Ed25519 | Audited library via `Ed25519Verifier` adapter; keys pinned in the app build |
| Device identity / envelope auth | Ed25519 | Audited library via `IdentityKeyEngine` / `EnvelopeSigner` adapters; private keys in platform secure storage, hardware-backed where available |
| Fingerprints / safety numbers | SHA-256 | Audited library via adapter |
| Key agreement (future E2E signaling payloads) | X25519 | Audited library only |

Standing rules:

1. **No custom cryptography.** All primitives come from audited libraries
   behind narrow adapters; this repo contains no hash, cipher, or signature
   implementations.
2. **No secret material in Dart heaps longer than necessary.** Sign-by-
   handle: private keys stay inside platform keystores.
3. **All transport is standard TLS-family**: HTTPS, WSS, DTLS-SRTP,
   TURN/TLS. The architecture guard (`tool/architecture_guard.dart`) fails
   CI if excluded legacy transport components reappear.
4. **No runtime code download and no AI-generated runtime code updates.**
   Behavior changes ship only through reviewed, signed app releases.

## Server-side data handling

- Signaling service: stores routing state only; message bodies are opaque;
  logs pass through redaction equivalent to `LogRedactor`; retention for
  operational logs is 30 days maximum.
- Config service: serves signed manifests; signing keys live offline/HSM
  and are used in an air-gapped signing step.
- TURN: short-lived credentials; no media content is ever stored (TURN
  relays encrypted SRTP).

## Dependency and release policy

- Dependency changes require review; new dependencies need a maintenance
  and audit-status check.
- CI runs: analyzer, tests, `tool/architecture_guard.dart`, and dependency
  pinning verification on every merge.
- Releases are tagged, signed, and reproducible-build is a tracked goal.

## Key rotation and revocation

- Manifest signing keys: rotate by shipping app builds with the new pinned
  public key alongside the old, then signing with the new key; revoke by
  marking the pinned entry revoked in the next release.
- Device identity keys: users can regenerate; peers see an explicit
  key-change warning and must re-verify safety numbers.
