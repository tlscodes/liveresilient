# Data Flow — VoiceCallKit (v2 boundaries; v3 delta lives in the threat model)

Companion to `security/THREAT_MODEL.md`. That document now covers v3 (its
§8 adds TB6-TB8 for the relay, the mesh/carrier lanes, and the broadcast
chain); this file still diagrams the v2 boundaries TB1-TB5 only, and says so
rather than implying it is complete. Contradiction 7, noted 2026-07-31: the
2026-07-27 architecture review said no threat model existed — the file
existed but was v2-only, which is now fixed at the source.

(trust boundaries TB1-TB5 there map
directly to the boundary markers below). This document shows *where data
goes and where it is protected*, not the threats — see the threat model
for the STRIDE analysis and per-item evidence.

Status as reviewed 2026-07-16 on `phase-4/security-identity`: the diagram
shows the designed v2 architecture; nodes not yet built are marked
**(not yet built)** or **(blocked, dated)** inline so this stays a design
document, not a claim that every box is running code today.

## 1. Overview diagram

```mermaid
flowchart LR
    subgraph DeviceA["Device A"]
        AppA["App (call_core, media_webrtc)"]
        IdA["Identity key (Ed25519)<br/>security/crypto_identity_engine.dart"]
        KeyStoreA["KeyMaterialStore<br/>(dev: in-memory/file)<br/>(prod: Keystore/Keychain - blocked, dated 2026-07-15)"]
    end

    subgraph DeviceB["Device B"]
        AppB["App (call_core, media_webrtc)"]
        IdB["Identity key (Ed25519)"]
        KeyStoreB["KeyMaterialStore"]
    end

    subgraph Nearby["Local peer link (device_link) - consent-gated"]
        LocalLink["Authenticated envelope<br/>(Ed25519 sign/verify, nonce+staleness)"]
    end

    Signaling["Signaling relay (WSS)<br/>server/signaling_server"]
    TURN["TURN/STUN relay<br/>infra/turn (coturn)"]
    ConfigSigner["Offline manifest signer<br/>(air-gapped)<br/>signed_config/bin/sign_manifest.dart"]
    ConfigHost["Config-serving host<br/>(HTTPS) - NOT YET BUILT<br/>no server/config_service exists"]

    AppA -- "TB1: WSS, envelope<br/>(key id, call id, seq only)" --> Signaling
    Signaling -- "TB1: WSS" --> AppB

    AppA -- "TB3: ICE/STUN/TURN<br/>media is DTLS-SRTP end to end" --> TURN
    TURN -- "TB3" --> AppB

    AppA -. "TB4: consent-gated,<br/>off by default" .-> LocalLink
    LocalLink -. "TB4" .-> AppB

    ConfigSigner -- "signs manifest<br/>(Ed25519, pinned key set)" --> ConfigHost
    ConfigHost -- "TB2: HTTPS + signature<br/>(config host NOT YET BUILT -<br/>verifier side is implemented<br/>and tested against fakes)" --> AppA
    ConfigHost -- "TB2" --> AppB

    IdA --- KeyStoreA
    IdB --- KeyStoreB
    AppA --- IdA
    AppB --- IdB

    classDef notbuilt fill:#00000000,stroke:#999,stroke-dasharray: 5 5,color:#999;
    class ConfigHost notbuilt;
```

## 2. Manifest fetch path (detail)

```mermaid
sequenceDiagram
    participant Op as Operator (offline, air-gapped)
    participant Signer as sign_manifest.dart CLI
    participant Host as Config-serving host (HTTPS) - not yet built
    participant App as Device app
    participant Verifier as ManifestVerifier + CryptographyEd25519Verifier

    Op->>Signer: manifest.json + private key (offline)
    Signer->>Signer: canonicalize + Ed25519 sign
    Signer-->>Host: signed manifest (manual/ops publish step)
    App->>Host: GET manifest (HTTPS)
    Host-->>App: {manifest, signature}
    App->>Verifier: verify(manifest, signature, pinnedKeys)
    Verifier->>Verifier: check signature, expiry, notYetValid,<br/>revokedKeyIds, monotonic revision
    Verifier-->>App: ManifestAccepted | ManifestRejected(reason)
    Note over Verifier: Real-crypto path (CryptographyEd25519Verifier)<br/>is green: 10/10 in crypto_ed25519_verifier_test.dart,<br/>confirmed by key_rotation_test.dart (8/8, real keys).<br/>The 2026-07-16 failures noted here were fixed the same day<br/>- see THREAT_MODEL.md T2.
```

