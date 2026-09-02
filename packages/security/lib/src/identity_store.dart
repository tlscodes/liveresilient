/// Device identity store.
///
/// Manages the device's long-term Ed25519 identity key pair and the trust
/// state of remote identities:
/// - key generation and use are delegated to [IdentityKeyEngine], an
///   adapter over an audited cryptography library; private key material
///   never passes through this class (sign-by-handle);
/// - persistence goes through [SecureKeyValueStore], an adapter over
///   platform secure storage (Keychain / Keystore);
/// - remote identities follow trust-on-first-use (TOFU): the first key seen
///   for a peer is pinned; any later change is reported as
///   [RemoteIdentityCheck.changed] so the UI can warn the user in plain
///   language (see key-verification requirements in the blueprint);
/// - session fingerprints are signed with the identity key so users can
///   compare safety numbers / QR codes out of band.
///
/// Designed from the v2 blueprint role (no v1 equivalent).
library;

import 'dart:typed_data';

import 'hex_codec.dart';

/// Handle-based signer over an audited Ed25519 implementation. The engine
/// owns private key material (ideally hardware-backed) and exposes only
/// operations.
abstract interface class IdentityKeyEngine {
  /// Generates a new Ed25519 key pair and returns its public key (32
  /// bytes). The private half stays inside the engine, addressable by
  /// [keyHandle].
  Future<Uint8List> generateKeyPair({required String keyHandle});

  /// Returns the public key for an existing handle, or null when absent.
  Future<Uint8List?> publicKey({required String keyHandle});

  Future<Uint8List> sign({
    required String keyHandle,
    required Uint8List message,
  });

  Future<bool> verify({
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  });

  /// Computes a cryptographic hash (SHA-256) used for fingerprints.
  Future<Uint8List> sha256(Uint8List input);
}

/// Adapter over platform secure storage.
abstract interface class SecureKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Outcome of checking a peer's presented identity key.
enum RemoteIdentityCheck {
  /// First contact: the key was pinned now (TOFU).
  pinnedFirstUse,

  /// Matches the pinned key.
  match,

  /// DIFFERENT from the pinned key — the UI must warn the user before the
  /// session continues.
  changed,
}

class DeviceIdentity {
  /// Public identity key (Ed25519, 32 bytes).
  final Uint8List publicKey;

  /// Human-comparable fingerprint of [publicKey] (uppercase hex of the
  /// SHA-256, grouped in blocks of 4).
  final String fingerprint;

  const DeviceIdentity({required this.publicKey, required this.fingerprint});
}

class IdentityStore {
  static const String _localKeyHandle = 'device-identity-v1';
  static const String _remoteKeyPrefix = 'peer-identity:';

  final IdentityKeyEngine _engine;
  final SecureKeyValueStore _store;

  DeviceIdentity? _cached;

  IdentityStore({
    required IdentityKeyEngine engine,
    required SecureKeyValueStore store,
  }) : _engine = engine,
       _store = store;

  /// Returns the device identity, generating it on first launch.
  Future<DeviceIdentity> localIdentity() async {
    final cached = _cached;
    if (cached != null) return cached;

    var publicKey = await _engine.publicKey(keyHandle: _localKeyHandle);
    publicKey ??= await _engine.generateKeyPair(keyHandle: _localKeyHandle);

    if (publicKey.length != 32) {
      throw StateError(
        'Identity engine returned a ${publicKey.length}-byte public key; '
        'Ed25519 keys are 32 bytes.',
      );
    }

    final identity = DeviceIdentity(
      publicKey: publicKey,
      fingerprint: await _fingerprint(publicKey),
    );
    _cached = identity;
    return identity;
  }

  /// Short key id used in envelopes: the first 16 hex characters of the
  /// fingerprint (collision-resistant enough for routing; full fingerprints
  /// are used for human verification).
  Future<String> localKeyId() async {
    final identity = await localIdentity();
    return identity.fingerprint.replaceAll(' ', '').substring(0, 16);
  }

  /// Signs a session fingerprint (e.g. the DTLS-SRTP certificate digest)
  /// with the identity key, binding the media session to this identity.
  Future<Uint8List> signSessionFingerprint(Uint8List sessionDigest) async {
    await localIdentity(); // Ensures the key exists.
    return _engine.sign(keyHandle: _localKeyHandle, message: sessionDigest);
  }

  /// Verifies a peer's signed session fingerprint against their pinned
  /// identity key.
  Future<bool> verifySessionFingerprint({
    required String peerId,
    required Uint8List sessionDigest,
    required Uint8List signature,
  }) async {
    if (peerId.isEmpty) {
      throw ArgumentError.value(peerId, 'peerId', 'must not be empty');
    }
    final pinnedHex = await _store.read('$_remoteKeyPrefix$peerId');
    if (pinnedHex == null) return false;
    return _engine.verify(
      publicKey: hexDecode(pinnedHex),
      message: sessionDigest,
      signature: signature,
    );
  }

