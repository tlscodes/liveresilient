/// OS-keystore-backed [KeyMaterialStore] for Apple platforms.
///
/// Implements the Phase-4 production adapter half that the Flutter shell
/// unblocks: macOS + iOS Keychain via the `flutter_secure_storage` plugin.
/// The Android Keystore half remains a separately tracked blocker (needs a
/// device/emulator).
///
/// ## Protection class (documented choice)
///
/// Items are written with `kSecAttrAccessibleAfterFirstUnlockThisDevice`
/// (`KeychainAccessibility.first_unlock_this_device`):
///
/// * `after_first_unlock…` (not `when_unlocked…`) because an incoming call
///   must be answerable while the phone is locked — the identity key has to
///   be readable by a background VoIP wake after the first unlock following
///   boot.
/// * `…this_device` so the seed is excluded from iCloud/encrypted backups
///   and can never migrate to another device; a restored phone generates a
///   fresh identity instead of cloning the old one.
///
/// On iOS devices this places the item under the Keychain's hardware-rooted
/// (Secure Enclave-derived) class keys. On macOS desktop the item lives in
/// the Data Protection keychain — encrypted at rest and ACL-scoped to this
/// app, but NOT hardware-isolated on non-T2 Macs. No stronger claim is made
/// for desktop.
///
/// ## macOS keychain flavor (Data Protection vs legacy login keychain)
///
/// The macOS Data Protection keychain (the flavor where
/// `kSecAttrAccessible` actually applies) requires the process to carry an
/// application-identifier / keychain-access-groups entitlement — i.e. a
/// REAL signing identity. Verified 2026-07-17 on this repo's example host:
/// with ad-hoc "Sign to Run Locally" signing, adding `keychain-access-groups`
/// gets the app SIGKILLed by taskgated ("Taskgated Invalid Signature"), and
/// omitting it makes Data Protection keychain calls fail with
/// errSecMissingEntitlement (-34018). Production builds are signed, so the
/// default stays `macUseDataProtectionKeychain: true`; dev/test hosts
/// without a signing identity pass `false` to fall back to the legacy
/// file-based login keychain (still encrypted at rest and ACL-gated per-app
/// by the OS, but the accessibility class above is NOT enforced there).
///
/// ## Secrecy discipline
///
/// Per the [KeyMaterialStore] contract the seed bytes are secret: this
/// adapter never logs, never `toString()`s, and never embeds seed material
/// in exception messages. Corrupt ciphertext surfaces as the storage layer's
/// own [FormatException] with no payload echo.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:security/security.dart' show KeyMaterialStore;

/// Keychain accessibility used for every item this adapter writes.
///
/// See the library doc comment for the rationale.
const KeychainAccessibility keychainSeedAccessibility =
    KeychainAccessibility.first_unlock_this_device;

/// [KeyMaterialStore] over the macOS/iOS Keychain.
///
/// Storage layout: handle `h` is stored under Keychain account key
/// `vck.identity.h` with the seed bytes base64-encoded (the plugin's value
/// type is `String`). Unknown handles read back as `null`, writes overwrite,
/// deletes are idempotent — exactly the [KeyMaterialStore] contract.
final class KeychainKeyMaterialStore implements KeyMaterialStore {
  /// Namespace prefix so VoiceCallKit identity seeds can never collide with
  /// other Keychain entries the host app (or other plugins) may create.
  static const String storageKeyPrefix = 'vck.identity.';

  final FlutterSecureStorage _storage;

  /// Creates a store backed by the platform Keychain.
  ///
  /// [storage] is injectable for tests only; production callers use the
  /// default, which pins [keychainSeedAccessibility] on both Apple
  /// platforms.
  ///
  /// [macUseDataProtectionKeychain] (macOS only, ignored when [storage] is
  /// injected): leave `true` for signed apps; pass `false` only for
  /// dev/test hosts running under ad-hoc local signing — see the library
  /// docs ("macOS keychain flavor") for the verified reasoning.
  KeychainKeyMaterialStore({
    FlutterSecureStorage? storage,
    bool macUseDataProtectionKeychain = true,
  }) : _storage =
           storage ??
           FlutterSecureStorage(
             iOptions: const IOSOptions(
               accessibility: keychainSeedAccessibility,
             ),
             mOptions: MacOsOptions(
               accessibility: keychainSeedAccessibility,
               useDataProtectionKeyChain: macUseDataProtectionKeychain,
             ),
           );

  /// Maps an opaque handle to its namespaced Keychain account key.
  static String storageKeyFor(String keyHandle) =>
      '$storageKeyPrefix$keyHandle';

  @override
  Future<Uint8List?> read(String keyHandle) async {
    final encoded = await _storage.read(key: storageKeyFor(keyHandle));
    if (encoded == null) return null;
    try {
      return base64Decode(encoded);
    } catch (_) {
      // base64Decode's own FormatException interpolates the offending
      // string; rethrow a fixed message so the stored payload is never
      // echoed, per this class's secrecy-discipline doc promise.
      throw const FormatException(
        'security_keychain: stored value for key handle is not valid '
        'base64 (payload not echoed)',
      );
    }
  }

  @override
  Future<void> write(String keyHandle, Uint8List seed) async {
    await _storage.write(
      key: storageKeyFor(keyHandle),
      value: base64Encode(seed),
    );
  }

  @override
  Future<void> delete(String keyHandle) async {
    await _storage.delete(key: storageKeyFor(keyHandle));
  }
}
