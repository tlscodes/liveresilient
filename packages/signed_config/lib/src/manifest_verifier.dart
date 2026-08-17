/// Manifest signature verification.
///
/// The configuration service signs the canonical bytes of each
/// [EndpointManifest] with an Ed25519 key held offline/in an HSM. The app
/// ships with the corresponding public keys pinned in the build (multiple
/// keys allow rotation). A manifest is accepted only when:
///
/// 1. its `signingKeyId` matches a pinned, non-revoked key;
/// 2. the Ed25519 signature over [EndpointManifest.canonicalBytes] verifies;
/// 3. the manifest is inside its validity window;
/// 4. its revision is not lower than the last accepted revision
///    (rollback protection — enforced here and again by the cache).
///
/// Cryptography is delegated to [Ed25519Verifier], an adapter the app
/// implements with an audited library (e.g. `package:cryptography`'s
/// Ed25519). This package deliberately contains no hand-rolled crypto.
///
/// Designed from the v2 blueprint role (no v1 equivalent; replaces the
/// unauthenticated v1 provisioning flow).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';

import 'endpoint_manifest.dart';

/// Signature algorithms the manifest envelope can name.
///
/// The wire field is `"alg"` in the signed document; a document without the
/// field means [ed25519] (the format's original and only algorithm), so every
/// previously signed document stays valid. The point of carrying the name
/// explicitly is migration: the manifest is the bootstrap artifact — a client
/// that cannot verify it cannot reach anything, including an update channel —
/// so any future algorithm change must be expressible in the format *before*
/// it is needed, and an unknown algorithm must be distinguishable from a
/// corrupt document (they call for opposite recoveries: "update the app"
/// vs "distrust the origin").
enum ManifestSignatureAlgorithm {
  /// Ed25519 (64-byte signatures, 32-byte public keys).
  ed25519('ed25519', signatureLength: 64, publicKeyLength: 32);

  const ManifestSignatureAlgorithm(
    this.wireName, {
    required this.signatureLength,
    required this.publicKeyLength,
  });

  /// The exact string carried in the document's `"alg"` field.
  final String wireName;

  /// Structural length of a well-formed signature, in bytes.
  final int signatureLength;

  /// Structural length of a well-formed public key, in bytes.
  final int publicKeyLength;

  /// Maps a wire name to an algorithm, or null when this build does not
  /// support it (which the verifier reports as
  /// [ManifestRejection.unsupportedAlgorithm], never as corruption).
  static ManifestSignatureAlgorithm? tryParse(String wireName) {
    for (final algorithm in values) {
      if (algorithm.wireName == wireName) return algorithm;
    }
    return null;
  }
}

/// Adapter over an audited Ed25519 implementation.
abstract interface class Ed25519Verifier {
  /// Returns true when [signature] is a valid Ed25519 signature by
  /// [publicKey] over [message].
  Future<bool> verify({
    required Uint8List message,
    required Uint8List signature,
    required Uint8List publicKey,
  });
}

/// A public key pinned into the app build.
final class PinnedManifestKey {
  final String keyId;
  final Uint8List publicKey;

  /// The algorithm this key verifies. Carried per key so a build can pin
  /// keys of mixed algorithms during a future transition; a document is
  /// only verified by a key whose algorithm matches its own.
  final ManifestSignatureAlgorithm algorithm;

  /// Revoked keys stay in the list (so `keyId` lookups stay unambiguous)
  /// but never verify.
  final bool revoked;

  PinnedManifestKey({
    required this.keyId,
    required List<int> publicKey,
    this.algorithm = ManifestSignatureAlgorithm.ed25519,
    this.revoked = false,
  }) : publicKey = Uint8List.fromList(publicKey) {
    if (keyId.isEmpty) {
      throw const FormatException('Pinned key requires a keyId.');
    }
    if (this.publicKey.length != algorithm.publicKeyLength) {
      throw FormatException(
        '${algorithm.wireName} public keys are '
        '${algorithm.publicKeyLength} bytes, got ${this.publicKey.length}.',
      );
    }
  }
}

enum ManifestRejection {
  malformed,
  unknownSigningKey,
  revokedSigningKey,

  /// The document names a signature algorithm this build cannot verify, or
  /// names one that does not match the pinned key's algorithm. Deliberately
  /// distinct from [malformed]: an unsupported algorithm usually means "this
  /// client is too old", which calls for an update prompt — not for treating
  /// the origin as corrupt or hostile.
  unsupportedAlgorithm,

  /// The signature bytes are not even the right length for the document's
  /// algorithm — a structural defect, distinct from [badSignature] which
  /// means a correctly-shaped signature that failed cryptographic
  /// verification.
  malformedSignature,
  badSignature,
  expired,
  notYetValid,
  rollback,
}

sealed class ManifestVerification {
  const ManifestVerification();
}

