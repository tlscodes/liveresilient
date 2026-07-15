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
class PinnedManifestKey {
  final String keyId;
  final Uint8List publicKey;

  /// Revoked keys stay in the list (so `keyId` lookups stay unambiguous)
  /// but never verify.
  final bool revoked;

  PinnedManifestKey({
    required this.keyId,
    required List<int> publicKey,
    this.revoked = false,
  }) : publicKey = Uint8List.fromList(publicKey) {
    if (keyId.isEmpty) {
      throw const FormatException('Pinned key requires a keyId.');
    }
    if (this.publicKey.length != 32) {
      throw FormatException(
        'Ed25519 public keys are 32 bytes, got ${this.publicKey.length}.',
      );
    }
  }
}

enum ManifestRejection {
  malformed,
  unknownSigningKey,
  revokedSigningKey,
  badSignature,
  expired,
  notYetValid,
  rollback,
}

sealed class ManifestVerification {
  const ManifestVerification();
}

class ManifestAccepted extends ManifestVerification {
  final EndpointManifest manifest;
  const ManifestAccepted(this.manifest);
}

class ManifestRejected extends ManifestVerification {
  final ManifestRejection reason;

  /// Diagnostic message safe for logs (never includes key material).
  final String detail;

  const ManifestRejected(this.reason, this.detail);
}

/// The signed document as fetched: manifest JSON plus detached signature.
class SignedManifestDocument {
  final Map<String, Object?> manifestJson;
  final Uint8List signature;

  SignedManifestDocument({
    required this.manifestJson,
    required List<int> signature,
  }) : signature = Uint8List.fromList(signature);

  /// Parses the transport format:
  /// `{"manifest": {...}, "signature": "<base64>"}`.
  factory SignedManifestDocument.fromBytes(List<int> bytes) {
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
    final List<int> signatureBytes;
    try {
      signatureBytes = base64Decode(signature);
    } on FormatException {
      throw const FormatException('Signature is not valid base64.');
    }
    return SignedManifestDocument(
      manifestJson: manifest,
      signature: signatureBytes,
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
  Future<ManifestVerification> verify(
    SignedManifestDocument document, {
    required int lastAcceptedRevision,
    DateTime? now,
  }) async {
    final effectiveNow = (now ?? clock.now()).toUtc();

    final EndpointManifest manifest;
    try {
      manifest = EndpointManifest.fromJson(document.manifestJson);
    } on FormatException catch (e) {
      return ManifestRejected(ManifestRejection.malformed, e.message);
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

    if (document.signature.length != 64) {
      return const ManifestRejected(
        ManifestRejection.badSignature,
        'Ed25519 signatures are 64 bytes.',
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
}
