// The identity key on the Montgomery curve. The map from an Ed25519 public
// key to its X25519 twin is checked against a path that never uses it:
// expand the seed the RFC 8032 way, let the library's X25519 derive the
// public key by scalar multiplication, and require the two to be equal.
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:security/security.dart';
import 'package:test/test.dart';

Uint8List _seed(int fill) => Uint8List.fromList(List<int>.filled(32, fill));

/// An engine whose key under `id` was made from [seed].
Future<CryptographyIdentityKeyEngine> _engineFrom(Uint8List seed) async {
  final store = InMemoryKeyStore();
  await store.write('id', seed);
  return CryptographyIdentityKeyEngine(keyStore: store);
}

/// The X25519 public key reached by scalar multiplication alone.
Future<Uint8List> _byScalarMultiplication(Uint8List seed) async {
  final expanded = await Sha512().hash(seed);
  final pair = await X25519().newKeyPairFromSeed(expanded.bytes.sublist(0, 32));
  return Uint8List.fromList((await pair.extractPublicKey()).bytes);
}

void main() {
  group('an Ed25519 public key has one X25519 twin', () {
    test('the map agrees with scalar multiplication, for many keys', () async {
      for (var i = 0; i < 48; i++) {
        final seed = Uint8List.fromList(
          List<int>.generate(32, (j) => (i * 37 + j * 11 + 5) & 0xff),
        );
        final engine = await _engineFrom(seed);
        final edPublic = (await engine.publicKey(keyHandle: 'id'))!;
        expect(
          ed25519PublicKeyToX25519(edPublic),
          await _byScalarMultiplication(seed),
          reason: 'seed #$i',
        );
      }
    });

    test('a freshly generated key maps the same way', () async {
      final store = InMemoryKeyStore();
      final engine = CryptographyIdentityKeyEngine(keyStore: store);
      final edPublic = await engine.generateKeyPair(keyHandle: 'id');
      final seed = (await store.read('id'))!;
      expect(
        ed25519PublicKeyToX25519(edPublic),
        await _byScalarMultiplication(seed),
      );
    });

    test('malformed keys are refused, not mapped', () {
      expect(
        () => ed25519PublicKeyToX25519(Uint8List(31)),
        throwsArgumentError,
      );
      // y = 1: the identity point.
      final identity = Uint8List(32)..[0] = 1;
      expect(() => ed25519PublicKeyToX25519(identity), throwsArgumentError);
      // y = p, not a field element.
      final notInField = Uint8List.fromList(List<int>.filled(32, 0xff))
        ..[0] = 0xed
        ..[31] = 0x7f;
      expect(() => ed25519PublicKeyToX25519(notInField), throwsArgumentError);
    });
  });

  group('two identity keys agree on one secret', () {
    test('each side reaches it from the other side\'s PUBLIC key', () async {
      final a = await _engineFrom(_seed(7));
      final b = await _engineFrom(_seed(9));
      final aPublic = (await a.publicKey(keyHandle: 'id'))!;
      final bPublic = (await b.publicKey(keyHandle: 'id'))!;

      final fromA = await a.agree(
        keyHandle: 'id',
        remoteX25519PublicKey: ed25519PublicKeyToX25519(bPublic),
      );
      final fromB = await b.agree(
        keyHandle: 'id',
        remoteX25519PublicKey: ed25519PublicKeyToX25519(aPublic),
      );
      expect(fromA, hasLength(32));
      expect(fromA, fromB);

      // A third key reaches a different secret.
      final c = await _engineFrom(_seed(11));
      expect(
        await c.agree(
          keyHandle: 'id',
          remoteX25519PublicKey: ed25519PublicKeyToX25519(bPublic),
        ),
        isNot(fromA),
      );
    });

    test('an ephemeral X25519 key and an identity key agree', () async {
      final recipient = await _engineFrom(_seed(21));
      final recipientX = ed25519PublicKeyToX25519(
        (await recipient.publicKey(keyHandle: 'id'))!,
      );
      final x25519 = X25519();
      final ephemeral = await x25519.newKeyPair();
      final senderSide = await x25519.sharedSecretKey(
        keyPair: ephemeral,
        remotePublicKey: SimplePublicKey(recipientX, type: KeyPairType.x25519),
      );
      final recipientSide = await recipient.agree(
        keyHandle: 'id',
        remoteX25519PublicKey: Uint8List.fromList(
          (await ephemeral.extractPublicKey()).bytes,
        ),
      );
      expect(recipientSide, await senderSide.extractBytes());
    });

    test('agreement still leaves signing intact', () async {
      final engine = await _engineFrom(_seed(3));
      final publicKey = (await engine.publicKey(keyHandle: 'id'))!;
      await engine.agree(
        keyHandle: 'id',
        remoteX25519PublicKey: ed25519PublicKeyToX25519(
          (await (await _engineFrom(_seed(4))).publicKey(keyHandle: 'id'))!,
        ),
      );
      final message = Uint8List.fromList([1, 2, 3]);
      final signature = await engine.sign(keyHandle: 'id', message: message);
      expect(
        await engine.verify(
          publicKey: publicKey,
          message: message,
          signature: signature,
        ),
        isTrue,
      );
    });

    test(
      'a missing key, a short key and a low-order point are refused',
      () async {
        final engine = await _engineFrom(_seed(5));
        expect(
          () => engine.agree(
            keyHandle: 'absent',
            remoteX25519PublicKey: Uint8List(32)..[0] = 9,
          ),
          throwsStateError,
        );
        expect(
          () => engine.agree(
            keyHandle: 'id',
            remoteX25519PublicKey: Uint8List(31),
          ),
          throwsArgumentError,
        );
        // u = 0 is a low-order point: the secret would be all zeros.
        expect(
          () => engine.agree(
            keyHandle: 'id',
            remoteX25519PublicKey: Uint8List(32),
          ),
          throwsArgumentError,
        );
      },
    );
  });
}