## 3. Trust boundaries and what crosses them

| Boundary | Crosses | Protection | Status |
|---|---|---|---|
| TB1 Device ⇄ signaling service | Envelope: key id, call id, sequence number, message type. No SDP, no media, no address book. | WSS (TLS). App-layer confidentiality of the envelope fields themselves: **not implemented** (see THREAT_MODEL T18) — the signaling server can read these fields today by design (routing metadata), only the TLS channel keeps outside observers out. | Transport: implemented (`server/signaling_server`). App-layer envelope encryption: not yet built. |
| TB2 Device ⇄ config service | Signed manifest (endpoints, regions, min-version, flags). No user identity. | HTTPS transport + Ed25519 signature verification against build-pinned keys; anti-rollback via monotonic revision; last-known-good cache on fetch failure. | Verifier logic: implemented, tested (fakes). Real-crypto backing: landing this wave, 2 tests failing. Live HTTPS host: not yet built. |
| TB3 Device ⇄ TURN/STUN | Relayed SRTP packets (ciphertext only) + short-lived TURN credentials (username/password). | DTLS-SRTP end to end (TURN never sees plaintext media or media keys); credentials are HMAC-based with expiry (`TurnCredentialsIssuer`). | Media crypto: blocked, dated (native WebRTC build, Xcode). Credential minting: implemented, untested (no test file). Credential distribution to a real client per call: not yet built. |
| TB4 Device ⇄ nearby device | Authenticated envelope wrapping session-layer ciphertext; nonce + timestamp. | Off by default; explicit consent; Ed25519 sign/verify; nonce replay cache; staleness window; hop/TTL caps for forwarding. | Protocol logic: implemented, tested (fakes). Real Ed25519 backing (`CryptoEnvelopeSigner`/`Verifier`): implemented, untested, not exported from the package barrel yet. |
| TB5 Device ⇄ push provider | Wake-up signal only (opaque call id, no names/numbers/content). | Fetch-on-wake over TLS; payload minimization by construction. | Not yet built (Phase 8, `docs/EXECUTION_PLAYBOOK.md:133`). |

## 4. Key material locations

| Key material | Current location | Production target |
|---|---|---|
| Device identity private key (Ed25519 seed) | `InMemoryKeyStore` (process lifetime) or `DevFileKeyStore` (plaintext JSON file, dev builds only, never for shipped builds) — `packages/security/lib/src/key_store.dart` | OS Keystore (Android) / Keychain (iOS), hardware-backed where available. **Blocked, dated 2026-07-15**: needs the Flutter app shell to exist before a platform-channel adapter can be written. |
| Manifest signing private key | Operator-held, offline, used only by `packages/signed_config/bin/sign_manifest.dart` in an air-gapped signing step | Same — offline/HSM by design; this does not change with app-shell availability, it's an ops-process control, not a client-code gap. |
| TURN shared secret (`static-auth-secret`) | Configuration value passed to `TurnCredentialsIssuer` (server side only, by contract in the class doc comment) | Must live only on the signaling/TURN-issuing server; the class explicitly documents that shipping it inside a client bundle leaks it to every install. No server-side wiring exists yet to enforce this operationally. |
| Pinned peer identities (TOFU) | In-memory / `SecureKeyValueStore` adapter (interface), exercised in tests via `InMemorySecureKeyValueStore` | Platform secure storage, same blocker as the identity key above. |

## 5. Review cadence

Reviewed alongside `security/THREAT_MODEL.md` at every milestone and
whenever a new component crosses a trust boundary listed above.
