// The letter queue's at-rest key, held only in the device keystore:
// Keychain on iOS and macOS (this device only, readable after the first
// unlock so a parked letter can drain from a background wake), the
// Keystore-backed store on Android. The key bytes are never logged and
// never written to the app's files.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:security/security.dart' show KeyMaterialStore;

class DeviceKeystore implements KeyMaterialStore {
  /// [storage] is injectable for tests only. macOS uses the login
  /// keychain, so an ad-hoc-signed desktop host can hold the key too
  /// (the Data Protection keychain needs a signing entitlement).
  DeviceKeystore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
            mOptions: MacOsOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
              usesDataProtectionKeychain: false,
            ),
          );

  static const String _prefix = 'vck.letters.';

  final FlutterSecureStorage _storage;

  @override
  Future<Uint8List?> read(String keyHandle) async {
    final encoded = await _storage.read(key: '$_prefix$keyHandle');
    if (encoded == null) return null;
    try {
      return base64Decode(encoded);
    } on FormatException {
      // Never echo the stored value.
      throw const FormatException('letter keystore: stored key is not base64');
    }
  }

  @override
  Future<void> write(String keyHandle, Uint8List seed) =>
      _storage.write(key: '$_prefix$keyHandle', value: base64Encode(seed));

  @override
  Future<void> delete(String keyHandle) =>
      _storage.delete(key: '$_prefix$keyHandle');
}
