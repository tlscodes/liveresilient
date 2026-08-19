# Threat Model — VoiceCallKit v3

Scope: the v3 stack (apps/, packages/, server/, infra/, the deployed relay
worker) as laid out in `docs/ARCHITECTURE.md`. Method: STRIDE per component,
plus an explicit adversary catalogue because this product is designed for
degraded and unreliable, high-packet-loss network environments.

Data flow and trust boundaries are diagrammed in `docs/DATA_FLOW.md`.

## Version note (2026-07-31)

Sections 1–7 below were written for **v2** and are kept verbatim, because
every one of their 24 threats still applies to code that still ships —
identity, signed config, device link, telemetry, log redaction, TURN
credentials. **Section 8 is the v3 delta**: the components that did not
exist in v2 (broadcast, connection_orchestrator, the deployed Cloudflare
relay, the HTTP long-poll lane, the low-rate codec, the DTN bundle queue),
their threats, and the two claims v3 must NOT make.

The architecture review dated 2026-07-27 recorded "no `THREAT_MODEL.md`
exists". That was wrong about the file and right about the substance: the
file existed, but it covered v2 only. This version closes that gap; it does
not pretend the gap never existed.

Constraint that binds every entry here: `tool/architecture_guard.dart` fails
CI on any excluded legacy transport component (sing-box, VLESS, Reality,
front-domain, obfuscation profiles, manual Host-header overrides, TLS
fragmentation/padding). Nothing in this document may be mitigated by
protocol mimicry — v3 keeps the project's own red line: **no attempt is made
to disguise call traffic as some other protocol.**

## Status legend (evidence discipline)

Every mitigation below is tagged with one status, and every tag names the
file(s)/test(s) that back it. Sections 1–7 were tagged as of 2026-07-16
(phase-4/security-identity branch); section 8 as of 2026-07-31 on `main`.
A status with no evidence is a bug in this document, not a fact
about the code — report it instead of leaving it unmarked.

- **implemented** — real code + passing tests exist; both are cited.
- **implemented, untested** — real code exists, but no test file exercises
  it yet. Cited as a gap, not claimed as verified.
- **landing this wave — verify before merge** — code and/or tests exist but
  a test run at review time showed failures, or the code isn't wired into
  its package's public API yet. The failure/gap is stated explicitly.
- **interface-only** — an abstract port/contract exists; no concrete,
  production-usable implementation is wired up yet.
- **blocked, dated** — known blocker with a recorded date and cause.
- **not yet built** — scoped for a later phase per `docs/EXECUTION_PLAYBOOK.md`;
  no code exists.

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
- ADV8. **Party to a compromised manifest-signing key** attempting to mint
  or keep using manifests after compromise is discovered.
- ADV9. **Holder of a leaked/logged TURN credential** attempting to reuse
  it after the call it was issued for ends.
- ADV10. **Attacker with coarse clock control** over one endpoint (NTP
  spoofing, manual clock change) attempting to widen or defeat a
  time-bounded check.

Out of scope: a fully compromised OS/device while unlocked (no client
design survives that), and legal/policy responses to service blocking —
the stack deliberately implements only standard IETF transport
(ICE/TURN/WSS, plus the HTTPS relay and long-poll lane added in v3); if the
service is unreachable, the app reports that honestly to the user.

## 3. Trust boundaries

- TB1. Device ⇄ signaling service (WSS).
- TB2. Device ⇄ config service (HTTPS + manifest signature).
- TB3. Device ⇄ TURN/STUN (standard ICE; media is DTLS-SRTP end to end).
- TB4. Device ⇄ nearby device (local link; consent-gated).
- TB5. Device ⇄ push provider (wake-up only; payloads carry no content).

See `docs/DATA_FLOW.md` for the diagram and the per-boundary "what crosses
it" table.

## 4. Key threats and mitigations