final class ManifestAccepted extends ManifestVerification {
  final EndpointManifest manifest;
  const ManifestAccepted(this.manifest);
}

final class ManifestRejected extends ManifestVerification {
  final ManifestRejection reason;

  /// Diagnostic message safe for logs (never includes key material).
  final String detail;

  const ManifestRejected(this.reason, this.detail);
}

/// The two rejection reasons a wrong device clock can manufacture on an
/// otherwise authentic document.
///
/// A clock set behind real time makes a genuine document look
/// [notYetValid]; a clock set ahead makes it look [expired]. No clock
/// setting can manufacture a bad signature, an unknown or revoked key, an
/// unsupported algorithm, a malformed document, or a rollback — so those
/// reasons are never eligible for the lenient re-check, and this enum
/// deliberately cannot name them. Widening it would turn a wrong-clock
/// workaround into an authentication hole.
enum ManifestTimeFault {
  /// The document's validity window had ended at the evaluated instant.
  expired,

  /// The evaluated instant was before the document's `issuedAt`.
  notYetValid,
}

/// Outcome of [ManifestVerifier.verifyLenient].
///
/// Sealed with three named states so every caller must branch: a stale
/// acceptance can never be mistaken for a strict one, and no outcome is
/// inferred from a null or a sentinel.
sealed class LenientManifestVerification {
  const LenientManifestVerification();
}

/// The document passed the strict [ManifestVerifier.verify] unchanged; no
/// relaxation was involved.
final class LenientAccepted extends LenientManifestVerification {
  /// The verified manifest, valid at the evaluated instant.
  final EndpointManifest manifest;

  const LenientAccepted(this.manifest);
}

/// The document is authentic — signature, key, algorithm and rollback all
/// pass — but its validity window fails at the evaluated instant for a
/// reason a wrong clock can manufacture ([fault]).
///
/// This type states a fact; it grants no serving rights. The caller owns
/// the policy for what a stale acceptance is good for (the manifest cache,
/// for example, bounds it with its last-known-good grace). What the
/// re-check cannot detect is WHICH party is wrong — the device clock or
/// the document — which is exactly why it never upgrades the result to a
/// plain acceptance.
final class LenientAcceptedStale extends LenientManifestVerification {
  /// The manifest, re-verified as of its own `issuedAt`.
  final EndpointManifest manifest;

  /// Which time fact the strict check failed on.
  final ManifestTimeFault fault;

  const LenientAcceptedStale(this.manifest, this.fault);
}

/// The document failed for a reason the lenient re-check refuses to
/// relax: any authenticity failure, a malformed document, or a rollback.
///
/// [reason] is never [ManifestRejection.expired] or
/// [ManifestRejection.notYetValid]: at its own `issuedAt` a well-formed
/// document is always inside its window (`expiresAt > issuedAt` is
/// enforced at parse), so a time-faulted document either comes back
/// [LenientAcceptedStale] or fails the relaxed pass on a non-time reason
/// reported here.
final class LenientRejected extends LenientManifestVerification {
  /// The rejection reason the relaxation refused to override.
  final ManifestRejection reason;

  /// Diagnostic message safe for logs (never includes key material).
  final String detail;

  const LenientRejected(this.reason, this.detail);
}

/// The signed document as fetched: manifest JSON plus detached signature.
class SignedManifestDocument {
  /// Longest `"alg"` value accepted structurally. Real algorithm names are
  /// short; anything past this is malformed input, not a future algorithm.
  static const int maxAlgorithmLabelLength = 64;

  /// Upper bound on a signed document, enforced before any parsing.
  ///
  /// The entry-count limits in `endpoint_manifest.dart` bound how many
  /// entries a manifest may carry, not how many bytes: a single entry can
  /// hold a multi-megabyte string and impose the same memory pressure. The
  /// network fetcher and the out-of-band importer each carry their own cap,
  /// but the persisted-document load path had none — a document already on
  /// disk was decoded uncapped. Capping here, at the one parse entry point
  /// all three paths funnel through, is what makes the bound true of every
  /// path rather than of the two that happened to remember.
  ///
  /// Matches the fetcher's `maxBodyBytes` default so a document that was
  /// accepted from the network cannot be rejected when it is read back.
  static const int maxSignedDocumentBytes = 256 * 1024;

  final Map<String, Object?> manifestJson;
  final Uint8List signature;

  /// The document's `"alg"` value, verbatim. Absent on the wire means
  /// `'ed25519'` (the format's original algorithm), so pre-existing signed
  /// documents parse identically. Kept as the raw string — not eagerly
  /// resolved to [ManifestSignatureAlgorithm] — because an algorithm this build
  /// does not know is a *verification* outcome
  /// ([ManifestRejection.unsupportedAlgorithm]), not a parse failure.
  final String algorithmLabel;

