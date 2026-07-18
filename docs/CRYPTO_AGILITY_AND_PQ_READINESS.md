# Crypto-agility and post-quantum readiness

Status: design proposal, 2026-07-18. Not implemented. Written because one part
of it gets **permanently more expensive with every day the current format ships**.

## The honest framing of "quantum"

The defensible engineering meaning of quantum-readiness in this stack is narrow
and concrete: Ed25519 — which this repo uses for both device identity
(`packages/security`) and signed configuration (`packages/signed_config`) — rests
on the discrete-log problem, which Shor's algorithm solves on a sufficiently
large quantum computer. No such machine is known to exist today, and predicting
when one will is not engineering. So this document does **not** claim urgency
about the cryptography itself.

It claims urgency about something else entirely, which does not depend on any
prediction about quantum computers:

> A signed format with no algorithm identifier can never be migrated safely,
> whatever the reason for migrating turns out to be.

That is true if the driver is a quantum computer, a break in a primitive, a
compliance mandate, or simply a better algorithm. The cost of fixing it is a
few bytes today and a flag day after deployment.

## The concrete defect

`SignedManifestDocument` (packages/signed_config/lib/src/manifest_verifier.dart)
defines the wire envelope as:

```json
{ "manifest": { ... }, "signature": "<base64>" }
```

There is no field naming the signature algorithm, and the verifier enforces
Ed25519 structurally:

```dart
if (document.signature.length != 64) {
  // 'Ed25519 signatures are 64 bytes.'
}
```

The envelope therefore cannot *express* any other algorithm. Consider what a
migration would require once clients are in the field:

- Every deployed client verifies Ed25519 and only Ed25519.
- The manifest is the **bootstrap** — it is how a client learns where to
  connect. A client that cannot verify the manifest cannot reach anything,
  including any mechanism you might otherwise use to update it.
- So the signer cannot switch algorithms until every client has updated, and a
  client that fails to update is permanently stranded.

That is a flag day on the one artifact that has no fallback channel. Not
impossible, but the kind of migration that gets postponed for years.

## Fix now (cheap, small, no new cryptography)

Add the algorithm field **before wide deployment**, while old clients that
would need to tolerate it are few or nonexistent:

```json
{ "manifest": { ... }, "alg": "ed25519", "signature": "<base64>" }
```

Rules:

1. `alg` absent is accepted and means `"ed25519"` — existing signed documents
   stay valid, so this ships without breaking anything.
2. The verifier dispatches on `alg` to a registered `Ed25519Verifier`-shaped
   implementation, and the 64-byte check moves **inside** the Ed25519 branch
   where it belongs — it is an Ed25519 fact, not a manifest fact.
3. An unknown `alg` fails as an explicit, distinguishable
   `unsupportedAlgorithm` result, never as a generic parse error. A client must
   be able to report "I am too old to verify this" as something other than
   "this manifest is corrupt", because those call for opposite recoveries.

The cost is roughly: one optional field, one enum, a dispatch map, and tests.
No new primitive, no dependency, no protocol negotiation. It buys the ability
to change algorithms later without a flag day — which is the whole point.

The same reasoning applies to `PinnedManifestKey`: a pinned key should carry
which algorithm it is *for*, so a client can hold keys of mixed types during
any future transition.

## Later (only when there is a reason, and a verified standard reference)

With the field in place, a hybrid signature becomes an incremental change
rather than a migration:

- Sign with **both** Ed25519 and a lattice-based scheme; accept the document
  only if both verify. Hybrid keeps the classical guarantee intact, so a
  weakness in the newer scheme cannot make security *worse* than today — the
  standard argument for hybrid deployment during a transition.
- `alg` becomes e.g. `"ed25519+mldsa44"`, and old clients that only understand
  `"ed25519"` fail with a clear unsupported-algorithm signal instead of a
  mysterious verification failure.
- Manifest size grows substantially (lattice signatures are kilobytes, not 64
  bytes). `signed_config` already enforces a fetch size cap — that cap must be
  re-derived from measurements, not guessed, before any such change.

**Verification duty before implementing any of this:** the exact scheme names,
parameter sets, and their standard document numbers must be read from the
primary source (NIST / IETF) at implementation time and cited in code. This
document deliberately does not assert an RFC number from memory — an earlier
draft of the surrounding discussion cited a number that could not be verified,
and a wrong identifier baked into a signed format is precisely the kind of
error this whole document exists to prevent.

## What this is not

This does not propose replacing DTLS-SRTP, which is negotiated by the WebRTC
implementation and is not this repo's to change. It does not propose new
cryptography written in-house — `packages/security` correctly delegates every
primitive to an audited library, and that must not change. And it is not a
claim that current cryptography is broken.

It is one small format change, made while it is still nearly free.

## Priority

Below the deployment-bound gates in the audit (real two-device call, TURN
deployment, mobile platform integration). Those prove the product works at all;
this one only becomes irreversible with deployment — which is exactly why it
should land *before* the stack ships widely, not after.
