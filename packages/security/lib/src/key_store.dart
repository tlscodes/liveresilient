/// Storage for identity private-key material (Ed25519 seeds), keyed by
/// handle.
///
/// This is deliberately separate from [SecureKeyValueStore] (see
/// `identity_store.dart`), which only ever holds *public* peer keys.
/// Private key seeds are far more sensitive and get their own narrow
/// contract so a future OS Keystore/Keychain-backed implementation can
/// slot in without touching [IdentityKeyEngine] callers.
///
/// Phase-4 blocker: the production adapter (iOS Keychain / Android
/// Keystore, hardware-backed where available) needs the Flutter app shell
/// and is tracked separately. Until then, callers use [InMemoryKeyStore]
/// (tests, ephemeral runs) or, for local development only, [DevFileKeyStore].
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Persists raw private-key seed bytes by opaque handle.
///
/// Implementations MUST treat the bytes as secret: no logging, no
/// transmission, no inclusion in crash reports.
abstract interface class KeyMaterialStore {
  /// Returns the stored seed for [keyHandle], or null if none exists.
  Future<Uint8List?> read(String keyHandle);

  /// Stores (overwriting any existing) seed bytes for [keyHandle].
  Future<void> write(String keyHandle, Uint8List seed);

  /// Removes any stored seed for [keyHandle]. A no-op if absent.
  Future<void> delete(String keyHandle);
}

/// Volatile, process-lifetime key store. Safe for tests and for engines
/// that regenerate identity on every launch (no persistence guarantees).
class InMemoryKeyStore implements KeyMaterialStore {
  final Map<String, Uint8List> _seeds = <String, Uint8List>{};

  @override
  Future<Uint8List?> read(String keyHandle) async {
    final seed = _seeds[keyHandle];
    return seed == null ? null : Uint8List.fromList(seed);
  }

  @override
  Future<void> write(String keyHandle, Uint8List seed) async {
    _seeds[keyHandle] = Uint8List.fromList(seed);
  }

  @override
  Future<void> delete(String keyHandle) async {
    _seeds.remove(keyHandle);
  }
}

/// !!! DEV-ONLY !!! Persists private-key seeds to a **plaintext** JSON file
/// on disk. There is no encryption, no OS keychain integration, and no
/// access-control beyond the filesystem's own permissions.
///
/// This exists ONLY so a local dev build can keep a stable device identity
/// across restarts before the real secure adapter lands. It MUST NOT be
/// used in any build that ships to a user or handles real call traffic.
///
/// The Phase-4 blocker for the production replacement (iOS Keychain /
/// Android Keystore, hardware-backed where available) needs the Flutter
/// app shell; track it there. Do not extend this class to "harden" it —
/// replace it with the real adapter instead.
class DevFileKeyStore implements KeyMaterialStore {
  final File _file;

  DevFileKeyStore(String path) : _file = File(path);

  Future<Map<String, dynamic>> _readAll() async {
    if (!await _file.exists()) return <String, dynamic>{};
    final contents = await _file.readAsString();
    if (contents.trim().isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(contents);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'DevFileKeyStore file must contain a JSON object.',
      );
    }
    return decoded;
  }

  Future<void> _writeAll(Map<String, dynamic> data) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(jsonEncode(data));
  }

  @override
  Future<Uint8List?> read(String keyHandle) async {
    final data = await _readAll();
    final hex = data[keyHandle];
    if (hex is! String) return null;
    return _hexDecode(hex);
  }

  @override
  Future<void> write(String keyHandle, Uint8List seed) async {
    final data = await _readAll();
    data[keyHandle] = _hexEncode(seed);
    await _writeAll(data);
  }

  @override
  Future<void> delete(String keyHandle) async {
    final data = await _readAll();
    if (data.remove(keyHandle) != null) {
      await _writeAll(data);
    }
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
