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
      // The clock advances past the overlap between rotations, because that
      // is the only legitimate way to rotate repeatedly: rotating again while
      // the previous epoch is still in grace would demote the current epoch
      // over the one still being accepted, cutting exactly the connections
      // the overlap exists to protect. The ring refuses it, so the test does
      // what an operator would do rather than what the old loop did.
      var at = DateTime.utc(2026, 7, 27);
      late RelayKeyRing ring;
      await pkg_clock.withClock(pkg_clock.Clock.fixed(at), () async {
        ring = await RelayKeyRing.generate(origin: at);
      });
      for (var i = 0; i < 5; i++) {
        at = at.add(const Duration(days: 7));
        final fresh = await _agreement.generateEphemeral();
        pkg_clock.withClock(
          pkg_clock.Clock.fixed(at),
          () => ring.rotate(freshNext: fresh),
        );
        final held = [
          ring.current,
          ring.previous,
          ring.next,
        ].where((k) => k != null).length;
        expect(held, lessThanOrEqualTo(RelayKeyRing.maxKeys));
      }
    });

    test('a second rotation inside the overlap is refused', () async {
      final at = DateTime.utc(2026, 7, 27);
      late RelayKeyRing ring;
      await pkg_clock.withClock(pkg_clock.Clock.fixed(at), () async {
        ring = await RelayKeyRing.generate(origin: at);
      });
      final first = await _agreement.generateEphemeral();
      final second = await _agreement.generateEphemeral();
      pkg_clock.withClock(
        pkg_clock.Clock.fixed(at),
        () => ring.rotate(freshNext: first),
      );
      pkg_clock.withClock(pkg_clock.Clock.fixed(at), () {
        expect(
          () => ring.rotate(freshNext: second),
          throwsA(isA<KeyRotationError>()),
          reason:
              'the overlap is documented, parameterised and enforced '
              'everywhere; without this guard the one path that defeats it '
              'is rotation itself',
        );
      });
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

    test(
      'two-key admission costs about two X25519 operations — measured as '
      'the extra cost of the second key trial, priced against a keygen on '
      'the same host, so load cancels instead of failing a fixed budget',
      () async {
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

          // An absolute microsecond budget measures this machine as much as
          // the code. Best-of-N absolute rounds was the previous answer and
          // it still failed at load average ~15, because at that load every
          // round is disturbed — there is no quiet round left to pick. What
          // this test actually claims is PROPORTIONALITY: admission costs
          // about two X25519 operations. So time one X25519 operation (an
          // ephemeral keygen — the same Montgomery ladder, same backend) in
          // the same process, interleaved round by round, and assert the
          // ratio. Host load stretches numerator and denominator together
          // and cancels; a code regression multiplies only the numerator,
          // in every round at once. The 2 ms budget itself is still unmet
          // on the pure-Dart backend (~1876 us/op per tool/bench_x25519.dart;
          // meeting it needs a native X25519) — that absolute question
          // belongs to the bench, not to this test.
          // A hello built for the CURRENT key matches on the first trial;
          // the previous-key hello above needs two. That pair is what makes
          // the trial count directly observable below.
          final helloCurrent = TlsClientHello.parseRecord(
            await _hello(
              relayPublicKey: ring.current.publicKey,
              timeSlot: auth.currentTimeSlot,
            ),
          );
          // STRUCTURE is read, not timed. The admission result reports the
          // exact number of key trials (EpochAdmission.keysTried,
          // relay_key_rotation.dart:360, set from the trial-loop counter at
          // :435/:444). A broken short-circuit or an extra trial fails
          // these deterministically — no band, no noise, no load
          // sensitivity. Timing statistics for these classes were an
          // estimate of a count from a duration; this is the count.
          final oneKeyAdmission = await RotatingRealityAuthenticator(
            ring: ring,
          ).inspect(helloCurrent);
          final twoKeyAdmission = await RotatingRealityAuthenticator(
            ring: ring,
          ).inspect(hello);
          expect(
            oneKeyAdmission.keysTried,
            1,
            reason:
                'a hello for the current key must match on the first '
                'trial; more means the short-circuit is broken',
          );
          expect(
            twoKeyAdmission.keysTried,
            2,
            reason:
                'a hello for the previous key must match on exactly '
                'the second trial; more means a third key is being tried',
          );
          const iterations = 40; // two-key admissions per round
          // K is a denominator: keep its phase long enough that one
          // scheduler hiccup moves it by no more than ~2%.
          const referenceOps = 20; // X25519 keygens per round
          const rounds = 6;
          // Warm both timed paths so neither pays JIT compilation alone in
          // the first round (the keysTried calls above warmed admission).
          for (var i = 0; i < 3; i++) {
            await RotatingRealityAuthenticator(ring: ring).inspect(hello);
            await _agreement.generateEphemeral();
          }
          // MAGNITUDE is the one thing a counter cannot report, so one
          // timing corridor remains: total two-key admission cost priced in
          // fixed-base X25519 keygens timed in the same process, phase
          // against phase inside each round, so host load stretches both
          // and cancels. A same-phase ratio, not a difference: differences
          // of two timed phases carry inter-phase scheduling noise that
          // iterations cannot average away (measured: difference spreads
          // 1.27-1.30x against 1.10x for this ratio), and with keysTried
          // guarding structure there is no fixed cost left to cancel.
          // Composition, from relay_key_rotation.dart:386-446: per trial
          // one sharedSecret (variable-base X25519), one HKDF credential
          // derivation, one constant-time compare; outside the loop only
          // cheap parsing and one verifyWith on the matching key — so this
          // corridor also catches cost quietly added OUTSIDE the trial
          // loop, which a trial-only statistic cancels by construction.
          // AUTHORITY for the healthy centre is this test's own paired
          // statistic: ~4.4-4.6 keygens per two-key admission (measured
          // 2026-08-18, two sessions, load averages 7.8 and 34-45; best
          // pair 4888.8us/1063.8us = 4.60). The standalone bench
          // (tool/bench_x25519.dart: sharedSecret 4018us, HKDF 174us,
          // keygen 1538us -> 2*(4018+174)/1538 = 5.45) corroborates the
          // order and is NOT the anchor: it disagrees with the paired
          // in-process keygen by 31% because it ran unpaired under
          // different load — which is the whole reason absolute
          // microseconds are banned from these assertions.
          // Bound placement rule: arithmetic midpoint between the measured
          // healthy state and the failure state the bound detects. Healthy
          // ~4.5; doubled per-trial work ~9.0 -> upper 6.75; agreement
          // skipped inside the loop ~0.3 -> lower 2.4 (the algebraic floor
          // — two variable-base ops cannot undercut two fixed-base keygens,
          // 2.0 — sits beneath it as sanity). If round spread approaches
          // half a healthy-to-failure separation, fix the instrument;
          // never move a bound to fit a reading.
          // HONESTY — what this pair cannot see: (1) a uniform slowdown of
          // the crypto backend itself, since numerator and denominator
          // scale together — absolutes belong to the bench; (2) cost
          // changes smaller than ~50%, the midpoint margin; (3) a
          // keysTried counter that misreports — the corridor only catches
          // a lying counter once the hidden work approaches a full trial.
          // Timing noise here is ONE-SIDED: the scheduler can add time to a
          // sample, never remove it. So each operation's true cost is
          // estimated by the MINIMUM over individually timed samples — it
          // converges to the truth from above and needs only one clean
          // window per term anywhere in the run — and the asserted
          // statistic is the ratio of the two minima. CALIBRATION, measured
          // 2026-08-19 on this machine: 4.22 unloaded, then 4.18 / 4.20 /
          // 4.21 with every core saturated by synthetic load — a spread of
          // 1.007x. In those same four runs the per-round PHASE ratios
          // ranged 1.30 to 8.44, a spread of 6.5x, because a stall landing
          // inside one phase cannot be cancelled by the other phase no
          // matter how closely the two are timed. Round ratios stay below
          // as DIAGNOSTICS and are deliberately not asserted: an earlier
          // version asserted them and a healthy round of 1.30 would have
          // turned it red.
          // Why per-operation minima rather than per-phase: the recorded
          // failure this test was rebuilt from measured 13545.1 us against
          // a 12000 us bound (suite run 20260818T192227Z) — that was the
          // MINIMUM of five 40-iteration phase averages, inflated 2.46x
          // over the ~5500 us healthy cost. A clean 4.6 ms window is far
          // easier to catch than a clean 184 ms one.
          final roundRatios = <double>[]; // diagnostics only, never asserted
          var perDecision = double.infinity; // cleanest single admission, us
          var perKeygen = double.infinity; // cleanest single keygen, us
          for (var round = 0; round < rounds; round++) {
            var keygenPhaseUs = 0;
            for (var i = 0; i < referenceOps; i++) {
              final w = Stopwatch()..start();
              await _agreement.generateEphemeral();
              w.stop();
              keygenPhaseUs += w.elapsedMicroseconds;
              if (w.elapsedMicroseconds < perKeygen) {
                perKeygen = w.elapsedMicroseconds.toDouble();
              }
            }
            var admissionPhaseUs = 0;
            for (var i = 0; i < iterations; i++) {
              final w = Stopwatch()..start();
              await RotatingRealityAuthenticator(ring: ring).inspect(hello);
              w.stop();
              admissionPhaseUs += w.elapsedMicroseconds;
              if (w.elapsedMicroseconds < perDecision) {
                perDecision = w.elapsedMicroseconds.toDouble();
              }
            }
            roundRatios.add(
              (admissionPhaseUs / iterations) / (keygenPhaseUs / referenceOps),
            );
          }
          final admissionPerKeygen = perDecision / perKeygen;
          final minRound = roundRatios.reduce((a, b) => a < b ? a : b);
          final maxRound = roundRatios.reduce((a, b) => a > b ? a : b);
          // ignore: avoid_print
          print(
            'EVIDENCE relay_admission '
            'oneKeyTried=${oneKeyAdmission.keysTried} '
            'twoKeyTried=${twoKeyAdmission.keysTried} '
            'perDecision=${perDecision.toStringAsFixed(1)}us '
            'perX25519=${perKeygen.toStringAsFixed(1)}us '
            'admissionPerKeygen=${admissionPerKeygen.toStringAsFixed(2)} '
            'roundRatios='
            '${roundRatios.map((v) => v.toStringAsFixed(2)).join(',')} '
            'condition='
            '${maxRound / minRound > 1.25 ? 'noisy-host' : 'quiet-host'}',
          );
          // Bound placement rule: each bound sits at the arithmetic midpoint
          // between the measured healthy state and the failure state it
          // detects, so a future reader can re-derive it from two numbers
          // instead of trusting one.
          //   healthy            4.20   measured, four runs, loaded and not
          //   doubled crypto     8.69   MEASURED, not assumed: a second
          //                             inspect() injected into the timed
          //                             sample (scratch harness, 2026-08-19)
          //   -> upper bound     6.45   (4.20 + 8.69) / 2
          //   skipped agreement  ~0.3   ESTIMATED, not measured: a per-trial
          //                             compare with no scalar multiply
          //   -> lower bound     2.25   (4.20 + 0.3) / 2
          // Re-deriving a bound from a better-calibrated centre is instrument
          // repair and is allowed. Moving a bound to fit a failing reading is
          // banned. If the round-to-round spread of the ASSERTED statistic
          // ever approaches half the healthy-to-failure separation, the
          // instrument is broken and gets finer sampling — not a wider bound.
          // (Two earlier versions of this test placed bounds from an
          // unanchored bench figure and from a statistic whose healthy value
          // sat on its own algebraic ceiling; both landed within noise of a
          // healthy reading. That is the mistake this rule exists to prevent.)
          expect(
            admissionPerKeygen,
            lessThan(6.45),
            reason:
                'cleanest admission priced in cleanest keygens: at or '
                'above the midpoint to measured doubled work (8.69), '
                'admission is doing roughly twice the crypto its two '
                'trials cost — inside the trial loop or added outside it',
          );
          expect(
            admissionPerKeygen,
            greaterThan(2.25),
            reason:
                'keysTried counts loop passes even when the crypto '
                'inside them is gone; below the midpoint to the '
                'skipped-agreement state (~0.3), the trials are no longer '
                'paying for real agreements',
          );
        });
      },
    );
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
