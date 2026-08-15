import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

/// Ticket 1 gate 1d — the independent scheduler.
///
/// The emitter runs its own clock instead of following the application's.
/// The property under test is that an observer of the emitted stream cannot
/// tell a tick where the caller had something to send from one where it did
/// not: same shaping path, same length distribution, same cadence.
void main() {
  TrafficShaper shaperWithSeed(int seed) => TrafficShaper(
    policy: TrafficShapingPolicy.voice,
    random: Random(seed),
    allowInsecureRandom: true,
  );

  group('FixedTickEmitter', () {
    test('the mode is a required named choice, not an absent argument', () {
      // Both states exist by name, so either can be grepped for and neither
      // can be reached by forgetting to pass an argument.
      expect(TickEmissionMode.values, hasLength(2));
      expect(TickEmissionMode.values, contains(TickEmissionMode.off));
      expect(TickEmissionMode.values, contains(TickEmissionMode.fixedTick));
    });

    test('off emits nothing at all', () async {
      var pulls = 0;
      final emitter = FixedTickEmitter(
        mode: TickEmissionMode.off,
        tick: const Duration(milliseconds: 20),
        shaper: shaperWithSeed(1),
        nextFrame: () {
          pulls++;
          return <int>[1, 2, 3];
        },
        delay: (_) async {},
      );
      final emitted = await emitter.run().toList();
      expect(emitted, isEmpty);
      expect(pulls, 0, reason: 'off must not even ask the caller for a frame');
      expect(emitter.framesEmitted, 0);
    });

    test('a non-positive tick is refused', () {
      for (final bad in [Duration.zero, const Duration(milliseconds: -1)]) {
        expect(
          () => FixedTickEmitter(
            mode: TickEmissionMode.fixedTick,
            tick: bad,
            shaper: shaperWithSeed(1),
            nextFrame: () => null,
          ),
          throwsArgumentError,
        );
      }
    });

    test(
      'an empty queue still emits: the output rate is the tick, not the '
      'application rate',
      () {
        final emitter = FixedTickEmitter(
          mode: TickEmissionMode.fixedTick,
          tick: const Duration(milliseconds: 20),
          shaper: shaperWithSeed(7),
          nextFrame: () => null, // the caller never has anything
          delay: (_) async {},
        );
        for (var i = 0; i < 50; i++) {
          expect(emitter.emitOnce(), isNotEmpty);
        }
        expect(emitter.fillerFramesEmitted, 50);
        expect(emitter.realFramesEmitted, 0);
      },
    );

    test('a filler frame is identified and refuses to yield a payload', () {
      final shaper = shaperWithSeed(3);
      final emitter = FixedTickEmitter(
        mode: TickEmissionMode.fixedTick,
        tick: const Duration(milliseconds: 20),
        shaper: shaper,
        nextFrame: () => null,
        delay: (_) async {},
      );
      final unshaped = TrafficShaper.unshape(emitter.emitOnce());
      expect(FixedTickEmitter.isFiller(unshaped), isTrue);
      expect(
        () => FixedTickEmitter.unwrap(unshaped),
        throwsFormatException,
        reason: 'returning empty bytes would let a filler reach the '
            'application instead of being dropped',
      );
    });

    test('a real frame round-trips through shape, unshape and unwrap', () {
      final payload = List<int>.generate(37, (i) => i * 3 % 251);
      final emitter = FixedTickEmitter(
        mode: TickEmissionMode.fixedTick,
        tick: const Duration(milliseconds: 20),
        shaper: shaperWithSeed(11),
        nextFrame: () => payload,
        delay: (_) async {},
      );
      final unshaped = TrafficShaper.unshape(emitter.emitOnce());
      expect(FixedTickEmitter.isFiller(unshaped), isFalse);
      expect(FixedTickEmitter.unwrap(unshaped), payload);
    });

    test(
      'both kinds draw their length from the same distribution, so the two '
      'are not separable by size',
      () {
        // Same seed for both runs: identical draws, so any length difference
        // could only come from the frame kind itself.
        Uint8List first(bool real) {
          final emitter = FixedTickEmitter(
            mode: TickEmissionMode.fixedTick,
            tick: const Duration(milliseconds: 20),
            shaper: shaperWithSeed(42),
            nextFrame: () => real ? <int>[9] : null,
            delay: (_) async {},
          );
          return emitter.emitOnce();
        }

        // A real frame carrying one payload byte and a filler frame carry the
        // same discriminator overhead, so at equal payload the wire lengths
        // differ by exactly that one byte and nothing else.
        expect(first(true).length - first(false).length, 1);
      },
    );

    test('counters separate the two kinds, which is what a shadow run reads',
        () {
      var queued = 3;
      final emitter = FixedTickEmitter(
        mode: TickEmissionMode.fixedTick,
        tick: const Duration(milliseconds: 20),
        shaper: shaperWithSeed(5),
        nextFrame: () => queued-- > 0 ? <int>[1] : null,
        delay: (_) async {},
      );
      for (var i = 0; i < 10; i++) {
        emitter.emitOnce();
      }
      expect(emitter.realFramesEmitted, 3);
      expect(emitter.fillerFramesEmitted, 7);
      expect(emitter.framesEmitted, 10);
    });

    test('run emits one frame per tick and stops on request', () async {
      var ticks = 0;
      final emitter = FixedTickEmitter(
        mode: TickEmissionMode.fixedTick,
        tick: const Duration(milliseconds: 20),
        shaper: shaperWithSeed(13),
        nextFrame: () => null,
        delay: (d) async {
          expect(d, const Duration(milliseconds: 20));
          ticks++;
        },
      );
      final seen = <Uint8List>[];
      final sub = emitter.run().listen((f) {
        seen.add(f);
        if (seen.length == 5) emitter.stop();
      });
      await sub.asFuture<void>();
      expect(seen, hasLength(5));
      expect(ticks, greaterThanOrEqualTo(5));
      expect(emitter.isRunning, isFalse);
    });

    test('an unknown discriminator is refused rather than guessed', () {
      expect(
        () => FixedTickEmitter.unwrap(Uint8List.fromList([0x7F, 1, 2])),
        throwsFormatException,
      );
      expect(
        () => FixedTickEmitter.unwrap(Uint8List(0)),
        throwsFormatException,
      );
    });
  });
}
