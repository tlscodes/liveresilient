import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:cryptography/cryptography.dart' hide Hkdf;
import 'package:test/test.dart';

Uint8List _random32([int seed = 17]) {
  final random = Random(seed);
  return Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
}

void main() {
  group('X25519KeyAgreement', () {
    late X25519KeyAgreement agreement;

    setUp(() => agreement = X25519KeyAgreement());

    test('both sides derive the same secret from opposite halves', () async {
      final alice = await agreement.generateEphemeral();
      final bob = await agreement.generateEphemeral();

      final fromAlice = await agreement.sharedSecret(
        privateKey: alice.privateKey,
        peerPublicKey: bob.publicKey,
      );
      final fromBob = await agreement.sharedSecret(
        privateKey: bob.privateKey,
        peerPublicKey: alice.publicKey,
      );
      expect(fromAlice, fromBob);
      expect(fromAlice, hasLength(32));
    });

    test('a third party derives a different secret', () async {
      final alice = await agreement.generateEphemeral();
      final bob = await agreement.generateEphemeral();
      final eve = await agreement.generateEphemeral();

      final real = await agreement.sharedSecret(
        privateKey: alice.privateKey,
        peerPublicKey: bob.publicKey,
      );
      final forged = await agreement.sharedSecret(
        privateKey: eve.privateKey,
        peerPublicKey: bob.publicKey,
      );
      expect(real, isNot(forged));
    });

    test('generates fresh keys every time', () async {
      final a = await agreement.generateEphemeral();
      final b = await agreement.generateEphemeral();
      expect(a.publicKey, isNot(b.publicKey));
      expect(a.privateKey, hasLength(32));
    });

    test('rejects a key of the wrong length', () {
      expect(
        () => agreement.sharedSecret(
          privateKey: Uint8List(16),
          peerPublicKey: Uint8List(32),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('matches RFC 7748 section 6.1', () async {
      // The RFC's own worked example: Alice's and Bob's private keys, and
      // the shared secret they must produce.
      Uint8List hex(String s) => Uint8List.fromList([
            for (var i = 0; i < s.length; i += 2)
              int.parse(s.substring(i, i + 2), radix: 16),
          ]);
      final alicePrivate = hex(
        '77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a',
      );
      final bobPublic = hex(
        'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f',
      );
      final expected = hex(
        '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742',
      );
      expect(
        await agreement.sharedSecret(
          privateKey: alicePrivate,
          peerPublicKey: bobPublic,
        ),
        expected,
      );
    });
  });

  group('admission handshake', () {
    late RealityRelayIdentity relay;
    late RealityClientKeyExchange client;

    setUp(() async {
      relay = await RealityRelayIdentity.generate();
      client = RealityClientKeyExchange(relayPublicKey: relay.publicKey);
    });

    Future<Uint8List> hello(RealityClientHandshake handshake) async =>
        UtlsClientHelloBuilder.wrapInRecord(
          client.buildHello(
            handshake: handshake,
            builder: UtlsClientHelloBuilder(
              profile: UtlsClientProfile.safari17, // X25519-only key share
              random: Random(3),
            ),
            serverName: 'edge.example',
          ),
        );

    test('the relay admits a client that ran the exchange', () async {
      final auth = RealityKeyExchangeAuthenticator(identity: relay);
      final handshake = await client.begin(
        clientRandom: _random32(),
        timeSlot: auth.currentTimeSlot,
      );
      final decision = await auth.inspect(
        TlsClientHello.parseRecord(await hello(handshake)),
      );
      expect(decision.admitted, isTrue);
      expect(decision.credential!.shortId, handshake.credential.shortId);
    });

    test('no pre-shared secret travels: the hello carries only a public key',
        () async {
      final auth = RealityKeyExchangeAuthenticator(identity: relay);
      final handshake = await client.begin(
        clientRandom: _random32(),
        timeSlot: auth.currentTimeSlot,
      );
      final bytes = await hello(handshake);
      expect(_contains(bytes, handshake.ephemeral.publicKey), isTrue,
          reason: 'the ephemeral public key is in the key_share');
      expect(_contains(bytes, handshake.ephemeral.privateKey), isFalse);
      expect(_contains(bytes, handshake.credential.authKey), isFalse,
          reason: 'the tag key is derived, never transmitted');
      expect(_contains(bytes, relay.keyPair.privateKey), isFalse);
    });

    test('a client with the wrong relay public key is passed through',
        () async {
      final auth = RealityKeyExchangeAuthenticator(identity: relay);
      final imposter = RealityClientKeyExchange(
        relayPublicKey: (await RealityRelayIdentity.generate()).publicKey,
      );
      final handshake = await imposter.begin(
        clientRandom: _random32(),
        timeSlot: auth.currentTimeSlot,
      );
      final decision = await auth.inspect(TlsClientHello.parseRecord(
        UtlsClientHelloBuilder.wrapInRecord(
          imposter.buildHello(
            handshake: handshake,
            builder: UtlsClientHelloBuilder(
              profile: UtlsClientProfile.safari17,
              random: Random(3),
            ),
            serverName: 'edge.example',
          ),
        ),
      ));
      expect(decision.admitted, isFalse);
      expect(decision.reason, RealityRejectReason.unknownShortId);
    });

    test('an ordinary browser hello is passed through', () async {
      final auth = RealityKeyExchangeAuthenticator(identity: relay);
      final decision = await auth.inspect(TlsClientHello.parseRecord(
        UtlsClientHelloBuilder.wrapInRecord(
          UtlsClientHelloBuilder(
            profile: UtlsClientProfile.chrome120,
            random: Random(11),
          ).build(serverName: 'edge.example'),
        ),
      ));
      expect(decision.admitted, isFalse);
    });

    test('a hello with no X25519 key share is passed through', () async {
      final auth = RealityKeyExchangeAuthenticator(identity: relay);
      final handshake = await client.begin(
        clientRandom: _random32(),
        timeSlot: auth.currentTimeSlot,
      );
      // Chrome's builder puts a placeholder hybrid share in, and its plain
      // X25519 entry is a zero placeholder, not our ephemeral key.
      final decision = await auth.inspect(TlsClientHello.parseRecord(
        UtlsClientHelloBuilder.wrapInRecord(
          UtlsClientHelloBuilder(
            profile: UtlsClientProfile.chrome120,
            random: Random(2),
          ).build(
            serverName: 'edge.example',
            clientRandom: handshake.clientRandom,
            sessionId: handshake.sessionId,
          ),
        ),
      ));
      expect(decision.admitted, isFalse);
    });

    test('a replayed hello is admitted once and no more', () async {
      final auth = RealityKeyExchangeAuthenticator(identity: relay);
      final handshake = await client.begin(
        clientRandom: _random32(),
        timeSlot: auth.currentTimeSlot,
      );
      final record = await hello(handshake);
      expect((await auth.inspect(TlsClientHello.parseRecord(record))).admitted,
          isTrue);
      // A fresh authenticator would admit it again, so the replay memory
      // has to live on the long-lived guard — which it does.
      final replay = await auth.inspect(TlsClientHello.parseRecord(record));
      expect(replay.admitted, isFalse);
      expect(replay.reason, RealityRejectReason.replayedHello);
    });

    test('a stale time slot is passed through', () async {
      final auth = RealityKeyExchangeAuthenticator(identity: relay);
      final handshake = await client.begin(
        clientRandom: _random32(),
        timeSlot: auth.currentTimeSlot - 90,
      );
      final decision = await auth.inspect(
        TlsClientHello.parseRecord(await hello(handshake)),
      );
      expect(decision.reason, RealityRejectReason.staleTimeSlot);
    });

    test('each connection derives a different credential', () async {
      final auth = RealityKeyExchangeAuthenticator(identity: relay);
      final a = await client.begin(
        clientRandom: _random32(1),
        timeSlot: auth.currentTimeSlot,
      );
      final b = await client.begin(
        clientRandom: _random32(2),
        timeSlot: auth.currentTimeSlot,
      );
      expect(a.credential.shortId, isNot(b.credential.shortId),
          reason: 'ephemeral keys make every connection independent');
    });
  });

  group('session key derivation', () {
    test('is deterministic and separated from the admission key', () async {
      final agreement = X25519KeyAgreement();
      final a = await agreement.generateEphemeral();
      final b = await agreement.generateEphemeral();
      final shared = await agreement.sharedSecret(
        privateKey: a.privateKey,
        peerPublicKey: b.publicKey,
      );

      final session = deriveSessionKey(shared);
      expect(session, hasLength(32));
      expect(deriveSessionKey(shared), session);
      expect(session, isNot(RealityCredential.fromSharedSecret(shared).authKey),
          reason: 'a different HKDF label must give a different key');
    });

    test('honors the requested length', () async {
      final key = deriveSessionKey(_random32(), length: 64);
      expect(key, hasLength(64));
    });
  });

  group('RealityIdentityProof — where the 64-byte signature lives', () {
    late SimpleKeyPair identityKey;
    late Uint8List transcript;

    setUp(() async {
      identityKey = await Ed25519().newKeyPair();
      transcript = realityHandshakeTranscript(
        clientRandom: _random32(4),
        ephemeralPublicKey: _random32(5),
        shortId: Uint8List.fromList(List<int>.filled(8, 0x11)),
        timeSlot: 29_000_000,
      );
    });

    test('the frame is 100 bytes: a 4-byte header plus key and signature',
        () async {
      final proof = await RealityIdentityProof.create(
        keyPair: identityKey,
        transcript: transcript,
      );
      final frame = proof.encode();
      expect(frame, hasLength(RealityIdentityProof.frameLength));
      expect(frame.length, 100);
      expect(proof.signature, hasLength(64),
          reason: 'the full 64 bytes, which session_id could never hold');
      expect(proof.publicKey, hasLength(32));
    });

    test('round-trips through encode and decode', () async {
      final proof = await RealityIdentityProof.create(
        keyPair: identityKey,
        transcript: transcript,
      );
      final decoded = RealityIdentityProof.decode(proof.encode());
      expect(decoded.publicKey, proof.publicKey);
      expect(decoded.signature, proof.signature);
      expect(await decoded.verify(transcript), isTrue);
    });

    test('verification fails against a different transcript', () async {
      final proof = await RealityIdentityProof.create(
        keyPair: identityKey,
        transcript: transcript,
      );
      final other = realityHandshakeTranscript(
        clientRandom: _random32(99),
        ephemeralPublicKey: _random32(5),
        shortId: Uint8List.fromList(List<int>.filled(8, 0x11)),
        timeSlot: 29_000_000,
      );
      expect(await proof.verify(other), isFalse,
          reason: 'a proof lifted from another connection must not verify');
    });

    test('verification fails for a signature from another identity',
        () async {
      final proof = await RealityIdentityProof.create(
        keyPair: identityKey,
        transcript: transcript,
      );
      final other = await RealityIdentityProof.create(
        keyPair: await Ed25519().newKeyPair(),
        transcript: transcript,
      );
      final mixed = RealityIdentityProof(
        publicKey: proof.publicKey,
        signature: other.signature,
      );
      expect(await mixed.verify(transcript), isFalse);
    });

    test('a garbage signature is a false verification, not a crash',
        () async {
      final proof = RealityIdentityProof(
        publicKey: Uint8List(32),
        signature: Uint8List(64),
      );
      expect(await proof.verify(transcript), isFalse);
    });

    test('decode rejects a short, mistyped, or mis-declared frame', () async {
      final good = (await RealityIdentityProof.create(
        keyPair: identityKey,
        transcript: transcript,
      ))
          .encode();

      expect(() => RealityIdentityProof.decode(Uint8List(20)),
          throwsFormatException);

      final wrongType = Uint8List.fromList(good)..[0] = 0x02;
      expect(() => RealityIdentityProof.decode(wrongType),
          throwsFormatException);

      final wrongVersion = Uint8List.fromList(good)..[1] = 0x09;
      expect(() => RealityIdentityProof.decode(wrongVersion),
          throwsFormatException);

      final wrongLength = Uint8List.fromList(good);
      ByteData.sublistView(wrongLength).setUint16(2, 40);
      expect(() => RealityIdentityProof.decode(wrongLength),
          throwsFormatException);
    });

    test('the transcript binds every handshake value', () {
      final base = realityHandshakeTranscript(
        clientRandom: _random32(4),
        ephemeralPublicKey: _random32(5),
        shortId: Uint8List.fromList(List<int>.filled(8, 0x11)),
        timeSlot: 29_000_000,
      );
      final variants = [
        realityHandshakeTranscript(
          clientRandom: _random32(6),
          ephemeralPublicKey: _random32(5),
          shortId: Uint8List.fromList(List<int>.filled(8, 0x11)),
          timeSlot: 29_000_000,
        ),
        realityHandshakeTranscript(
          clientRandom: _random32(4),
          ephemeralPublicKey: _random32(7),
          shortId: Uint8List.fromList(List<int>.filled(8, 0x11)),
          timeSlot: 29_000_000,
        ),
        realityHandshakeTranscript(
          clientRandom: _random32(4),
          ephemeralPublicKey: _random32(5),
          shortId: Uint8List.fromList(List<int>.filled(8, 0x22)),
          timeSlot: 29_000_000,
        ),
        realityHandshakeTranscript(
          clientRandom: _random32(4),
          ephemeralPublicKey: _random32(5),
          shortId: Uint8List.fromList(List<int>.filled(8, 0x11)),
          timeSlot: 29_000_001,
        ),
      ];
      for (final variant in variants) {
        expect(variant, isNot(base));
      }
    });

    test('end to end: exchange, admit, then prove identity', () async {
      final relay = await RealityRelayIdentity.generate();
      final client = RealityClientKeyExchange(relayPublicKey: relay.publicKey);
      final auth = RealityKeyExchangeAuthenticator(identity: relay);

      final handshake = await client.begin(
        clientRandom: _random32(21),
        timeSlot: auth.currentTimeSlot,
      );
      final record = UtlsClientHelloBuilder.wrapInRecord(
        client.buildHello(
          handshake: handshake,
          builder: UtlsClientHelloBuilder(
            profile: UtlsClientProfile.safari17,
            random: Random(3),
          ),
          serverName: 'edge.example',
        ),
      );

      final decision = await auth.inspect(TlsClientHello.parseRecord(record));
      expect(decision.admitted, isTrue);

      // First record after admission: the identity proof the hello had no
      // room for.
      final proof = await RealityIdentityProof.create(
        keyPair: identityKey,
        transcript: handshake.transcript,
      );
      final onWire = proof.encode();

      // Relay side: rebuild the transcript from what it received, then
      // verify. It never needed the client's transcript object.
      final relayTranscript = realityHandshakeTranscript(
        clientRandom: decision.hello!.random,
        ephemeralPublicKey: handshake.ephemeral.publicKey,
        shortId: decision.credential!.shortId,
        timeSlot: handshake.timeSlot,
      );
      expect(
        await RealityIdentityProof.decode(onWire).verify(relayTranscript),
        isTrue,
      );
    });
  });
}

bool _contains(Uint8List haystack, Uint8List needle) {
  if (needle.isEmpty) return false;
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}