  SignedManifestDocument({
    required this.manifestJson,
    required List<int> signature,
    this.algorithmLabel = 'ed25519',
  }) : signature = Uint8List.fromList(signature) {
    if (algorithmLabel.isEmpty ||
        algorithmLabel.length > maxAlgorithmLabelLength) {
      throw FormatException(
        'Algorithm label must be 1-$maxAlgorithmLabelLength characters.',
      );
    }
  }

  /// Parses the transport format:
  /// `{"manifest": {...}, "alg": "<name>", "signature": "<base64>"}`
  /// where `"alg"` is optional and defaults to `"ed25519"`.
  factory SignedManifestDocument.fromBytes(List<int> bytes) {
    // Byte cap first, before decode and before parse: the order of
    // operations the plan requires is cap -> verify -> deep parse.
    if (bytes.length > maxSignedDocumentBytes) {
      throw FormatException(
        'Signed manifest is limited to $maxSignedDocumentBytes bytes, '
        'got ${bytes.length}.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Exception catch (e) {
      throw FormatException('Signed manifest is not valid JSON: $e');
    }
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Signed manifest root must be an object.');
    }
    final manifest = decoded['manifest'];
    final signature = decoded['signature'];
    if (manifest is! Map<String, Object?> || signature is! String) {
      throw const FormatException(
        'Signed manifest requires "manifest" object and "signature" string.',
      );
    }
    final alg = decoded['alg'];
    if (alg is! String?) {
      throw const FormatException(
        'Signed manifest "alg", when present, must be a string.',
      );
    }
    final List<int> signatureBytes;
    try {
      signatureBytes = base64Decode(signature);
    } on FormatException {
      throw const FormatException('Signature is not valid base64.');
    }
    return SignedManifestDocument(
      manifestJson: manifest,
      signature: signatureBytes,
      algorithmLabel: alg ?? 'ed25519',
    );
  }
}

class ManifestVerifier {
  final Map<String, PinnedManifestKey> _keysById;
  final Ed25519Verifier _crypto;

  ManifestVerifier({
    required List<PinnedManifestKey> pinnedKeys,
    required Ed25519Verifier crypto,
  }) : _crypto = crypto,
       _keysById = {for (final k in pinnedKeys) k.keyId: k} {
    if (pinnedKeys.isEmpty) {
      throw ArgumentError('At least one pinned key is required.');
    }
    if (_keysById.length != pinnedKeys.length) {
      throw ArgumentError('Pinned key ids must be unique.');
    }
  }

  /// Verifies a fetched document.
  ///
  /// [now] is injectable for tests. [lastAcceptedRevision] enables rollback
  /// protection; pass the value from the manifest cache (0 when none).
  ///
  /// [persistedTimeFloorUtc] is the monotonic time floor persisted beside
  /// the accepted revision: the latest issuedAt of any document ever
  /// accepted on this device, in UTC. The validity window is evaluated at
  /// the LATER of the device clock and the floor, so a device clock lagging
  /// behind an authentic newer document's issuedAt no longer rejects it as
  /// not-yet-valid. The floor is advisory about the past only — it can only
  /// move the effective instant forward, so it never makes a document
  /// appear valid before its issuedAt was genuinely reached and never
  /// extends one past its expiresAt. Null means no floor has been recorded
  /// (fresh install) and preserves prior behaviour exactly.
  Future<ManifestVerification> verify(
    SignedManifestDocument document, {
    required int lastAcceptedRevision,
    DateTime? now,
    DateTime? persistedTimeFloorUtc,
  }) async {
    final floor = persistedTimeFloorUtc;
    if (floor != null && !floor.isUtc) {
      throw ArgumentError.value(
        floor,
        'persistedTimeFloorUtc',
        'The persisted time floor must be UTC.',
      );
    }
    final deviceNowUtc = (now ?? clock.now()).toUtc();
    final effectiveNow = (floor != null && floor.isAfter(deviceNowUtc))
        ? floor
        : deviceNowUtc;

    final EndpointManifest manifest;
    try {
      manifest = EndpointManifest.fromJson(document.manifestJson);
    } on FormatException catch (e) {
      return ManifestRejected(ManifestRejection.malformed, e.message);
    }

    final algorithm = ManifestSignatureAlgorithm.tryParse(
      document.algorithmLabel,
    );
    if (algorithm == null) {
      return ManifestRejected(
        ManifestRejection.unsupportedAlgorithm,
        'This build cannot verify "${document.algorithmLabel}" signatures; '
        'an update may be required.',
      );
    }

    final key = _keysById[manifest.signingKeyId];
    if (key == null) {
      return ManifestRejected(
        ManifestRejection.unknownSigningKey,
        'No pinned key with id ${manifest.signingKeyId}.',
      );
    }
    if (key.revoked) {
      return ManifestRejected(
        ManifestRejection.revokedSigningKey,
        'Key ${manifest.signingKeyId} has been revoked.',
      );
    }
    if (key.algorithm != algorithm) {
      return ManifestRejected(
        ManifestRejection.unsupportedAlgorithm,
        'Key ${manifest.signingKeyId} is pinned for '
        '${key.algorithm.wireName}, but the document is signed with '
        '${algorithm.wireName}.',
      );
    }

    if (document.signature.length != algorithm.signatureLength) {
      return ManifestRejected(
        ManifestRejection.malformedSignature,
        '${algorithm.wireName} signatures are '
        '${algorithm.signatureLength} bytes.',
      );
    }

    final valid = await _crypto.verify(
      message: Uint8List.fromList(manifest.canonicalBytes()),
      signature: document.signature,
      publicKey: key.publicKey,
    );
    if (!valid) {
      return const ManifestRejected(
        ManifestRejection.badSignature,
        'Signature verification failed.',
      );
    }

    // Time-window checks run only after the signature is proven, so an
    // attacker cannot learn anything from differential timing of rejects.
    if (effectiveNow.isBefore(manifest.issuedAt)) {
      return const ManifestRejected(
        ManifestRejection.notYetValid,
        'Manifest issuedAt is in the future.',
      );
    }
    if (manifest.isExpiredAt(effectiveNow)) {
      return const ManifestRejected(
        ManifestRejection.expired,
        'Manifest validity window has ended.',
      );
    }

    if (manifest.revision < lastAcceptedRevision) {
      return ManifestRejected(
        ManifestRejection.rollback,
        'Revision ${manifest.revision} is older than accepted '
        '$lastAcceptedRevision.',
      );
    }

    return ManifestAccepted(manifest);
  }

