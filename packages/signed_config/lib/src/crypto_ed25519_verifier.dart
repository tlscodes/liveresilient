/// Real Ed25519 signature verification, backed by `package:cryptography`.
///
/// This is the app's concrete plug-in for [Ed25519Verifier] (see
/// `manifest_verifier.dart`'s doc comment: the verifier package deliberately
/// contains no hand-rolled crypto and delegates to an audited library).
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'manifest_verifier.dart';

/// [Ed25519Verifier] implementation backed by `package:cryptography`'s
/// pure-Dart Ed25519 verifier.
///
/// Stateless and safe to share/reuse across calls; a single instance may be
/// passed to any number of [ManifestVerifier]s.
class CryptographyEd25519Verifier implements Ed25519Verifier {
  final Ed25519 _algorithm;

  /// [algorithm] is injectable for tests that want to observe/replace the
  /// underlying primitive; production code should use the default.
  CryptographyEd25519Verifier({Ed25519? algorithm})
    : _algorithm = algorithm ?? Ed25519();

  @override
  Future<bool> verify({
    required Uint8List message,
    required Uint8List signature,
    required Uint8List publicKey,
  }) async {
    if (publicKey.length != 32) return false;
    if (signature.length != 64) return false;
    try {
      final simplePublicKey = SimplePublicKey(
        publicKey,
        type: KeyPairType.ed25519,
      );
      final sig = Signature(signature, publicKey: simplePublicKey);
      return await _algorithm.verify(message, signature: sig);
    } on Exception {
      // Any malformed-input exception from the crypto library is a failed
      // verification, never a thrown error the caller must catch.
      return false;
    }
  }
}
