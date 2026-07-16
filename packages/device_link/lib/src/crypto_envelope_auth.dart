/// Real Ed25519 adapters for the [EnvelopeSigner] / [EnvelopeVerifier] ports
/// declared in `authenticated_envelope.dart`.
///
/// All cryptographic operations are delegated to the audited
/// `package:cryptography` implementation of Ed25519 — no signature or hash
/// primitives are implemented in this file.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'authenticated_envelope.dart';

/// [EnvelopeSigner] backed by a real Ed25519 key pair.
///
/// Holds the private key material for the local device identity and signs
/// over [AuthenticatedEnvelope.signedBytes] — the only bytes the protocol
/// authenticates.
class CryptoEnvelopeSigner implements EnvelopeSigner {
  @override
  final String keyId;

  final SimpleKeyPair _keyPair;
  static final Ed25519 _algorithm = Ed25519();

  CryptoEnvelopeSigner._(this.keyId, this._keyPair);

  /// Generates a fresh Ed25519 key pair for [keyId].
  static Future<CryptoEnvelopeSigner> generate({required String keyId}) async {
    final keyPair = await _algorithm.newKeyPair();
    return CryptoEnvelopeSigner._(keyId, keyPair);
  }

  /// Wraps an already-generated key pair (e.g. loaded from secure storage).
  static CryptoEnvelopeSigner fromKeyPair({
    required String keyId,
    required SimpleKeyPair keyPair,
  }) => CryptoEnvelopeSigner._(keyId, keyPair);

  /// The public key to register with peers' trusted-key directories.
  Future<SimplePublicKey> extractPublicKey() => _keyPair.extractPublicKey();

  @override
  Future<Uint8List> sign(Uint8List message) async {
    final signature = await _algorithm.sign(message, keyPair: _keyPair);
    return Uint8List.fromList(signature.bytes);
  }
}

/// [EnvelopeVerifier] backed by a real Ed25519 verification and a trusted
/// public-key directory keyed by sender key id.
///
/// Per the [EnvelopeVerifier] contract, an unknown [keyId] or a signature
/// that fails cryptographic verification both resolve to `false` — never a
/// thrown exception.
class CryptoEnvelopeVerifier implements EnvelopeVerifier {
  final Map<String, SimplePublicKey> _trustedKeys;
  static final Ed25519 _algorithm = Ed25519();

  CryptoEnvelopeVerifier([Map<String, SimplePublicKey>? trustedKeys])
    : _trustedKeys = Map<String, SimplePublicKey>.of(trustedKeys ?? const {});

  /// Registers (or replaces) the trusted public key for [keyId].
  void trust(String keyId, SimplePublicKey publicKey) {
    _trustedKeys[keyId] = publicKey;
  }

  /// Removes a previously trusted key (e.g. on device unpairing).
  void revoke(String keyId) {
    _trustedKeys.remove(keyId);
  }

  @override
  Future<bool> verify({
    required String keyId,
    required Uint8List message,
    required Uint8List signature,
  }) async {
    final publicKey = _trustedKeys[keyId];
    if (publicKey == null) return false;
    try {
      return await _algorithm.verify(
        message,
        signature: Signature(signature, publicKey: publicKey),
      );
    } catch (_) {
      // A malformed signature (e.g. wrong byte length) surfaces as a
      // StateError from the underlying library, not a verification
      // failure result; the port contract requires false, never a throw.
      return false;
    }
  }
}
