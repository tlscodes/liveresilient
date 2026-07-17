// Unit tests: wiring, namespacing, encoding, nullability — against a MOCKED
// platform channel. These prove the adapter drives flutter_secure_storage
// correctly; they do NOT touch a real Keychain (see
// example/integration_test/keychain_store_test.dart for that).

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:security_keychain/security_keychain.dart';

const MethodChannel _channel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Fake Keychain: account key -> stored string value.
  final Map<String, String> fakeKeychain = <String, String>{};

  /// Every method call the mock handler saw, for wiring assertions.
  final List<MethodCall> calls = <MethodCall>[];

  setUp(() {
    fakeKeychain.clear();
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (MethodCall call) async {
          calls.add(call);
          final args = (call.arguments as Map).cast<String, dynamic>();
          final key = args['key'] as String?;
          switch (call.method) {
            case 'read':
              return fakeKeychain[key];
            case 'write':
              fakeKeychain[key!] = args['value'] as String;
              return null;
            case 'delete':
              fakeKeychain.remove(key);
              return null;
            default:
              throw UnimplementedError(call.method);
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  final seed = Uint8List.fromList(
    List<int>.generate(32, (i) => (i * 7) & 0xff),
  );

  test('write -> read round-trips seed bytes exactly', () async {
    final store = KeychainKeyMaterialStore();
    await store.write('primary', seed);
    final back = await store.read('primary');
    expect(back, isNotNull);
    expect(back, equals(seed));
    // Defensive: result is a fresh buffer, not aliased to the input.
    back![0] ^= 0xff;
    expect((await store.read('primary')), equals(seed));
  });

  test('storage key is namespaced as vck.identity.<handle>', () async {
    final store = KeychainKeyMaterialStore();
    await store.write('device-a', seed);
    final writeCall = calls.singleWhere((c) => c.method == 'write');
    final args = (writeCall.arguments as Map).cast<String, dynamic>();
    expect(args['key'], 'vck.identity.device-a');
    expect(KeychainKeyMaterialStore.storageKeyFor('x'), 'vck.identity.x');
  });

  test('seed bytes cross the channel base64-encoded, never raw', () async {
    final store = KeychainKeyMaterialStore();
    await store.write('enc', seed);
    final args = (calls.single.arguments as Map).cast<String, dynamic>();
    final value = args['value'];
    expect(value, isA<String>());
    expect(value, base64Encode(seed));
    expect(base64Decode(value as String), equals(seed));
  });

  test('read of unknown handle returns strict null', () async {
    final store = KeychainKeyMaterialStore();
    expect(await store.read('never-written'), isNull);
  });

  test('write overwrites an existing seed', () async {
    final store = KeychainKeyMaterialStore();
    final other = Uint8List.fromList(List<int>.filled(32, 0x5a));
    await store.write('h', seed);
    await store.write('h', other);
    expect(await store.read('h'), equals(other));
    expect(fakeKeychain.length, 1);
  });

  test('delete removes the seed and is idempotent when absent', () async {
    final store = KeychainKeyMaterialStore();
    await store.write('gone', seed);
    await store.delete('gone');
    expect(await store.read('gone'), isNull);
    // Second delete of a now-absent handle must not throw.
    await expectLater(store.delete('gone'), completes);
    // And deleting a handle that never existed is a no-op too.
    await expectLater(store.delete('never-existed'), completes);
  });

  test(
    'macOS options pin accessibility to first_unlock_this_device',
    () async {
      final store = KeychainKeyMaterialStore();
      await store.write('opt', seed);
      final args = (calls.single.arguments as Map).cast<String, dynamic>();
      final options = (args['options'] as Map).cast<String, String>();
      expect(options['accessibility'], 'first_unlock_this_device');
    },
    // FlutterSecureStorage._selectOptions picks the option set from the
    // HOST dart:io Platform, so this assertion is only meaningful on macOS.
    skip: !Platform.isMacOS
        ? 'options selection is host-OS dependent; macOS-only assertion'
        : false,
  );

  test(
    're-instantiation reads what a previous instance wrote (wiring)',
    () async {
      await KeychainKeyMaterialStore().write('persist', seed);
      expect(await KeychainKeyMaterialStore().read('persist'), equals(seed));
    },
  );
}
