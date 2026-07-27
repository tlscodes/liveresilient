/// A short-lived publishing key, delegated by a long-lived root key.
///
/// The root identity key signs nothing but these certificates, and can
/// stay off the publishing device entirely. Posts are signed by the
/// publishing key, so a device compromise is bounded by the
/// certificate's own expiry rather than by anyone noticing and acting.
/// Time does the revoking; that is the point.
library;

import 'dart:typed_data';

import 'broadcast_ids.dart';
import 'broadcast_keys.dart';
import 'wire.dart';

/// Domain separation, so a certificate signature can never be replayed
/// as a signature over anything else this project signs.
final Uint8List _certDomain = Uint8List.fromList(
  'vck/broadcast/publishing-key/v1\n'.codeUnits,
);

/// The only certificate version this build understands.
const int certificateVersion = 1;

/// Encoded certificate length: version, author id, key, two timestamps,
/// signature.
const int certificateBytes = 1 + authorIdBytes + 32 + 5 + 5 + 64;

/// The longest validity window a reader will accept.
///
/// A certificate is the compromise bound, so an unbounded one defeats
/// the mechanism. This ceiling is enforced on the reader side, which
/// means a misconfigured author cannot talk a reader into a longer
/// window than the reader is willing to grant.
const Duration maxCertificateValidity = Duration(days: 31);

/// Why a certificate was refused.
enum CertificateRejection {
  malformed,
  unsupportedVersion,
  authorMismatch,
  invalidWindow,
  windowTooLong,
  notYetValid,
  expired,
  badSignature,
}

/// A verified delegation from a root key to a publishing key.
class PublishingKeyCertificate {
  const PublishingKeyCertificate({
    required this.authorId,
    required this.publishingKey,
    required this.notBefore,
    required this.notAfter,
    required this.encoded,
  });

  /// Truncated identifier of the root key that signed this.
  final Uint8List authorId;

  /// The 32-byte key that may sign posts while this is valid.
  final Uint8List publishingKey;

  final DateTime notBefore;
  final DateTime notAfter;

  /// The exact bytes this was parsed from, or produced as.
  final Uint8List encoded;

  /// Whether [at] falls inside the validity window, inclusive.
  bool isValidAt(DateTime at) =>
      !at.isBefore(notBefore) && !at.isAfter(notAfter);

  /// Sign a new certificate with the root key held by [rootSigner].
  static Future<PublishingKeyCertificate> issue({
    required BroadcastSigner rootSigner,
    required Uint8List publishingKey,
    required DateTime notBefore,
    required DateTime notAfter,
  }) async {
    if (publishingKey.length != 32) {
      throw ArgumentError.value(
        publishingKey.length,
        'publishingKey.length',
        'an Ed25519 public key is 32 bytes',
      );
    }
    if (!notAfter.isAfter(notBefore)) {
      throw ArgumentError.value(
        notAfter,
        'notAfter',
        'must be strictly after notBefore',
      );
    }
    final authorId = authorIdFor(rootSigner.publicKey);
    final body = _body(
      authorId: authorId,
      publishingKey: publishingKey,
      notBefore: notBefore,
      notAfter: notAfter,
    );
    final signature = await rootSigner.sign(_signingInput(body));
    final out = WireWriter()
      ..bytes(body)
      ..bytes(signature);
    return PublishingKeyCertificate(
      authorId: authorId,
      publishingKey: publishingKey,
      notBefore: notBefore,
      notAfter: notAfter,
      encoded: out.take(),
    );
  }