  /// Checks (and on first use pins) the identity key a peer presented.
  Future<RemoteIdentityCheck> checkRemoteIdentity({
    required String peerId,
    required Uint8List presentedPublicKey,
  }) async {
    if (peerId.isEmpty) {
      throw ArgumentError.value(peerId, 'peerId', 'must not be empty');
    }
    if (presentedPublicKey.length != 32) {
      throw ArgumentError.value(
        presentedPublicKey.length,
        'presentedPublicKey.length',
        'Ed25519 public keys are 32 bytes',
      );
    }

    final storageKey = '$_remoteKeyPrefix$peerId';
    final pinnedHex = await _store.read(storageKey);
    final presentedHex = hexEncode(presentedPublicKey);

    if (pinnedHex == null) {
      await _store.write(storageKey, presentedHex);
      return RemoteIdentityCheck.pinnedFirstUse;
    }
    // Both values are public key material (not secrets), so a non
    // constant-time string compare here leaks nothing an attacker doesn't
    // already have; constant-time comparison is reserved for secret-vs-
    // secret checks elsewhere (e.g. MAC verification).
    return pinnedHex == presentedHex
        ? RemoteIdentityCheck.match
        : RemoteIdentityCheck.changed;
  }

  /// Re-pins a peer's key after the user explicitly accepted the change
  /// (e.g. verified the new safety number out of band).
  Future<void> acceptChangedIdentity({
    required String peerId,
    required Uint8List newPublicKey,
  }) async {
    await _store.write('$_remoteKeyPrefix$peerId', hexEncode(newPublicKey));
  }

  /// Domain tag and version for [safetyNumber]. Both are inside the hash, so a
  /// future version produces entirely different digits rather than colliding
  /// with this one.
  ///
  /// This value is frozen. Two people comparing safety numbers on different
  /// app versions must either see the same number or be told the version
  /// differs — they must never see a mismatch caused by us and read it as an
  /// attack. Changing the derivation means shipping v2 alongside v1 and
  /// displaying which is in use, never editing this.
  static const List<int> _safetyNumberDomainV1 = [
    // "vck-safety-number-v1"
    118, 99, 107, 45, 115, 97, 102, 101, 116, 121,
    45, 110, 117, 109, 98, 101, 114, 45, 118, 49,
  ];

  /// Safety number for out-of-band comparison: sixty decimal digits derived
  /// from both parties' public keys, identical on both devices regardless of
  /// which side asks.
  ///
  /// Derivation, version 1 — frozen, and pinned by a golden vector in
  /// `safety_number_test.dart`:
  ///
  ///   sha256( domain tag || min(keyA, keyB) || max(keyA, keyB) )
  ///   the digest read as a big-endian integer, reduced modulo 10^60,
  ///   left-padded to sixty digits, shown in groups of five.
  ///
  /// The keys are compared and concatenated as raw bytes, so both sides reach
  /// the same input without agreeing who is "local". Reducing the whole digest
  /// modulo 10^60 spends all 256 bits on the sixty digits and is unbiased to
  /// about one part in 10^17; taking digits byte by byte, as an earlier
  /// version did, both threw away most of the digest and made the digits 0-5
  /// roughly twice as likely as 6-9. A safety number's only job is to be hard
  /// to collide on purpose, so that mattered.
  Future<String> safetyNumber({
    required Uint8List localPublicKey,
    required Uint8List remotePublicKey,
  }) async {
    final first = _lexicographicallyFirst(localPublicKey, remotePublicKey);
    final second = identical(first, localPublicKey)
        ? remotePublicKey
        : localPublicKey;

    final input = Uint8List.fromList([
      ..._safetyNumberDomainV1,
      ...first,
      ...second,
    ]);
    final digest = await _engine.sha256(input);

    var value = BigInt.zero;
    for (final byte in digest) {
      value = (value << 8) | BigInt.from(byte);
    }
    final modulus = BigInt.from(10).pow(60);
    final raw = (value % modulus).toString().padLeft(60, '0');

    final groups = <String>[
      for (var i = 0; i < 60; i += 5) raw.substring(i, i + 5),
    ];
    return groups.join(' ');
  }

  /// Byte-wise order, so both devices concatenate the two keys the same way.
  /// Returns whichever argument sorts first; ties (the same key on both sides)
  /// return [a], which makes the concatenation well defined either way.
  static Uint8List _lexicographicallyFirst(Uint8List a, Uint8List b) {
    final shared = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < shared; i++) {
      if (a[i] != b[i]) return a[i] < b[i] ? a : b;
    }
    return a.length <= b.length ? a : b;
  }

  Future<String> _fingerprint(Uint8List publicKey) async {
    final digest = await _engine.sha256(publicKey);
    final hex = hexEncode(digest).toUpperCase();
    final groups = <String>[
      for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4),
    ];
    return groups.join(' ');
  }
}
