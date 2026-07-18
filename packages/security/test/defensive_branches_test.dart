/// Defensive-branch matrix: misbehaving engines, corrupted persisted
/// material, and malformed inputs must fail loudly instead of producing a
/// silently broken identity.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:security/security.dart';
import 'package:test/test.dart';

class InMemorySecureKeyValueStore implements SecureKeyValueStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// An engine that violates the Ed25519 contract by returning a 16-byte
/// public key — simulating a broken platform keystore.
class WrongSizeKeyEngine implements IdentityKeyEngine {
  @override
  Future<Uint8List> generateKeyPair({required String keyHandle}) async =>
      Uint8List(16);

  @override
  Future<Uint8List?> publicKey({required String keyHandle}) async => null;

  @override
  Future<Uint8List> sign({
    required String keyHandle,
    required Uint8List message,
  }) async => Uint8List(64);

  @override
  Future<bool> verify({
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) async => true;

  @override
  Future<Uint8List> sha256(Uint8List input) async => Uint8List(32);
}

void main() {
  group('IdentityStore defensive branches', () {
    IdentityStore realStore() => IdentityStore(
      engine: CryptographyIdentityKeyEngine(keyStore: InMemoryKeyStore()),
      store: InMemorySecureKeyValueStore(),
    );

    test('an engine returning a non-32-byte public key is rejected', () async {
      final store = IdentityStore(
        engine: WrongSizeKeyEngine(),
        store: InMemorySecureKeyValueStore(),
      );
      await expectLater(store.localIdentity(), throwsA(isA<StateError>()));
    });

    test('checkRemoteIdentity rejects an empty peerId and a wrong-size '
        'key', () async {
      final store = realStore();
      await expectLater(
        store.checkRemoteIdentity(
          peerId: '',
          presentedPublicKey: Uint8List(32),
        ),
        throwsArgumentError,
      );
      await expectLater(
        store.checkRemoteIdentity(
          peerId: 'peer-1',
          presentedPublicKey: Uint8List(16),
        ),
        throwsArgumentError,
      );
    });

    test('verifySessionFingerprint rejects an empty peerId', () async {
      final store = realStore();
      await expectLater(
        store.verifySessionFingerprint(
          peerId: '',
          sessionDigest: Uint8List(32),
          signature: Uint8List(64),
        ),
        throwsArgumentError,
      );
    });

    test('a corrupted (odd-length hex) pinned key fails loudly when used '
        'for verification', () async {
      final kv = InMemorySecureKeyValueStore();
      final store = IdentityStore(
        engine: CryptographyIdentityKeyEngine(keyStore: InMemoryKeyStore()),
        store: kv,
      );
      await kv.write('peer-identity:peer-1', 'abc'); // odd-length hex
      await expectLater(
        store.verifySessionFingerprint(
          peerId: 'peer-1',
          sessionDigest: Uint8List(32),
          signature: Uint8List(64),
        ),
        throwsFormatException,
      );
    });
  });

  group('KeyMaterialStore defensive branches', () {
    test('InMemoryKeyStore.read returns null for an unknown handle', () async {
      expect(await InMemoryKeyStore().read('missing'), isNull);
    });

    test('DevFileKeyStore rejects corrupted odd-length hex material', () async {
      final dir = await Directory.systemTemp.createTemp('security_test_');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/keys.json';
      File(path).writeAsStringSync('{"handle-1": "abc"}'); // odd-length hex

      await expectLater(
        DevFileKeyStore(path).read('handle-1'),
        throwsFormatException,
      );
    });

    test(
      'DevFileKeyStore treats a handle whose value is a non-string JSON '
      '(e.g. an integer) as missing rather than throwing — corruption at '
      'this specific spot is masked as absence, current pinned behavior',
      () async {
        final dir = await Directory.systemTemp.createTemp('security_test_');
        addTearDown(() => dir.delete(recursive: true));
        final path = '${dir.path}/keys.json';
        File(path).writeAsStringSync('{"handle-1": 42}');

        expect(await DevFileKeyStore(path).read('handle-1'), isNull);
      },
    );

    test('DevFileKeyStore serializes concurrent writes so neither is lost '
        '(no read-modify-write race)', () async {
      final dir = await Directory.systemTemp.createTemp('security_test_');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/keys.json';
      final store = DevFileKeyStore(path);

      await Future.wait([
        store.write('h1', Uint8List.fromList([1, 2, 3])),
        store.write('h2', Uint8List.fromList([4, 5, 6])),
      ]);

      expect(await store.read('h1'), equals(Uint8List.fromList([1, 2, 3])));
      expect(await store.read('h2'), equals(Uint8List.fromList([4, 5, 6])));
    });
  });

  group('LogRedactor JWT rule', () {
    test('a JWT-shaped token is replaced with [jwt]', () {
      final line =
          'auth failed for eyJhbGciOiJFZERTQSJ9.eyJzdWIiOiJ1LTEifQ.c2ln';
      final result = LogRedactor.redact(line);
      expect(result, contains('[jwt]'));
      expect(result, isNot(contains('eyJhbGci')));
    });
  });
}
