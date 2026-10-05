/// Ed25519 [IdentityKeyEngine] backed by `package:cryptography` (audited,
/// no hand-rolled primitives).
///
/// Private key seeds are addressed by handle through a [KeyMaterialStore]
/// (see `key_store.dart`); this class never exposes private key bytes to
/// its callers, matching the handle-based contract in `identity_store.dart`.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'identity_key_agreement.dart';
import 'key_store.dart';
import 'identity_store.dart';

/// Production identity engine: Ed25519 signatures, SHA-256 hashing.
///
/// Key pairs are generated fresh (`Ed25519.newKeyPair()`, which draws from
/// a secure random source) and their extractable seed is persisted via
/// [KeyMaterialStore] so the same handle reloads the same key pair later.
/// A per-handle in-memory cache avoids re-deriving the key pair from its
/// seed on every operation.
class CryptographyIdentityKeyEngine
    implements IdentityKeyEngine, IdentityKeyAgreement {
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
    } on ArgumentError {
      // `package:cryptography` validates key/signature byte lengths with
      // its own `ArgumentError` (e.g. `DartEd25519.verify` rejects a
      // public key that isn't 32 bytes) *before* it gets to do any actual
      // verification — that is malformed input material (possibly from
      // tampering), not a caller bug in this class, so it is treated as
      // "verification failed" like any other bad signature.
      return false;
    } on Exception {
      // Any other malformed-input exception the crypto library may throw
      // for the same reason. A real Error (assertion/type/out-of-memory)
      // is a bug and must propagate rather than be swallowed as
      // "verification failed".
      return false;
    }
  }

  @override
  Future<Uint8List> sha256(Uint8List input) async {
    final hash = await _hashAlgorithm.hash(input);
    return Uint8List.fromList(hash.bytes);
  }

  @override
  Future<Uint8List> agree({
    required String keyHandle,
    required Uint8List remoteX25519PublicKey,
  }) async {
    if (remoteX25519PublicKey.length != 32) {
      throw ArgumentError.value(
        remoteX25519PublicKey.length,
        'remoteX25519PublicKey',
        'must be 32 bytes',
      );
    }
    final keyPair = await _loadKeyPair(keyHandle);
    if (keyPair == null) {
      throw StateError('No identity key pair for handle "$keyHandle".');
    }
    // RFC 8032 §5.1.5: the Ed25519 secret scalar is the clamped low half of
    // SHA-512(seed). X25519 clamps the same way, so handing it those 32
    // bytes yields the Montgomery key whose public half is
    // ed25519PublicKeyToX25519(this key's public half).
    final seed = await keyPair.extractPrivateKeyBytes();
    final expanded = await Sha512().hash(seed);
    final x25519 = X25519();
    final montgomery = await x25519.newKeyPairFromSeed(
      expanded.bytes.sublist(0, 32),
    );
    final secret = await x25519.sharedSecretKey(
      keyPair: montgomery,
      remotePublicKey: SimplePublicKey(
        remoteX25519PublicKey,
        type: KeyPairType.x25519,
      ),
    );
    final bytes = Uint8List.fromList(await secret.extractBytes());
    var acc = 0;
    for (final b in bytes) {
      acc |= b;
    }
    if (acc == 0) {
      throw ArgumentError('remoteX25519PublicKey is a low-order point');
    }
    return bytes;
  }

  /// Drops any cached key pair for [keyHandle] so the next operation on
  /// that handle re-derives it from [KeyMaterialStore] (or finds nothing,
  /// if the caller also deleted the underlying seed). Call this after
  /// deleting a handle's seed from the key store — otherwise this engine
  /// instance keeps serving the stale in-memory key pair indefinitely.
  void forget(String keyHandle) {
    _cache.remove(keyHandle);
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
