/// Signing and verification seams for the broadcast layer.
///
/// The package depends on these interfaces, not on a crypto library, so
/// a host app can route signing to platform key storage where the
/// private key never enters the Dart heap. The bundled implementations
/// are the default for tests and for the reference app.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Produces Ed25519 signatures for one key pair.
abstract interface class BroadcastSigner {
  /// The 32-byte public key matching this signer.
  Uint8List get publicKey;

  /// Sign [message], returning 64 bytes.
  Future<Uint8List> sign(Uint8List message);
}

/// Verifies Ed25519 signatures.
abstract interface class BroadcastVerifier {
  /// Whether [signature] is a valid signature of [message] by
  /// [publicKey]. Returns false rather than throwing on malformed
  /// input — every caller here is handling bytes from an untrusted
  /// source, and an exception would just become a crash on hostile data.
  Future<bool> verify({
    required Uint8List message,
    required Uint8List signature,
    required Uint8List publicKey,
  });
}

/// An in-process signer backed by `package:cryptography`.
///
/// Suitable for the publishing key, which is short-lived by design. A
/// root identity key should prefer a platform-backed signer.
class CryptographyBroadcastSigner implements BroadcastSigner {
  CryptographyBroadcastSigner._(this._keyPair, this.publicKey);

  /// Generate a fresh key pair.
  static Future<CryptographyBroadcastSigner> generate() async {
    final keyPair = await Ed25519().newKeyPair();
    final pub = await keyPair.extractPublicKey();
    return CryptographyBroadcastSigner._(
      keyPair,
      Uint8List.fromList(pub.bytes),
    );
  }

  /// Rebuild a signer from a 32-byte Ed25519 seed.
  static Future<CryptographyBroadcastSigner> fromSeed(Uint8List seed) async {
    if (seed.length != 32) {
      throw ArgumentError.value(
        seed.length,
        'seed.length',
        'an Ed25519 seed is 32 bytes',
      );
    }
    final keyPair = await Ed25519().newKeyPairFromSeed(seed);
    final pub = await keyPair.extractPublicKey();
    return CryptographyBroadcastSigner._(
      keyPair,
      Uint8List.fromList(pub.bytes),
    );
  }

  final SimpleKeyPair _keyPair;

  @override
  final Uint8List publicKey;

  @override
  Future<Uint8List> sign(Uint8List message) async {
    final sig = await Ed25519().sign(message, keyPair: _keyPair);
    return Uint8List.fromList(sig.bytes);
  }
}

/// Verification backed by `package:cryptography`.
class CryptographyBroadcastVerifier implements BroadcastVerifier {
  const CryptographyBroadcastVerifier();

  @override
  Future<bool> verify({
    required Uint8List message,
    required Uint8List signature,
    required Uint8List publicKey,
  }) async {
    // Reject wrong-sized inputs before handing them to the algorithm:
    // the library's own error for these is an exception, and callers
    // here are parsing untrusted bytes.
    if (publicKey.length != 32 || signature.length != 64) return false;
    try {
      return await Ed25519().verify(
        message,
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
        ),
      );
    } on Object {
      return false;
    }
  }
}
