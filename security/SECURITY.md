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

Status column reflects this review (2026-07-16, `phase-4/security-identity`);
see `security/THREAT_MODEL.md` §4 for the per-threat evidence this table
summarizes.

| Purpose | Primitive | Implementation rule | Status |
|---|---|---|---|
| Media encryption | DTLS-SRTP | WebRTC platform stack only; never re-implemented | Blocked, dated 2026-07-15 (native `flutter_webrtc` build needs full Xcode) |
| Endpoint manifest signatures | Ed25519 | Audited library (`package:cryptography`) via `Ed25519Verifier` adapter; keys pinned in the app build | Verification logic implemented and tested against fakes (`manifest_verifier_test.dart`). Real-crypto adapter `CryptographyEd25519Verifier` exists but 2 of 8 tests in `crypto_ed25519_verifier_test.dart` fail as of this review — do not treat as production-ready until green. Build-pinned keys: not yet built (no shipped app build exists). |
| Device identity / envelope auth | Ed25519 | Audited library (`package:cryptography`) via `IdentityKeyEngine` / `EnvelopeSigner` adapters; private keys in platform secure storage, hardware-backed where available | Identity engine (`CryptographyIdentityKeyEngine`) implemented and tested (`crypto_identity_engine_test.dart`, `identity_store_e2e_test.dart`, all passing). Envelope crypto adapter (`CryptoEnvelopeSigner`/`Verifier` in `device_link`) implemented, exported, and tested with real keys (15 tests, 100% coverage). Private-key storage: dev-only stores only (`InMemoryKeyStore`, `DevFileKeyStore`); platform Keystore/Keychain blocked, dated 2026-07-15 (needs the Flutter app shell). |
| Fingerprints / safety numbers | SHA-256 | Audited library via adapter | Sign/verify + fingerprint computation implemented and tested (`identity_store_e2e_test.dart`). User-facing comparison UI not yet built (no call UI exists). |
| TURN credential issuance | HMAC-SHA1 (coturn `use-auth-secret` interop requirement, scoped to this one wire format) | Audited library (`package:crypto`); short-lived, expiring credentials | Implemented (`TurnCredentialsIssuer`), no test file yet. Not wired to a live server that hands credentials to clients per call. |
| Key agreement (future E2E signaling payloads) | X25519 | Audited library only | Not yet built — planned for a future signaling-payload confidentiality layer; today signaling confidentiality is transport-level only (WSS), see `docs/DATA_FLOW.md` T18 in the threat model. |

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

- Signaling service (`server/signaling_server`, implemented): stores
  routing state only; message bodies are opaque; retention for
  operational logs is 30 days maximum as a policy target — the redaction
  guarantee itself is proven at the client library layer
  (`packages/security/lib/src/log_redactor.dart`, tested); the signaling
  server's own log output has not been independently audited against
  this table yet.
- Config service (**not yet built** — no `server/config_service` exists
  in this repo): the design is that it would serve signed manifests
  produced by an offline/HSM signing step. Today, manifest signing exists
  only as an offline CLI (`packages/signed_config/bin/sign_manifest.dart`,
  `manifest_keygen.dart`) and manifest *verification* exists client-side
  (`ManifestVerifier`, tested against fakes); there is no live serving
  host to hold this policy accountable to yet.
- TURN: `infra/turn/turnserver.conf` provides the coturn config; short-
  lived credential *issuance logic* exists
  (`packages/security/lib/src/turn_credentials.dart`, tested — known vector + expiry; not yet
  wired to a live issuing service). No media content is ever stored
  (TURN relays encrypted SRTP) — this part follows from the standard
  TURN protocol itself, not from code in this repo.

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
