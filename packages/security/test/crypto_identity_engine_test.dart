import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:security/src/crypto_identity_engine.dart';
import 'package:security/src/key_store.dart';
import 'package:test/test.dart';

Uint8List _msg(String s) => Uint8List.fromList(utf8.encode(s));

String _hexEncode(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('CryptographyIdentityKeyEngine (InMemoryKeyStore)', () {
    late CryptographyIdentityKeyEngine engine;

    setUp(() {
      engine = CryptographyIdentityKeyEngine(keyStore: InMemoryKeyStore());
    });

    test('generateKeyPair returns a 32-byte Ed25519 public key', () async {
      final publicKey = await engine.generateKeyPair(keyHandle: 'h1');
      expect(publicKey.length, 32);
    });

    test('publicKey is null before generation, stable after', () async {
      expect(await engine.publicKey(keyHandle: 'h2'), isNull);
      final generated = await engine.generateKeyPair(keyHandle: 'h2');
      final read1 = await engine.publicKey(keyHandle: 'h2');
      final read2 = await engine.publicKey(keyHandle: 'h2');
      expect(read1, equals(generated));
      expect(read2, equals(generated));
    });

    test('sign/verify roundtrip succeeds for the signing key', () async {
      final publicKey = await engine.generateKeyPair(keyHandle: 'h3');
      final message = _msg('hello voice call kit');
      final signature = await engine.sign(keyHandle: 'h3', message: message);

      final ok = await engine.verify(
        publicKey: publicKey,
        message: message,
        signature: signature,
      );
      expect(ok, isTrue);
    });

    test('verify fails when the payload is tampered', () async {
      final publicKey = await engine.generateKeyPair(keyHandle: 'h4');
      final message = _msg('original payload');
      final signature = await engine.sign(keyHandle: 'h4', message: message);

      final tamperedMessage = _msg('original PAYLOAD');
      final ok = await engine.verify(
        publicKey: publicKey,
        message: tamperedMessage,
        signature: signature,
      );
      expect(ok, isFalse);
    });

    test('verify fails when the signature bytes are tampered', () async {
      final publicKey = await engine.generateKeyPair(keyHandle: 'h5');
      final message = _msg('do not touch this');
      final signature = await engine.sign(keyHandle: 'h5', message: message);

      final tampered = Uint8List.fromList(signature);
      tampered[0] = tampered[0] ^ 0xFF;

      final ok = await engine.verify(
        publicKey: publicKey,
        message: message,
        signature: tampered,
      );
      expect(ok, isFalse);
    });

    test('verify fails when a different key claims the signature', () async {
      final publicKeyA = await engine.generateKeyPair(keyHandle: 'a');
      final publicKeyB = await engine.generateKeyPair(keyHandle: 'b');
      final message = _msg('signed by A');
      final signature = await engine.sign(keyHandle: 'a', message: message);

      expect(publicKeyA, isNot(equals(publicKeyB)));

      final ok = await engine.verify(
        publicKey: publicKeyB,
        message: message,
        signature: signature,
      );
      expect(ok, isFalse);
    });

    test(
      'verify fails cleanly (no throw) on a malformed public key length',
      () async {
        final message = _msg('anything');
        final signature = Uint8List(64);
        final malformedPublicKey = Uint8List(16);

        final ok = await engine.verify(
          publicKey: malformedPublicKey,
          message: message,
          signature: signature,
        );
        expect(ok, isFalse);
      },
    );

    test('sha256 is deterministic and 32 bytes', () async {
      final input = _msg('fingerprint me');
      final a = await engine.sha256(input);
      final b = await engine.sha256(input);
      expect(a.length, 32);
      expect(_hexEncode(a), equals(_hexEncode(b)));
    });

    test('sha256-derived fingerprint hex has no colons', () async {
      final publicKey = await engine.generateKeyPair(keyHandle: 'fp');
      final digest = await engine.sha256(publicKey);
      final hex = _hexEncode(digest);
      expect(hex, matches(RegExp(r'^[0-9a-f]+$')));
      expect(hex.contains(':'), isFalse);
    });

    test('key rotation: new key verifies new sigs, old key still verifies its '
        'own old signatures', () async {
      final oldPublicKey = await engine.generateKeyPair(keyHandle: 'rot');
      final oldMessage = _msg('message under the old key');
      final oldSignature = await engine.sign(
        keyHandle: 'rot',
        message: oldMessage,
      );

      // Rotate: regenerate under the SAME handle.
      final newPublicKey = await engine.generateKeyPair(keyHandle: 'rot');
      expect(newPublicKey, isNot(equals(oldPublicKey)));

      final newMessage = _msg('message under the new key');
      final newSignature = await engine.sign(
        keyHandle: 'rot',
        message: newMessage,
      );

      // The engine now signs with the new key.
      expect(
        await engine.verify(
          publicKey: newPublicKey,
          message: newMessage,
          signature: newSignature,
        ),
        isTrue,
      );

      // The OLD signature, checked against the OLD public key (as a
      // verifier holding a previously-pinned identity would), still
      // verifies: verify() is a pure function of the three arguments,
      // independent of the engine's current handle state.
      expect(
        await engine.verify(
          publicKey: oldPublicKey,
          message: oldMessage,
          signature: oldSignature,
        ),
        isTrue,
      );

      // Cross-checking the old signature against the new key fails.
      expect(
        await engine.verify(
          publicKey: newPublicKey,
          message: oldMessage,
          signature: oldSignature,
        ),
        isFalse,
      );
    });

    test('deleted-key device scenario: sign fails cleanly after the store is '
        'cleared', () async {
      final store = InMemoryKeyStore();
      final freshEngine = CryptographyIdentityKeyEngine(keyStore: store);
      await freshEngine.generateKeyPair(keyHandle: 'device');

      await store.delete('device');
      // The engine's own cache still holds the loaded pair, so use a
      // brand-new engine instance over the now-cleared store to model a
      // fresh process (e.g. app reinstall / storage wipe) with no cache.
      final reloadedEngine = CryptographyIdentityKeyEngine(keyStore: store);

      expect(await reloadedEngine.publicKey(keyHandle: 'device'), isNull);
      expect(
        () => reloadedEngine.sign(
          keyHandle: 'device',
          message: _msg('should not sign'),
        ),
        throwsStateError,
      );
    });
  });

  group('CryptographyIdentityKeyEngine (DevFileKeyStore)', () {
    late Directory tempDir;
    late DevFileKeyStore store;
    late CryptographyIdentityKeyEngine engine;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dev-file-key-store');
      store = DevFileKeyStore('${tempDir.path}/keys.json');
      engine = CryptographyIdentityKeyEngine(keyStore: store);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'persists and reloads the same key pair across engine instances',
      () async {
        final publicKey = await engine.generateKeyPair(keyHandle: 'persisted');
        final message = _msg('durable across restarts');
        final signature = await engine.sign(
          keyHandle: 'persisted',
          message: message,
        );

        final restartedEngine = CryptographyIdentityKeyEngine(keyStore: store);
        final reloadedPublicKey = await restartedEngine.publicKey(
          keyHandle: 'persisted',
        );
        expect(reloadedPublicKey, equals(publicKey));

        final ok = await restartedEngine.verify(
          publicKey: reloadedPublicKey!,
          message: message,
          signature: signature,
        );
        expect(ok, isTrue);
      },
    );

    test('deleted-key device scenario clears the on-disk file entry', () async {
      await engine.generateKeyPair(keyHandle: 'wiped');
      await store.delete('wiped');

      final reloadedEngine = CryptographyIdentityKeyEngine(keyStore: store);
      expect(await reloadedEngine.publicKey(keyHandle: 'wiped'), isNull);
      expect(
        () => reloadedEngine.sign(keyHandle: 'wiped', message: _msg('nope')),
        throwsStateError,
      );
    });
  });
}
