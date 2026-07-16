/// Ed25519 [IdentityKeyEngine] backed by `package:cryptography` (audited,
/// no hand-rolled primitives).
///
/// Private key seeds are addressed by handle through a [KeyMaterialStore]
/// (see `key_store.dart`); this class never exposes private key bytes to
/// its callers, matching the handle-based contract in `identity_store.dart`.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'key_store.dart';
import 'identity_store.dart';

/// Production identity engine: Ed25519 signatures, SHA-256 hashing.
///
/// Key pairs are generated fresh (`Ed25519.newKeyPair()`, which draws from
/// a secure random source) and their extractable seed is persisted via
/// [KeyMaterialStore] so the same handle reloads the same key pair later.
/// A per-handle in-memory cache avoids re-deriving the key pair from its
/// seed on every operation.
class CryptographyIdentityKeyEngine implements IdentityKeyEngine {
  final KeyMaterialStore _keyStore;
  final Ed25519 _algorithm;
  final Sha256 _hashAlgorithm;
  final Map<String, SimpleKeyPair> _cache = <String, SimpleKeyPair>{};

  CryptographyIdentityKeyEngine({required KeyMaterialStore keyStore})
    : _keyStore = keyStore,
      _algorithm = Ed25519(),
      _hashAlgorithm = Sha256();

  @override
  Future<Uint8List> generateKeyPair({required String keyHandle}) async {
    final keyPair = await _algorithm.newKeyPair();
    final seed = await keyPair.extractPrivateKeyBytes();
    await _keyStore.write(keyHandle, Uint8List.fromList(seed));
    _cache[keyHandle] = keyPair;
    final publicKey = await keyPair.extractPublicKey();
    return Uint8List.fromList(publicKey.bytes);
  }

  @override
  Future<Uint8List?> publicKey({required String keyHandle}) async {
    final keyPair = await _loadKeyPair(keyHandle);
    if (keyPair == null) return null;
    final publicKey = await keyPair.extractPublicKey();
    return Uint8List.fromList(publicKey.bytes);
  }

  @override
  Future<Uint8List> sign({
    required String keyHandle,
    required Uint8List message,
  }) async {
    final keyPair = await _loadKeyPair(keyHandle);
    if (keyPair == null) {
      throw StateError(
        'No identity key pair for handle "$keyHandle". '
        'Call generateKeyPair() first (or restore from storage).',
      );
    }
    final signature = await _algorithm.sign(message, keyPair: keyPair);
    return Uint8List.fromList(signature.bytes);
  }

  @override
  Future<bool> verify({
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) async {
    final candidate = Signature(
      signature,
      publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
    );
    try {
      return await _algorithm.verify(message, signature: candidate);
    } on Object {
      // Malformed signature/public-key material (e.g. wrong length after
      // tampering) is a verification failure, not a caller error.
      return false;
    }
  }

  @override
  Future<Uint8List> sha256(Uint8List input) async {
    final hash = await _hashAlgorithm.hash(input);
    return Uint8List.fromList(hash.bytes);
  }

  Future<SimpleKeyPair?> _loadKeyPair(String keyHandle) async {
    final cached = _cache[keyHandle];
    if (cached != null) return cached;

    final seed = await _keyStore.read(keyHandle);
    if (seed == null) return null;

    final keyPair = await _algorithm.newKeyPairFromSeed(seed);
    _cache[keyHandle] = keyPair;
    return keyPair;
  }
}