  /// Strict [verify], then — only when the sole failure is a time fact a
  /// wrong device clock can manufacture ([ManifestRejection.expired] or
  /// [ManifestRejection.notYetValid]) — a second verification of the same
  /// document as of its own `issuedAt`.
  ///
  /// WHY THIS EXISTS: the manifest cache has two ways to meet a document
  /// whose only defect is its time window — reading one back from storage
  /// and fetching one from the network. This method is the single
  /// relaxation point both paths call, so the two paths cannot drift into
  /// different security policies.
  ///
  /// The relaxed pass changes ONLY the evaluated instant. Signature, key,
  /// algorithm, structure and rollback checks all run again unchanged, so
  /// nothing that fails authenticity can ever come back
  /// [LenientAcceptedStale]. Any rejection reason other than the two time
  /// facts — including reasons added in the future — stays strict by
  /// construction: the relaxation names its two eligible reasons and
  /// treats everything else as final.
  ///
  /// The relaxed pass deliberately drops [persistedTimeFloorUtc]: the
  /// floor (or the clock) is precisely what manufactured the time fault,
  /// and at its own `issuedAt` every well-formed document is inside its
  /// window, so the pass measures authenticity and rollback only. This
  /// does not bypass the floor's guarantees — the strict result, with the
  /// floor applied, is what decides fresh validity; a stale acceptance
  /// only ever reaches the caller as [LenientAcceptedStale], for the
  /// caller's bounded stale-serving policy to judge.
  Future<LenientManifestVerification> verifyLenient(
    SignedManifestDocument document, {
    required int lastAcceptedRevision,
    DateTime? now,
    DateTime? persistedTimeFloorUtc,
  }) async {
    final strict = await verify(
      document,
      lastAcceptedRevision: lastAcceptedRevision,
      now: now,
      persistedTimeFloorUtc: persistedTimeFloorUtc,
    );
    switch (strict) {
      case ManifestAccepted(:final manifest):
        return LenientAccepted(manifest);
      case ManifestRejected(:final reason, :final detail):
        final ManifestTimeFault fault;
        switch (reason) {
          case ManifestRejection.expired:
            fault = ManifestTimeFault.expired;
          case ManifestRejection.notYetValid:
            fault = ManifestTimeFault.notYetValid;
          default:
            // Every non-time reason — present or future — is final. The
            // default keeps unknown future reasons on the safe (strict)
            // side rather than silently relaxing them.
            return LenientRejected(reason, detail);
        }
        // Parse cannot fail here: a time rejection means the strict pass
        // already parsed this exact JSON successfully.
        final issuedAt =
            EndpointManifest.fromJson(document.manifestJson).issuedAt;
        final relaxed = await verify(
          document,
          lastAcceptedRevision: lastAcceptedRevision,
          now: issuedAt,
        );
        return switch (relaxed) {
          ManifestAccepted(:final manifest) =>
            LenientAcceptedStale(manifest, fault),
          ManifestRejected(:final reason, :final detail) =>
            LenientRejected(reason, detail),
        };
    }
  }
}
