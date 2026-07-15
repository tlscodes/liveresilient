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
  })  : _engine = engine,
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
    return _engine.sign(
      keyHandle: _localKeyHandle,
      message: sessionDigest,
    );
  }

  /// Verifies a peer's signed session fingerprint against their pinned
  /// identity key.
  Future<bool> verifySessionFingerprint({
    required String peerId,
    required Uint8List sessionDigest,
    required Uint8List signature,
  }) async {
    final pinnedHex = await _store.read('$_remoteKeyPrefix$peerId');
    if (pinnedHex == null) return false;
    return _engine.verify(
      publicKey: _hexDecode(pinnedHex),
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
    final presentedHex = _hexEncode(presentedPublicKey);

    if (pinnedHex == null) {
      await _store.write(storageKey, presentedHex);
      return RemoteIdentityCheck.pinnedFirstUse;
    }
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
    await _store.write(
      '$_remoteKeyPrefix$peerId',
      _hexEncode(newPublicKey),
    );
  }

  /// Safety number for out-of-band comparison: a stable digest over both
  /// parties' public keys, identical on both devices regardless of role.
  Future<String> safetyNumber({
    required Uint8List localPublicKey,
    required Uint8List remotePublicKey,
  }) async {
    final a = _hexEncode(localPublicKey);
    final b = _hexEncode(remotePublicKey);
    // Order-independent: sort so both sides derive the same number.
    final combined = a.compareTo(b) <= 0 ? '$a$b' : '$b$a';
    final digest = await _engine.sha256(
      Uint8List.fromList(combined.codeUnits),
    );
    // 60 decimal digits in groups of 5, matching familiar safety-number UX.
    final digits = StringBuffer();
    for (var i = 0; i < digest.length && digits.length < 60; i++) {
      digits.write((digest[i] % 10).toString());
      digits.write((digest[i] ~/ 10 % 10).toString());
    }
    final raw = digits.toString().substring(0, 60);
    final groups = <String>[
      for (var i = 0; i < 60; i += 5) raw.substring(i, i + 5),
    ];
    return groups.join(' ');
  }

  Future<String> _fingerprint(Uint8List publicKey) async {
    final digest = await _engine.sha256(publicKey);
    final hex = _hexEncode(digest).toUpperCase();
    final groups = <String>[
      for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4),
    ];
    return groups.join(' ');
  }

  static String _hexEncode(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _hexDecode(String hex) {
    if (hex.length.isOdd) {
      throw FormatException('Hex string has odd length: ${hex.length}');
    }
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
