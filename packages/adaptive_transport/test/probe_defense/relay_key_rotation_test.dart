import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:clock/clock.dart' as pkg_clock;
import 'package:test/test.dart';

final _agreement = X25519KeyAgreement();

Uint8List _random32([int seed = 41]) {
  final random = Random(seed);
  return Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
}

/// A hello authenticated against [relayPublicKey].
Future<Uint8List> _hello({
  required Uint8List relayPublicKey,
  required int timeSlot,
  int randomSeed = 41,
}) async {
  final client = RealityClientKeyExchange(relayPublicKey: relayPublicKey);
  final handshake = await client.begin(
    clientRandom: _random32(randomSeed),
    timeSlot: timeSlot,
  );
  return UtlsClientHelloBuilder.wrapInRecord(
    client.buildHello(
      handshake: handshake,
      builder: UtlsClientHelloBuilder(
        profile: UtlsClientProfile.safari17,
        random: Random(5),
      ),
      serverName: 'edge.example',
    ),
  );
}

Future<RelayKeyEpoch> _epoch(int number) async =>
    RelayKeyEpoch(epoch: number, keyPair: await _agreement.generateEphemeral());

void main() {
  group('RelayKeyRing construction', () {
    test('generate() stages a next key one epoch ahead', () async {
      final ring = await RelayKeyRing.generate();
      expect(ring.next, isNotNull);
      expect(ring.next!.epoch, ring.current.epoch + 1);
      expect(ring.previous, isNull);
      expect(ring.current.publicKey, hasLength(32));
    });

    test('rejects an inverted or overlong configuration', () async {
      final current = await _epoch(10);
      expect(
        () => RelayKeyRing(
          current: current,
          previous: RelayKeyEpoch(epoch: 11, keyPair: current.keyPair),
        ),
        throwsA(isA<KeyRotationError>()),
      );
      expect(
        () => RelayKeyRing(
          current: current,
          next: RelayKeyEpoch(epoch: 9, keyPair: current.keyPair),
        ),
        throwsA(isA<KeyRotationError>()),
      );
      expect(
        () => RelayKeyRing(
          current: current,
          epochDuration: const Duration(days: 1),
          gracePeriod: const Duration(days: 3),
        ),
        throwsA(isA<KeyRotationError>()),
        reason: 'a grace window longer than an epoch outlives its successor',
      );
    });

    test('epoch numbers advance with the clock', () async {
      final origin = DateTime.utc(2026, 7, 27);
      final ring = RelayKeyRing(
        current: await _epoch(0),
        epochDuration: const Duration(days: 7),
        origin: origin,
      );
      expect(ring.epochAt(origin), 0);
      expect(ring.epochAt(origin.add(const Duration(days: 6))), 0);
      expect(ring.epochAt(origin.add(const Duration(days: 7))), 1);
      expect(ring.epochAt(origin.add(const Duration(days: 21))), 3);
    });

    test('the announcement carries public keys only', () async {
      final ring = await RelayKeyRing.generate();
      final announcement = ring.announcement;
      expect(announcement.currentPublicKey, ring.current.publicKey);
      expect(announcement.nextPublicKey, ring.next!.publicKey);
      expect(
        announcement.currentPublicKey,
        isNot(ring.current.keyPair.privateKey),
      );
    });
  });

  group('rotation mechanics', () {
    test(
      'rotate promotes next to current and demotes current to previous',
      () async {
        final ring = await RelayKeyRing.generate();
        final wasCurrent = ring.current;
        final wasNext = ring.next!;

        ring.rotate(freshNext: (await _agreement.generateEphemeral()));

        expect(ring.current.epoch, wasNext.epoch);
        expect(ring.current.publicKey, wasNext.publicKey);
        expect(ring.previous!.publicKey, wasCurrent.publicKey);
        expect(ring.next!.epoch, wasNext.epoch + 1);
      },
    );

    test(
      'rotating with no staged next is an error, not a silent no-op',
      () async {
        final ring = RelayKeyRing(current: await _epoch(1));
        expect(
          () => ring.rotate(
            freshNext: KeyPairBytes(
              publicKey: Uint8List(32),
              privateKey: Uint8List(32),
            ),
          ),
          throwsA(isA<KeyRotationError>()),
        );
      },
    );

    test('stageNext installs a next key on a bare ring', () async {
      final ring = RelayKeyRing(current: await _epoch(4));
      expect(ring.next, isNull);
      ring.stageNext(await _agreement.generateEphemeral());
      expect(ring.next!.epoch, 5);
    });

    test('the previous key is admissible during grace and not after', () async {
      final start = DateTime.utc(2026, 7, 27, 12);
      late RelayKeyRing ring;
      await pkg_clock.withClock(pkg_clock.Clock.fixed(start), () async {
        ring = await RelayKeyRing.generate(
          gracePeriod: const Duration(hours: 6),
        );
        ring.rotate(freshNext: await _agreement.generateEphemeral());
        expect(ring.previousInGrace, isTrue);
        expect(ring.admissibleKeys, hasLength(2));
      });

      pkg_clock.withClock(
        pkg_clock.Clock.fixed(start.add(const Duration(hours: 5))),
        () {
          expect(ring.previousInGrace, isTrue);
          expect(ring.admissibleKeys, hasLength(2));
        },
      );
      pkg_clock.withClock(
        pkg_clock.Clock.fixed(start.add(const Duration(hours: 7))),
        () {
          expect(ring.previousInGrace, isFalse);
          expect(
            ring.admissibleKeys,
            hasLength(1),
            reason: 'an expired key must stop authenticating',
          );
        },
      );
    });

    test(
      'retireExpired drops the previous key once, then does nothing',
      () async {
        final start = DateTime.utc(2026, 7, 27);
        late RelayKeyRing ring;
        await pkg_clock.withClock(pkg_clock.Clock.fixed(start), () async {
          ring = await RelayKeyRing.generate(
            gracePeriod: const Duration(hours: 1),
          );
          ring.rotate(freshNext: await _agreement.generateEphemeral());
          expect(ring.retireExpired(), isFalse, reason: 'still in grace');
        });
        pkg_clock.withClock(
          pkg_clock.Clock.fixed(start.add(const Duration(hours: 2))),
          () {
            expect(ring.retireExpired(), isTrue);
            expect(ring.previous, isNull);
            expect(ring.retireExpired(), isFalse);
          },
        );
      },
    );

    test('the ring never holds more than three keys', () async {
      final ring = await RelayKeyRing.generate();
      for (var i = 0; i < 5; i++) {
        ring.rotate(freshNext: await _agreement.generateEphemeral());
        final held = [
          ring.current,
          ring.previous,
          ring.next,
        ].where((k) => k != null).length;
        expect(held, lessThanOrEqualTo(RelayKeyRing.maxKeys));
      }
    });

    test('rotationDue fires once the clock reaches the next epoch', () async {
      final origin = DateTime.utc(2026, 7, 27);
      late RelayKeyRing ring;
      await pkg_clock.withClock(pkg_clock.Clock.fixed(origin), () async {
        ring = await RelayKeyRing.generate(
          epochDuration: const Duration(days: 7),
          origin: origin,
        );
        expect(ring.rotationDue, isFalse);
      });
      pkg_clock.withClock(
        pkg_clock.Clock.fixed(origin.add(const Duration(days: 8))),
        () => expect(ring.rotationDue, isTrue),
      );
    });
  });

  group('admission across epochs', () {
    test(
      'a client on the current key is admitted with no update signal',
      () async {
        final ring = await RelayKeyRing.generate();
        final auth = RotatingRealityAuthenticator(ring: ring);
        final record = await _hello(
          relayPublicKey: ring.current.publicKey,
          timeSlot: auth.currentTimeSlot,
        );

        final result = await auth.inspect(TlsClientHello.parseRecord(record));
        expect(result.admitted, isTrue);
        expect(result.epoch, ring.current.epoch);
        expect(result.keyUpdateRequired, isFalse);
        expect(result.keysTried, 1);
      },
    );

    test('zero downtime: a client on the outgoing key still connects, and '
        'is told to update', () async {
      final start = DateTime.utc(2026, 7, 27, 12);
      await pkg_clock.withClock(pkg_clock.Clock.fixed(start), () async {
        final ring = await RelayKeyRing.generate(
          gracePeriod: const Duration(hours: 6),
        );
        final oldKey = ring.current.publicKey;
        final auth = RotatingRealityAuthenticator(ring: ring);

        // The client's config predates the rotation.
        final record = await _hello(
          relayPublicKey: oldKey,
          timeSlot: auth.currentTimeSlot,
        );
        ring.rotate(freshNext: await _agreement.generateEphemeral());

        final result = await auth.inspect(TlsClientHello.parseRecord(record));
        expect(
          result.admitted,
          isTrue,
          reason: 'rotation must not drop an in-flight client',
        );
        expect(result.keyUpdateRequired, isTrue);
        expect(result.epoch, ring.previous!.epoch);
        expect(result.keysTried, 2);
      });
    });

    test('once grace expires, the old key no longer authenticates', () async {
      final start = DateTime.utc(2026, 7, 27, 12);
      late RelayKeyRing ring;
      late Uint8List record;
      late RotatingRealityAuthenticator auth;

      await pkg_clock.withClock(pkg_clock.Clock.fixed(start), () async {
        ring = await RelayKeyRing.generate(
          gracePeriod: const Duration(hours: 2),
        );
        auth = RotatingRealityAuthenticator(ring: ring);
        record = await _hello(
          relayPublicKey: ring.current.publicKey,
          timeSlot: auth.currentTimeSlot,
        );
        ring.rotate(freshNext: await _agreement.generateEphemeral());
      });

      await pkg_clock.withClock(
        pkg_clock.Clock.fixed(start.add(const Duration(hours: 3))),
        () async {
          final result = await auth.inspect(TlsClientHello.parseRecord(record));
          expect(result.admitted, isFalse);
          expect(result.decision.reason, RealityRejectReason.unknownShortId);
          expect(result.keysTried, 1, reason: 'only the current key is left');
        },
      );
    });

    test('the next key is not accepted before its epoch begins', () async {
      final ring = await RelayKeyRing.generate();
      final auth = RotatingRealityAuthenticator(ring: ring);
      final record = await _hello(
        relayPublicKey: ring.next!.publicKey,
        timeSlot: auth.currentTimeSlot,
      );

      final result = await auth.inspect(TlsClientHello.parseRecord(record));
      expect(
        result.admitted,
        isFalse,
        reason:
            'accepting it early widens the window a stolen key is '
            'useful in',
      );
    });

    test(
      'an unrelated key is passed through after the bounded trial',
      () async {
        final start = DateTime.utc(2026, 7, 27);
        await pkg_clock.withClock(pkg_clock.Clock.fixed(start), () async {
          final ring = await RelayKeyRing.generate();
          ring.rotate(freshNext: await _agreement.generateEphemeral());
          final auth = RotatingRealityAuthenticator(ring: ring);
          final stranger = await _agreement.generateEphemeral();

          final result = await auth.inspect(
            TlsClientHello.parseRecord(
              await _hello(
                relayPublicKey: stranger.publicKey,
                timeSlot: auth.currentTimeSlot,
              ),
            ),
          );
          expect(result.admitted, isFalse);
          expect(
            result.keysTried,
            lessThanOrEqualTo(RelayKeyRing.maxKeys),
            reason: 'trial cost is bounded even for a probe',
          );
        });
      },
    );

    test('replay memory survives a rotation', () async {
      final start = DateTime.utc(2026, 7, 27, 12);
      await pkg_clock.withClock(pkg_clock.Clock.fixed(start), () async {
        final ring = await RelayKeyRing.generate(
          gracePeriod: const Duration(hours: 6),
        );
        final auth = RotatingRealityAuthenticator(ring: ring);
        final record = await _hello(
          relayPublicKey: ring.current.publicKey,
          timeSlot: auth.currentTimeSlot,
        );

        expect(
          (await auth.inspect(TlsClientHello.parseRecord(record))).admitted,
          isTrue,
        );
        ring.rotate(freshNext: await _agreement.generateEphemeral());

        final replay = await auth.inspect(TlsClientHello.parseRecord(record));
        expect(replay.admitted, isFalse);
        expect(
          replay.decision.reason,
          RealityRejectReason.replayedHello,
          reason: 'a rotation must not hand an attacker a fresh window',
        );
      });
    });

    test('a browser hello is passed through regardless of the ring', () async {
      final ring = await RelayKeyRing.generate();
      final auth = RotatingRealityAuthenticator(ring: ring);
      final result = await auth.inspect(
        TlsClientHello.parseRecord(
          UtlsClientHelloBuilder.wrapInRecord(
            UtlsClientHelloBuilder(
              profile: UtlsClientProfile.chrome120,
              random: Random(7),
            ).build(serverName: 'edge.example'),
          ),
        ),
      );
      expect(result.admitted, isFalse);
    });

    test('two-key admission costs about two X25519 operations — which is '
        'over the 2ms budget on the pure-Dart backend', () async {
      final start = DateTime.utc(2026, 7, 27);
      await pkg_clock.withClock(pkg_clock.Clock.fixed(start), () async {
        final ring = await RelayKeyRing.generate(
          gracePeriod: const Duration(hours: 6),
        );
        ring.rotate(freshNext: await _agreement.generateEphemeral());
        final auth = RotatingRealityAuthenticator(ring: ring);

        // Worst case: the client is on the previous key, so both keys are
        // tried before a match.
        final oldPublic = ring.previous!.publicKey;
        final hello = TlsClientHello.parseRecord(
          await _hello(
            relayPublicKey: oldPublic,
            timeSlot: auth.currentTimeSlot,
          ),
        );

        const iterations = 40;
        final stopwatch = Stopwatch()..start();
        for (var i = 0; i < iterations; i++) {
          await RotatingRealityAuthenticator(ring: ring).inspect(hello);
        }
        stopwatch.stop();
        final perDecision = stopwatch.elapsedMicroseconds / iterations;
        // Measured, not hoped for: X25519 is ~1876 us/op on the pure-Dart
        // backend (tool/bench_x25519.dart), so a two-key trial lands near
        // 4 ms. This asserts the cost stays proportional to the key count
        // and does not silently grow; it deliberately does NOT assert the
        // 2 ms budget, which this backend cannot meet. Meeting it needs a
        // native X25519 implementation behind KeyAgreement.
        expect(
          perDecision,
          lessThan(12000),
          reason:
              'two X25519 ops plus one HMAC; measured '
              '${perDecision.toStringAsFixed(1)} us',
        );
        expect(
          perDecision,
          greaterThan(1000),
          reason:
              'if this ever drops below one scalar multiply, the '
              'trial loop stopped actually running the agreement',
        );
      });
    });
  });

  group('RelayKeyUpdate frame', () {
    test('round-trips, and is 40 bytes', () async {
      final ring = await RelayKeyRing.generate();
      final update = RelayKeyUpdate.forRing(ring);
      final frame = update.encode();

      expect(frame, hasLength(RelayKeyUpdate.frameLength));
      expect(frame.length, 40);
      final decoded = RelayKeyUpdate.decode(frame);
      expect(decoded.epoch, ring.current.epoch);
      expect(decoded.publicKey, ring.current.publicKey);
    });

    test('does not collide with the identity-proof frame type', () {
      expect(RelayKeyUpdate.frameType, isNot(RealityIdentityProof.frameType));
    });

    test('rejects a short, mistyped, or mis-declared frame', () async {
      final good = RelayKeyUpdate.forRing(
        await RelayKeyRing.generate(),
      ).encode();

      expect(() => RelayKeyUpdate.decode(Uint8List(8)), throwsFormatException);

      final wrongType = Uint8List.fromList(good)..[0] = 0x01;
      expect(() => RelayKeyUpdate.decode(wrongType), throwsFormatException);

      final wrongVersion = Uint8List.fromList(good)..[1] = 0x07;
      expect(() => RelayKeyUpdate.decode(wrongVersion), throwsFormatException);

      final wrongLength = Uint8List.fromList(good);
      ByteData.sublistView(wrongLength).setUint16(2, 8);
      expect(() => RelayKeyUpdate.decode(wrongLength), throwsFormatException);
    });
  });

  group('RelayKeyStore — the client side of an update', () {
    test('applies a newer epoch and then authenticates against it', () async {
      final start = DateTime.utc(2026, 7, 27, 12);
      await pkg_clock.withClock(pkg_clock.Clock.fixed(start), () async {
        final ring = await RelayKeyRing.generate(
          gracePeriod: const Duration(hours: 6),
        );
        final store = RelayKeyStore(
          publicKey: ring.current.publicKey,
          epoch: ring.current.epoch,
        );
        final auth = RotatingRealityAuthenticator(ring: ring);

        ring.rotate(freshNext: await _agreement.generateEphemeral());

        // The relay admits the stale client, then sends the update.
        final stale = await auth.inspect(
          TlsClientHello.parseRecord(
            await _hello(
              relayPublicKey: store.publicKey,
              timeSlot: auth.currentTimeSlot,
            ),
          ),
        );
        expect(stale.keyUpdateRequired, isTrue);

        expect(store.apply(RelayKeyUpdate.forRing(ring)), isTrue);
        expect(store.publicKey, ring.current.publicKey);
        expect(store.epoch, ring.current.epoch);

        // The next connection needs no grace window.
        final fresh = await auth.inspect(
          TlsClientHello.parseRecord(
            await _hello(
              relayPublicKey: store.publicKey,
              timeSlot: auth.currentTimeSlot,
              randomSeed: 77,
            ),
          ),
        );
        expect(fresh.admitted, isTrue);
        expect(fresh.keyUpdateRequired, isFalse);
        expect(fresh.keysTried, 1);
      });
    });

    test('ignores a replayed or backwards update', () async {
      final ring = await RelayKeyRing.generate();
      final store = RelayKeyStore(
        publicKey: ring.current.publicKey,
        epoch: ring.current.epoch,
      );
      final older = RelayKeyUpdate(
        epoch: ring.current.epoch - 1,
        publicKey: Uint8List(32),
      );
      expect(
        store.apply(older),
        isFalse,
        reason: 'a replayed old update must not pin a client backwards',
      );
      expect(store.publicKey, ring.current.publicKey);

      expect(
        store.apply(RelayKeyUpdate.forRing(ring)),
        isFalse,
        reason: 'the same epoch is not newer',
      );
    });
  });
}