| # | Threat (STRIDE) | Asset | Mitigation | Status | Evidence |
|---|---|---|---|---|---|
| T1 | Spoofed signaling peer (S) | A1, A2 | Device identity keys (Ed25519); session fingerprints signed by identity keys; safety-number comparison; key-change alerts | Identity keys + fingerprint sign/verify + TOFU key-change detection: **implemented**. Safety-number comparison UI: **not yet built** (no call UI exists yet; Phase 9) | `packages/security/lib/src/crypto_identity_engine.dart`, `identity_store.dart` — tests `packages/security/test/crypto_identity_engine_test.dart` (13/13 pass), `packages/security/test/identity_store_e2e_test.dart` (fingerprint round-trip + "a different key on later contact is reported as changed", part of security's 30/30 pass) |
| T2 | Tampered endpoint config (T) | A1, A2 | Ed25519-signed manifest, keys pinned in build, revision monotonicity (anti-rollback), HTTPS-only fetch | Verification logic (revocation, expiry, rollback) against a fake signer: **implemented**. Real Ed25519 backing (`CryptographyEd25519Verifier`): **implemented** (the accept-path failures recorded earlier on 2026-07-16 are fixed — full crypto suite green on re-run later the same day, see Evidence). Build-pinned keys in a shipped app: **not yet built** (no app build exists). Live HTTPS config-serving endpoint: **not yet built** (no `config_service` directory exists in this repo; only an offline signer CLI, see T8) | `packages/signed_config/lib/src/manifest_verifier.dart` — `manifest_verifier_test.dart` (fake-crypto, all pass); `packages/signed_config/lib/src/crypto_ed25519_verifier.dart` — `crypto_ed25519_verifier_test.dart` re-run 2026-07-16 (phase-7): **10/10 pass**, including "accepts a manifest signed by its pinned key" and "manifest signed by the newly-rotated-in key is accepted"; independently confirmed with real keys end to end by `key_rotation_test.dart` (8/8 pass) and `sign_manifest_cli_test.dart` |
| T3 | Media interception (I) | A1 | WebRTC native DTLS-SRTP; certificate digests bound to identity keys (T1) | **blocked, dated** — native `flutter_webrtc` build needs full Xcode (only CommandLineTools present as of 2026-07-15); tracked in `docs/EXECUTION_PLAYBOOK.md` Phase 3 status | `docs/EXECUTION_PLAYBOOK.md:114` |
| T4 | Metadata harvesting by observer (I) | A2 | TLS everywhere; padding/timing analysis is **accepted residual risk** — documented, not masked | not a mitigation to implement; see R1 | — |
| T5 | Replay of signaling frames (T) | A2 | Envelope `messageId` de-duplication + staleness window | **implemented** | `packages/signaling/lib/src/reliable_outbox.dart`, `signal_envelope.dart` — `reliable_outbox_test.dart` ("duplicate enqueue of the same messageId keeps a single pending ..."), `signal_envelope_test.dart` |
| T6 | Malicious signaling server drops/reorders (D) | A1 | Reliable outbox with acks and retransmission; multi-path failover via PathSelector; user-visible degradation states | **implemented** | `packages/signaling/lib/src/reliable_outbox.dart`, `packages/adaptive_transport/lib/src/path_selector.dart` — respective `test/` suites (Phase 2 deterministic-core coverage) |
| T7 | Rogue nearby device (S/E) | A1, A4 | Local path off by default; explicit consent gate; Ed25519-authenticated envelopes; replay + freshness checks; forwarding disabled by default with hop/TTL caps when enabled | Protocol logic (nonce replay rejection, staleness window, consent gate, hop/TTL caps): **implemented**. Real Ed25519 signer/verifier (`CryptoEnvelopeSigner`/`CryptoEnvelopeVerifier`): **implemented and tested** — exported from the package barrel; real-key tests cover tamper/replay/stolen-key/forwarding (`crypto_envelope_auth_test.dart`, `crypto_media_frame_auth_test.dart`, 15 tests, 100% line coverage) | `packages/device_link/lib/src/authenticated_envelope.dart`, `device_link_adapter.dart` — `authenticated_envelope_test.dart` + `device_link_adapter_test.dart` (34/34 pass, against fakes); `packages/device_link/lib/src/crypto_envelope_auth.dart`, `crypto_media_frame_auth.dart` — `crypto_envelope_auth_test.dart` + `crypto_media_frame_auth_test.dart` (49/49 package tests pass) |
| T8 | Config-service compromise (E) | A5 | Signing keys offline/HSM, never on the serving host; compromise of the web tier cannot mint valid manifests; key rotation + revocation via pinned key set | Offline signing tool + revocation-by-pinned-key-set logic: **implemented**. A live config-serving host to compromise: **not yet built** (no `server/config_service`; only `server/signaling_server` exists) | `packages/signed_config/bin/sign_manifest.dart`, `packages/signed_config/bin/manifest_keygen.dart` (offline CLI signer/keygen); `packages/signed_config/lib/src/manifest_verifier.dart` revocation path — `manifest_verifier_test.dart` ("rejects a revoked signing key", pass); ops runbook: `security/INCIDENT_RESPONSE.md` |
| T9 | Device theft (I) | A3, A4 | Identity keys in platform secure storage/hardware; no call content stored; logs redacted | Key-handle abstraction + dev-only stores: **implemented** (tests pass). Production platform-secure-storage adapter (iOS Keychain / Android Keystore, hardware-backed where available): **blocked, dated 2026-07-15** — needs the Flutter app shell (tracked in code comment, not yet in EXECUTION_PLAYBOOK). Log redaction: **implemented** | `packages/security/lib/src/key_store.dart` (`InMemoryKeyStore`, and `DevFileKeyStore` — explicitly dev-only, plaintext-on-disk, documented as such in its doc comment) — no dedicated key_store test file yet, exercised indirectly via `crypto_identity_engine_test.dart`'s `DevFileKeyStore` group (2 tests, pass); `packages/security/lib/src/log_redactor.dart` — `log_redactor_test.dart` (5/5 pass) |
| T10 | Push-payload leakage (I) | A2 | Push messages are wake-up signals only (no names, numbers, or content); fetch-on-wake over TLS | **not yet built** — push wake-up (`PushWakeup`) is scoped for Phase 8 (`docs/EXECUTION_PLAYBOOK.md:133`); no push code exists in this repo yet | `docs/EXECUTION_PLAYBOOK.md:133` |
| T11 | Malicious update / dependency (T) | all | Reproducible-build goal, dependency review, `tool/architecture_guard.dart` in CI (blocks excluded legacy components), no runtime code download, no AI-generated runtime code updates | Architecture guard: **implemented**. Reproducible-build pipeline: **not yet built** (tracked as a goal in `security/SECURITY.md`, no CI step yet) | `tool/architecture_guard.dart` (present, wired as `melos run guard` per `README.md`) |
| T12 | Telemetry as a side channel (I) | A2 | Opt-in only, fixed allowlist, aggregate-only export, no identifiers | **implemented** | `packages/privacy_telemetry/lib/src/privacy_telemetry.dart` — `privacy_telemetry_test.dart` (7/7 pass) |
| T13 | TURN credential abuse (E) | A6 | Short-lived credentials minted per session by config service | Credential-minting logic (coturn `use-auth-secret` HMAC scheme, expiry check): **implemented and tested** — known-vector + expiry-boundary tests (`turn_credentials_test.dart`, 10 tests, 100% line coverage). Wiring into a live config/signaling service that actually hands these to clients per-call: **not yet built** | `packages/security/lib/src/turn_credentials.dart` (`TurnCredentialsIssuer`, `TurnCredentials.isExpired`) — `packages/security/test/turn_credentials_test.dart` (verified present 2026-07-31; the earlier "no test file found" note in this row was stale and contradicted the row's own status, so it is removed) |
| T14 | Log exfiltration (I) | A2 | Mandatory `LogRedactor` in front of every sink; SDP/candidate summarization | **implemented** | `packages/security/lib/src/log_redactor.dart` — `log_redactor_test.dart` (5/5 pass, incl. `redactSdp` candidate/connection-line handling) |
| T15 | Stolen device identity key (E) | A3, A4 | Key regeneration on suspected compromise; peers see an explicit key-change warning and must re-verify safety numbers before trusting the new key | Key-change detection logic: **implemented**. User-facing regenerate action + safety-number re-verify UI: **not yet built** (no call UI yet) | `packages/security/lib/src/identity_store.dart` (`RemoteIdentityCheck.changed`) — `identity_store_e2e_test.dart` ("a different key on later contact is reported as changed", pass); policy stated in `security/SECURITY.md` "Key rotation and revocation" |
| T16 | Replayed TURN credential (S/E) | A6 | HMAC-based credential carries its own expiry (coturn `use-auth-secret`); a captured/logged credential stops working once `expiresAt` passes; default TTL 1 hour | **implemented and tested** — same code as T13 (`turn_credentials_test.dart`, expiry boundary covered) | `packages/security/lib/src/turn_credentials.dart` |
| T17 | Manifest signer key compromise (E) | A5 | Signing key kept offline/HSM (never on a serving host); compromised key is added to the pinned-set `revokedKeyIds`; new key ships in the next app build and old key stops verifying immediately | Revocation-by-pinned-set logic: **implemented**. Formal key-rotation runbook (who signs, how the compromise is confirmed, how fast a build with the revocation ships): **not yet built** — `security/SECURITY.md` states the mechanism, but there is no step-by-step incident runbook for this specific case beyond the general `security/INCIDENT_RESPONSE.md` | `packages/signed_config/lib/src/manifest_verifier.dart` — `manifest_verifier_test.dart` ("rejects a revoked signing key", "manifest signed by the newly-rotated-in key is accepted while both keys are pinned and unrevoked" — both pass against the fake verifier); `security/SECURITY.md` "Key rotation and revocation" |
| T18 | Signaling relay tampering / reads payload semantics (T/I) | A2 | Transport confidentiality/integrity from WSS (TB1) today; the envelope schema is opaque-payload-ready for a future end-to-end signaling-payload encryption layer (X25519 key agreement, listed in `security/SECURITY.md`'s crypto inventory as future work) | **not yet built** — no signaling-payload-level (app-layer, beyond TLS) encryption exists; a compromised signaling server today can read envelope fields the schema exposes (key id, call id, sequence — see `docs/PRIVACY.md`), matching R2 below | `docs/PRIVACY.md` §"Signaling envelopes"; `security/SECURITY.md` cryptography inventory ("Key agreement (future E2E signaling payloads)") |
| T19 | Clock skew (D/T) | A2, A5, A6 | Time-bounded checks (manifest `expired`/`notYetValid`, TURN credential expiry, envelope staleness window) use an injectable clock so tests pin exact boundaries; production has no adaptive skew-tolerance margin beyond the window itself | **implemented** for the deterministic window checks (tested against a fake/pinned clock). **Accepted residual risk**: a device with a materially wrong system clock can have valid manifests/credentials rejected as expired/not-yet-valid early, or (bounded by the window width) accept slightly-stale ones late; no NTP-sync or skew-detection mechanism exists | `packages/signed_config/lib/src/manifest_verifier.dart` (`ManifestRejection.expired`/`.notYetValid`) — `manifest_verifier_test.dart` ("rejects an expired manifest", "rejects a manifest not yet valid", pass); `packages/security/lib/src/turn_credentials.dart` (`isExpired`, uses `package:clock`); `packages/device_link/lib/src/authenticated_envelope.dart` staleness window — `authenticated_envelope_test.dart` ("an envelope delivered outside the freshness window is rejected as stale", pass) |
| T20 | Single config-origin outage (D) | A1, A2 | Manifest schema v2 lists ≥2 `configServiceUris`; the cache fails over across listed origins in order, and any origin's response counts only after full signature verification — availability never buys authenticity | Schema v2 multi-origin field (https-only, validated): **implemented**. Cache-level multi-origin failover: **landing this wave — verify before merge** (Wave 2A lands it concurrently with this review; the Wave-1 cache used only the primary origin) | `packages/signed_config/lib/src/endpoint_manifest.dart` (`configServiceUris`, https-only) — `endpoint_manifest_test.dart`, `sign_manifest_cli_test.dart` (both pass); failover: `packages/signed_config/lib/src/manifest_cache.dart` — `packages/signed_config/test/multi_origin_cache_test.dart`, `packages/signed_config/test/https_loopback_discovery_test.dart` (Wave 2A) |
| T21 | Malicious/compromised config origin serves tampered or stale manifests (T/S) | A1, A2 | A fetched document is accepted only with a valid Ed25519 signature by a pinned, non-revoked key over the manifest's canonical bytes; monotonic revision check (`lastAcceptedRevision`) rejects stale-but-authentic replays, so a hostile origin can at worst withhold service (see T20), never alter or roll back config | **implemented** — real Ed25519, not fakes | `packages/signed_config/lib/src/manifest_verifier.dart`, `crypto_ed25519_verifier.dart` — `crypto_ed25519_verifier_test.dart` (10/10 pass, run 2026-07-16), `manifest_verifier_test.dart` (pass), `key_rotation_test.dart` (real-crypto replay + rollback rejection, 8/8 pass) |
| T22 | Signing-key compromise across a rotation window (E) | A5 | Overlap rotation: old + new keys pinned together, so manifests signed by either key verify during rotation (no verification-outage moment); the compromised key is then pinned `revoked: true` — revocation is checked before the time-window and rollback checks, so even a freshly minted HIGHER revision signed by the revoked key is rejected (`revokedSigningKey` beats freshness) | **implemented** | `packages/signed_config/lib/src/manifest_verifier.dart` (`PinnedManifestKey.revoked`, `verify()` check ordering) — `packages/signed_config/test/key_rotation_test.dart` (8/8 pass, real Ed25519: 3-epoch rotation; replayed rev 1 AND attacker rev 99 by the revoked key both rejected `revokedSigningKey`); mechanism policy: T17, `security/SECURITY.md` "Key rotation and revocation" |
| T23 | DNS hijack / redirect of config fetch to an attacker origin (S) | A1, A2 | Config URIs are https-only (TLS server authentication), and — decisively — trust is anchored in the PINNED SIGNING KEY, not the origin: whichever host serves the bytes, a manifest is accepted only under a pinned non-revoked key's signature; signatures by unpinned keys are rejected | Verifier logic + https-only URI validation: **implemented**. Real-socket HTTPS discovery exercise: **landing this wave — verify before merge** (Wave 2A) | `packages/signed_config/lib/src/endpoint_manifest.dart` (https-only `configServiceUris`), `manifest_verifier.dart` — `key_rotation_test.dart` ("unpinned keyC ... rejected unknownSigningKey", pass); wire path: `packages/signed_config/test/https_loopback_discovery_test.dart` (Wave 2A) |
| T24 | Grace-window abuse: keeping clients on an expired last-known-good manifest indefinitely (T/D) | A1, A2 | Last-known-good fallback applies only to already-signature-verified manifests and is bounded by `lastKnownGoodGrace` (default 7 days past `expiresAt`); beyond the grace end the cache fails closed instead of serving arbitrarily stale config | **implemented** (within-grace accept path tested; Wave 2A extends cache coverage) | `packages/signed_config/lib/src/manifest_cache.dart` (`ManifestCacheConfig.lastKnownGoodGrace`, grace-end check) — `manifest_cache_test.dart` ("initialize() accepts an expired-but-authentic stored manifest as last-known-good (grace path)", pass); `packages/signed_config/test/multi_origin_cache_test.dart` (Wave 2A) |

## 5. Residual risks (accepted, stated honestly)

- R1. Traffic analysis of encrypted flows can reveal that a call is
  happening and approximate duration. The stack uses standard, observable
  transport and does not reshape its traffic as something else. See R6/T27
  for what v3 measured about this — which is: nothing yet.
- R2. The signaling server necessarily learns call metadata (A2). Server
  data-minimization and retention limits (see `SECURITY.md`) reduce, but
  cannot eliminate, this. See T18: no app-layer encryption of signaling
  payloads exists yet, so this is broader than a compromised-server
  scenario — it applies to the operator's normal operation too.
- R3. TOFU pinning is vulnerable at first contact; safety-number
  verification exists precisely to close this when users perform it —
  and note (T1, T15) the verification UI itself is not yet built.
- R4. A total network outage or complete service block stops calls. The
  local peer path only helps devices within radio range of each other.
- R5. No adaptive clock-skew tolerance (T19): the mitigation is a fixed
  window, not skew detection: a device with a badly wrong clock degrades
  (calls fail to set up) rather than silently accepting stale material
  outside a reasonable margin — a deliberate fail-closed choice, recorded
  here so it isn't mistaken for an oversight.

## 6. Open blockers (dated, tracked — never silently deferred)

- OS Keystore/Keychain-backed `KeyMaterialStore` (T9, T15): blocked
  2026-07-15, needs the Flutter app shell to exist before a platform
  channel/plugin can be wired in. Until then, only `InMemoryKeyStore`
  (tests) and `DevFileKeyStore` (explicitly dev-only, plaintext) exist —
  neither is safe to ship. See `packages/security/lib/src/key_store.dart`.
- Native WebRTC media path (T3): blocked 2026-07-15, full Xcode not
  installed (only CommandLineTools); see
  `docs/EXECUTION_PLAYBOOK.md:114`.
- Real-2-device call test (T3, general): blocked, needs physical devices;
  same `EXECUTION_PLAYBOOK.md` line.
- `CryptographyEd25519Verifier` accept-path failure (T2): **resolved
  2026-07-16** (phase-7) — `crypto_ed25519_verifier_test.dart` re-run is
  10/10 green, and `key_rotation_test.dart` (8/8, real Ed25519 signing
  end to end) independently confirms the accept path. Entry retained,
  struck, per the archive-don't-delete rule.

## 7. Review cadence

This document is reviewed at every milestone release and whenever a new
component crosses a trust boundary. Changes require security sign-off per
`INCIDENT_RESPONSE.md` ownership.

---

## 8. The v3 delta

Everything in this section covers components that did not exist when
sections 1–7 were written. Same evidence discipline: a status with no
evidence is a bug in this document.

### 8.1 New assets

- A8. Broadcast root signing key and the delegated publishing key
  (`packages/broadcast`) — the anchor of every post a reader trusts.
- A9. Relay session identifier. The deployed Cloudflare relay pairs two
  peers by session id and authenticates nobody, so **the session id is a
  secret**, not a name. Anyone holding it is a peer.
- A10. DTN bundle queue contents (`DtnBundleQueue`) — payloads parked on
  the device while every lane is down.
- A11. Relay quota/budget. Not a confidentiality asset; an availability and
  cost asset. It is the asset the architecture review named first.

### 8.2 New adversaries

- ADV11. **Traffic classifier on the path** (DPI or equivalent) trying to
  decide *this flow is this product* from packet sizes and timing alone —
  not to read the content, which DTLS-SRTP already denies it.
- ADV12. **Quota-burn attacker** posting to the relay with no intent to
  call, to exhaust the free tier and take the service down by invoice.
- ADV13. **Relay operator or anyone who observes the relay** — the relay
  passes bytes through untouched and holds no persistence, but it sees
  pairing, size and timing.
- ADV14. **Broadcast forger / equivocator** — an adversary who tries to
  publish under someone else's identity, or to show two different readers
  two different chains from the same author.

### 8.3 New trust boundaries

- TB6. Device ⇄ Cloudflare relay worker (HTTPS; unauthenticated pairing by
  session id; bytes passed through unmodified).
- TB7. Device ⇄ device over the local mesh / carrier lane
  (`connection_orchestrator`), consent-gated exactly as TB4.
- TB8. Reader ⇄ broadcast chain (data at rest on any host; trust comes from
  the signature over the descriptor, never from the host that served it).

### 8.4 New threats

| # | Threat (STRIDE) | Asset | Mitigation | Status | Evidence |
|---|---|---|---|---|---|
| T25 | Relay quota exhaustion / denial by invoice (D) | A11 | Per-session frame cap (256 frames, 4 MB) and a bounded 25 s hold; no unbounded fan-out | **implemented, partial** — the caps exist and bound one session, but the relay authenticates no peer, so an attacker can open sessions without limit. Per-peer authentication: **not yet built**; it is the architecture review's own "needed for economics, not for confidentiality" finding | `tools/cloudflare_relay_worker/src/worker.js` (queue cap, 25 s hold); `docs/ARCHITECTURE_REVIEW_2026.md` (relay-auth finding) |
| T26 | Session-id disclosure gives a stranger a peer seat (S) | A9 | The session id is generated per call and treated as a secret; it is never logged (`LogRedactor`) and never put in a URL that is shown to a third party | **implemented for the client side**; the relay itself has **no** peer authentication, so the id is the only thing standing between a stranger and the session | `packages/security/lib/src/log_redactor.dart` — `log_redactor_test.dart`; relay limitation recorded in `DOCS-ALL/FINAL-REPORT.md` §10a |
| T27 | Flow classification by size and timing (I) | A2 | None claimed. The HTTP long-poll lane's fixed 25 s cadence is a strong fingerprint; the audit's cheap remedy (randomise the hold to 15–25 s and pad onto a size lattice) is **not implemented** | **not yet built** — and, decisively, **not measured**: no test in this repo scores the indistinguishability of the product's own traffic. This is the largest open gap in v3 | `docs/ARCHITECTURE_REVIEW_2026.md` (25 s cadence finding); gap tracked as B-1/B-5 in `../questions/REMAINING-AND-MERGE-PLAN.md` |
| T28 | Parked bundles read off a lost device (I) | A10, A1 | The DTN queue is bounded (bundle count + byte cap) and drops rather than growing; contents live only in process memory today | **implemented** for the bounds. At-rest encryption of a persisted queue: **not yet built** — there is no persistent queue yet, so there is nothing encrypted and nothing to claim | `packages/device_link/lib/src/dtn_bundle_queue.dart` — `dtn_bundle_queue_test.dart`; overflow behaviour pinned by `packages/connection_orchestrator/test/chaos_fabric_test.dart` ("the queue drops rather than growing without bound", "a critical payload outlives bulk when the queue overflows") |
| T29 | Forged or equivocating broadcast author (S/T) | A8 | Fixed-length descriptor committing to each layer's hash, signed by a delegated publishing key that chains to the root key; an expired certificate still validates the posts of its own period; a fork is reportable as a <600 B fork report carrying both conflicting descriptors | **implemented** | `packages/broadcast/` — 303 tests green in the 2026-07-29 gate (`docs/PROJECT_STATE_2026-07-29.md`) |
| T30 | Fabric picks a lane that silently swallows payloads (D) | A1 | The fabric reports what it actually did — live send, queued for later — and never reports success on a caller's behalf; a lane that lies cannot be detected at this layer and that is stated rather than papered over | **implemented, with the limit stated** | `packages/connection_orchestrator/test/chaos_fabric_test.dart` ("a lane that lies about carrying is survivable end to end"); 12 fixed chaos seeds + a frozen-digest reproducibility gate in the same file |

### 8.5 New residual risks

- R6. **Indistinguishability is unmeasured, so it is not claimed.** v3 has
  no metric, no gate, and no number for how distinguishable its traffic is.
  Until one exists, any statement that this product's traffic is hard to
  classify is unsupported and must not be made (T27).
- R7. **The relay authenticates no peer.** Confidentiality does not depend
  on it — media is DTLS-SRTP end to end — but availability and cost do
  (T25), and the session id carries the whole access decision (T26).
- R8. **The low-rate codec is a last resort, not a privacy feature.** The
  project's own documents state that speaker identity does not survive at
  that rate; that is a consequence of the rate, not a protection anyone
  should rely on. The 31.8 bps figure is labelled "measured on a recording,
  not on a live call" everywhere it appears, and stays labelled that way.
- R9. **Battery, data, and real capacity are unmeasured** (device-blocked).
  No claim is made about any of them.

### 8.6 v3 open blockers (dated)

- Indistinguishability metric and CI gate (T27, R6): open 2026-07-31.
  Depends on a leak-metric implementation; tracked as B-1.
- Size/timing shaping for the long-poll lane (T27): open 2026-07-31.
  Cheap partial remedy (randomised 15–25 s hold) is not implemented.
- Relay peer authentication (T25, T26, R7): open 2026-07-31.
- Two-device call with deliberate disconnection, TURN fallback proof,
  budget alert: blocked 2026-07-16 — no cloud account. Unchanged from
  section 6.
- `micro_datagram_lane.dart:32` padding overflow when `mtuBlockSize > 224`
  (found by the 2026-07-27 framing audit, `docs/AUDIT_PLAN_media_transport_framing.md`
  §1): open. It is a memory-safety defect on a padding path, so it belongs
  here and not only in the audit plan.