  /// Parse and fully verify [encoded] against [rootPublicKey] at [now].
  ///
  /// Returns null and reports through [onReject] rather than throwing:
  /// the input is untrusted by definition, so refusal is an expected
  /// outcome, not an exceptional one.
  static Future<PublishingKeyCertificate?> verify({
    required Uint8List encoded,
    required Uint8List rootPublicKey,
    required BroadcastVerifier verifier,
    required DateTime now,
    Duration maxValidity = maxCertificateValidity,
    void Function(CertificateRejection reason)? onReject,
  }) async {
    void reject(CertificateRejection reason) => onReject?.call(reason);

    if (encoded.length != certificateBytes) {
      reject(CertificateRejection.malformed);
      return null;
    }
    final reader = WireReader(encoded);
    final int version;
    final Uint8List authorId;
    final Uint8List publishingKey;
    final int notBeforeSeconds;
    final int notAfterSeconds;
    final Uint8List signature;
    try {
      version = reader.u8();
      authorId = reader.bytes(authorIdBytes);
      publishingKey = reader.bytes(32);
      notBeforeSeconds = reader.u40();
      notAfterSeconds = reader.u40();
      signature = reader.bytes(64);
    } on FormatException {
      reject(CertificateRejection.malformed);
      return null;
    }

    if (version != certificateVersion) {
      reject(CertificateRejection.unsupportedVersion);
      return null;
    }
    if (rootPublicKey.length != 32 ||
        !bytesEqual(authorId, authorIdFor(rootPublicKey))) {
      reject(CertificateRejection.authorMismatch);
      return null;
    }

    final notBefore = _fromSeconds(notBeforeSeconds);
    final notAfter = _fromSeconds(notAfterSeconds);
    if (!notAfter.isAfter(notBefore)) {
      reject(CertificateRejection.invalidWindow);
      return null;
    }
    if (notAfter.difference(notBefore) > maxValidity) {
      reject(CertificateRejection.windowTooLong);
      return null;
    }
    if (now.isBefore(notBefore)) {
      reject(CertificateRejection.notYetValid);
      return null;
    }
    if (now.isAfter(notAfter)) {
      reject(CertificateRejection.expired);
      return null;
    }

    final body = Uint8List.sublistView(encoded, 0, certificateBytes - 64);
    final ok = await verifier.verify(
      message: _signingInput(Uint8List.fromList(body)),
      signature: signature,
      publicKey: rootPublicKey,
    );
    if (!ok) {
      reject(CertificateRejection.badSignature);
      return null;
    }

    return PublishingKeyCertificate(
      authorId: authorId,
      publishingKey: publishingKey,
      notBefore: notBefore,
      notAfter: notAfter,
      encoded: Uint8List.fromList(encoded),
    );
  }

  /// Peek at the declared `notBefore` without verifying anything.
  ///
  /// Used only to choose the instant at which [verify] should run its
  /// window check, so that adopting a certificate can test the signature
  /// while deliberately not testing liveness. The value is attacker-
  /// controlled and must never be treated as a fact: the real window
  /// comes back from [verify].
  static DateTime? parseWindowStart(Uint8List encoded) {
    if (encoded.length != certificateBytes) return null;
    final reader = WireReader(encoded);
    try {
      if (reader.u8() != certificateVersion) return null;
      reader.bytes(authorIdBytes);
      reader.bytes(32);
      return _fromSeconds(reader.u40());
    } on FormatException {
      return null;
    }
  }

  static Uint8List _body({
    required Uint8List authorId,
    required Uint8List publishingKey,
    required DateTime notBefore,
    required DateTime notAfter,
  }) {
    final out = WireWriter()
      ..u8(certificateVersion)
      ..bytes(authorId)
      ..bytes(publishingKey)
      ..u40(_toSeconds(notBefore))
      ..u40(_toSeconds(notAfter));
    return out.take();
  }

  static Uint8List _signingInput(Uint8List body) {
    final out = WireWriter()
      ..bytes(_certDomain)
      ..bytes(body);
    return out.take();
  }
}

int _toSeconds(DateTime at) {
  final seconds = at.toUtc().millisecondsSinceEpoch ~/ 1000;
  if (seconds < 0 || seconds > 0xFFFFFFFFFF) {
    throw ArgumentError.value(at, 'at', 'not representable in five bytes');
  }
  return seconds;
}

DateTime _fromSeconds(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
