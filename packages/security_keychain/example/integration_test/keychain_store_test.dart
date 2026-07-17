// REAL-KEYCHAIN integration tests (run with:
//   flutter test integration_test -d macos
// from packages/security_keychain/example).
//
// Unlike the package's unit tests, nothing here is mocked: every call goes
// through the flutter_secure_storage macOS plugin into the actual Keychain
// of this machine. Cleanup discipline: every handle this file touches is
// listed in [_testHandles] and deleted in tearDown, so the user's Keychain
// is left clean even when an expectation fails mid-test.
//
// Keychain flavor: this host is signed with the ad-hoc "Sign to Run
// Locally" identity (no Apple Development cert on this machine), which
// cannot carry the entitlement the macOS Data Protection keychain requires
// (verified 2026-07-17: entitlement present -> taskgated SIGKILL; absent ->
// errSecMissingEntitlement -34018). So every store below is constructed
// with macUseDataProtectionKeychain: false, exercising the real LOGIN
// keychain instead. Same plugin code path, same OS persistence guarantees
// the adapter contract needs; only the accessibility class enforcement
// differs (documented in the adapter's library docs).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:security/security.dart' show KeyMaterialStore;
import 'package:security_keychain/security_keychain.dart';

/// Every handle any test below may write. tearDown deletes them all.
const List<String> _testHandles = <String>[
  'it.roundtrip',
  'it.persist',
  'it.delete',
  'it.missing',
  'it.overwrite',
];

/// See the header: login-keychain flavor because this debug host is ad-hoc
/// signed. Production (signed) apps use the default constructor.
KeychainKeyMaterialStore _newStore() =>
    KeychainKeyMaterialStore(macUseDataProtectionKeychain: false);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    final store = _newStore();
    for (final handle in _testHandles) {
      await store.delete(handle);
    }
  });

  final seed = Uint8List.fromList(
    List<int>.generate(32, (i) => (i * 31 + 3) & 0xff),
  );

  test('write -> read round-trips 32 seed bytes through the real Keychain',
      () async {
    final KeyMaterialStore store = _newStore();
    await store.write('it.roundtrip', seed);
    final back = await store.read('it.roundtrip');
    expect(back, isNotNull);
    expect(back, equals(seed));
  });

  test('seed persists across store re-instantiation (Keychain, not memory)',
      () async {
    await _newStore().write('it.persist', seed);
    // A brand-new adapter instance (and plugin client) must find the item —
    // the bytes live in the OS Keychain, not in any Dart-side state.
    final back = await _newStore().read('it.persist');
    expect(back, equals(seed));
  });

  test('delete removes the seed; second delete is a no-op', () async {
    final store = _newStore();
    await store.write('it.delete', seed);
    expect(await store.read('it.delete'), isNotNull);
    await store.delete('it.delete');
    expect(await store.read('it.delete'), isNull);
    await expectLater(store.delete('it.delete'), completes);
  });

  test('unknown handle reads as strict null', () async {
    final store = _newStore();
    // Belt-and-braces: make sure no stale item exists from a broken run.
    await store.delete('it.missing');
    expect(await store.read('it.missing'), isNull);
  });

  test('write overwrites an existing seed in place', () async {
    final store = _newStore();
    final replacement = Uint8List.fromList(List<int>.filled(32, 0xa5));
    await store.write('it.overwrite', seed);
    await store.write('it.overwrite', replacement);
    expect(await store.read('it.overwrite'), equals(replacement));
  });
}
