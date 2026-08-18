/// Batching: the contract, and the two numbers that decide whether it was
/// worth doing.
///
/// The estimate that justified this change was "about x1.2 at N=10". An
/// estimate is not a result, and the cost side — batching turns independent
/// symbol loss into burst loss — was explicitly deferred to measurement rather
/// than assumed away. Both are measured here, and both print their numbers.
@TestOn('vm')
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:test/test.dart';

const int _blockSize = 55; // the mandated size; datagrams are 60 B

List<Uint8List> _symbols(int n, {int seed = 1}) {
  final encoder = RlncEncoder(
    Uint8List.fromList(List.generate(4000, (i) => ((i + seed) * 31) & 0xFF)),
    blockSize: _blockSize,
  );
  return List.generate(n, encoder.datagramAt);
}

void main() {
  group('frame contract', () {
    test('round-trips the whole address, including the media type', () {
      // The type is the point: it did not travel at all before, so the
      // receiver invented the value that decides how an object renders.
      for (final type in MediaType.values) {
        final syms = _symbols(7);
        final frame = CliffFreeBatchCodec.encode(
          objectId: 4242,
          type: type,
          layerCount: 30,
          layerIndex: 29,
          symbols: syms,
        );
        final batch = CliffFreeBatchCodec.decode(frame);

        expect(batch.objectId, 4242);
        expect(batch.type, type);
        expect(batch.layerCount, 30);
        expect(batch.layerIndex, 29);
        expect(batch.symbols.length, 7);
        for (var i = 0; i < syms.length; i++) {
          expect(batch.symbols[i], syms[i], reason: 'symbol $i');
        }
      }
    });

    test('a 30-layer object at a high objectId now survives MediaCarriage', () {
      // This is the defect from Run I-2, inverted into a contract. The old
      // scheme packed the layer address into a 32-bit transfer id that
      // `MediaCarriage.wrap` rejected on the second object ever sent. With the
      // address in the frame, the carriage id carries only objectId — and a
      // u16 objectId is exactly what a 16-bit field holds.
      final frame = CliffFreeBatchCodec.encode(
        objectId: 0xFFFF,
        type: MediaType.flipbook,
        layerCount: 30,
        layerIndex: 17,
        symbols: _symbols(10),
      );

      for (final carrier in MediaCarrier.values) {
        final carriage = MediaCarriage(carrier: carrier);
        final wire = carriage.wrap(TaggedDatagram(0xFFFF, frame));
        final back = carriage.unwrap(wire);
        expect(back.transferId, 0xFFFF);

        final batch = CliffFreeBatchCodec.decode(back.bytes);
        expect(batch.objectId, 0xFFFF);
        expect(batch.layerIndex, 17);
        expect(batch.layerCount, 30);
        expect(batch.type, MediaType.flipbook);
      }
    });

    test('every malformed header is NAMED, not silently dropped', () {
      final good = CliffFreeBatchCodec.encode(
        objectId: 1,
        type: MediaType.photo,
        layerCount: 4,
        layerIndex: 1,
        symbols: _symbols(3),
      );

      CliffFreeBatchError errorOf(Uint8List f) {
        try {
          CliffFreeBatchCodec.decode(f);
        } on CliffFreeBatchException catch (e) {
          return e.error;
        }
        fail('expected a rejection');
      }

      // Not ours at all.
      expect(errorOf(Uint8List.fromList([1, 2, 3])),
          CliffFreeBatchError.notABatch);
      final wrongMagic = Uint8List.fromList(good)..[0] = 0x00;
      expect(errorOf(wrongMagic), CliffFreeBatchError.notABatch);

      // Ours, and from the future.
      final wrongVersion = Uint8List.fromList(good)..[1] = 9;
      expect(errorOf(wrongVersion), CliffFreeBatchError.unsupportedVersion);

      // Ours, and lying about its own size — the remotely-triggerable one.
      final truncated = Uint8List.sublistView(good, 0, good.length - 10);
      expect(errorOf(Uint8List.fromList(truncated)),
          CliffFreeBatchError.lengthMismatch);

      // A media type index past the end of the enum used to throw RangeError
      // out of a receive path from a value an attacker chooses.
      final badType = Uint8List.fromList(good)..[4] = 200;
      expect(errorOf(badType), CliffFreeBatchError.malformedHeader);

      final badLayer = Uint8List.fromList(good)..[6] = 9; // >= layerCount 4
      expect(errorOf(badLayer), CliffFreeBatchError.malformedHeader);

      final zeroSymbols = Uint8List.fromList(good)..[7] = 0;
      expect(errorOf(zeroSymbols), CliffFreeBatchError.malformedHeader);

      final badSize = Uint8List.fromList(good)..[8] = 200;
      expect(errorOf(badSize), CliffFreeBatchError.malformedHeader);
    });

    test('tryDecode separates "not ours" from "ours and broken"', () {
      expect(CliffFreeBatchCodec.tryDecode(Uint8List.fromList([1, 2, 3])),
          isNull);
      final good = CliffFreeBatchCodec.encode(
        objectId: 1,
        type: MediaType.photo,
        layerCount: 2,
        layerIndex: 0,
        symbols: _symbols(2),
      );
      // Claims our magic, then lies. That is not someone else's traffic.
      final lying = Uint8List.fromList(good)..[7] = 200;
      expect(
        () => CliffFreeBatchCodec.tryDecode(lying),
        throwsA(isA<CliffFreeBatchException>()),
      );
    });

    test('a ragged batch is refused rather than padded', () {
      final syms = _symbols(3);
      expect(
        () => CliffFreeBatchCodec.encode(
          objectId: 1,
          type: MediaType.photo,
          layerCount: 1,
          layerIndex: 0,
          symbols: [syms[0], Uint8List(40), syms[2]],
        ),
        throwsA(isA<ArgumentError>()),
        reason: 'padding a short symbol makes a CRC failure look like the link',
      );
    });
  });

  group('CliffFreeBatcher', () {
    test('flushes on a layer change and loses nothing at the boundary', () {
      final batcher = CliffFreeBatcher(
        objectId: 3,
        type: MediaType.photo,
        layerCount: 3,
        maxSymbolsPerFrame: 4,
      );
      final syms = _symbols(12);
      final frames = <Uint8List>[];

      for (var i = 0; i < 3; i++) {
        final f = batcher.add(0, syms[i]);
        if (f != null) frames.add(f);
      }
      // Layer changes with three symbols pending: they must be emitted, not
      // discarded and not merged into the next layer's frame.
      for (var i = 3; i < 9; i++) {
        final f = batcher.add(1, syms[i]);
        if (f != null) frames.add(f);
      }
      final tail = batcher.flush();
      if (tail != null) frames.add(tail);

      var total = 0;
      for (final f in frames) {
        final b = CliffFreeBatchCodec.decode(f);
        total += b.symbols.length;
      }
      expect(total, 9, reason: 'every symbol offered must appear in a frame');
      expect(batcher.pendingSymbols, 0);

      final layers = frames
          .map((f) => CliffFreeBatchCodec.decode(f).layerIndex)
          .toList();
      expect(layers.first, 0);
      expect(layers.last, 1);
    });

    test('an address change AND a full batch in one call loses neither frame',
        () {
      // The ordering trap: `add` can trigger a flush for the layer change and
      // then find the batch full. Overwriting the first frame with the second
      // drops real symbols on the floor.
      final batcher = CliffFreeBatcher(
        objectId: 1,
        type: MediaType.photo,
        layerCount: 2,
        maxSymbolsPerFrame: 1, // every add both changes and fills
      );
      final syms = _symbols(4);
      final frames = <Uint8List>[];
      for (var i = 0; i < 4; i++) {
        final f = batcher.add(i.isEven ? 0 : 1, syms[i]);
        if (f != null) frames.add(f);
      }
      final tail = batcher.flush();
      if (tail != null) frames.add(tail);

      var total = 0;
      for (final f in frames) {
        total += CliffFreeBatchCodec.decode(f).symbols.length;
      }
      expect(total, 4);
    });
  });

  group('MEASURED: what batching buys', () {
    test('wire bytes per source byte, by batch size', () {
      // The number the whole change exists for. Printed as a table because a
      // single figure hides where the curve flattens, and the default batch
      // size should come from the table rather than from a preference.
      final carriage = MediaCarriage(carrier: MediaCarrier.sctpDataChannel);
      const trials = 120;

      for (final n in [1, 2, 5, 10, 20, 40, 80]) {
        var wire = 0;
        var source = 0;
        for (var t = 0; t < trials; t++) {
          final syms = _symbols(n, seed: t);
          final frame = CliffFreeBatchCodec.encode(
            objectId: 1,
            type: MediaType.photo,
            layerCount: 1,
            layerIndex: 0,
            symbols: syms,
          );
          wire += carriage.wrap(TaggedDatagram(1, frame)).length;
          source += n * 60;
        }
        // ignore: avoid_print
        print(
          'batch N=${n.toString().padLeft(2)}: '
          '${(wire / source).toStringAsFixed(2)}x wire/source  '
          '(${(wire / trials).round()} B per frame carrying ${n * 60} B)',
        );
      }

      // The assertion is the claim that justified the change, and nothing
      // more: batching must actually amortize. The exact figure is the
      // printed table's job.
      double factor(int n) {
        var wire = 0;
        for (var t = 0; t < trials; t++) {
          final frame = CliffFreeBatchCodec.encode(
            objectId: 1,
            type: MediaType.photo,
            layerCount: 1,
            layerIndex: 0,
            symbols: _symbols(n, seed: t),
          );
          wire += carriage.wrap(TaggedDatagram(1, frame)).length;
        }
        return wire / (trials * n * 60);
      }

      final one = factor(1);
      final ten = factor(10);
      expect(ten, lessThan(one / 2),
          reason: 'N=10 must at least halve the expansion of N=1');
      expect(one, greaterThan(2.0),
          reason: 'the unbatched cost measured in Run I was x3.6');
    });

    test('MEASURED COST: burst loss from batching, at equal byte loss', () {
      // The cost the chosen approach explicitly required measuring rather than
      // assuming. Same object, same total fraction of bytes lost, delivered
      // two ways: independent per-symbol drops, and whole-frame drops.
      //
      // Rateless coding does not care WHICH symbols arrive, only how many, so
      // the first-order prediction is that these are equal. The second-order
      // effect is variance: a whole-frame drop removes N symbols at once, so
      // the delivered count is lumpier and a marginal transfer fails more
      // often even when the mean is identical.
      final rng = Random(20260804);
      const object = 3000; // bytes
      const trials = 400;

      double successRate({required int batchSize, required double loss}) {
        var ok = 0;
        for (var t = 0; t < trials; t++) {
          final encoder = RlncEncoder(
            Uint8List.fromList(
              List.generate(object, (i) => ((i + t) * 17) & 0xFF),
            ),
            blockSize: _blockSize,
          );
          // Send enough symbols that a clean link decodes comfortably, and let
          // loss do the deciding.
          final need = encoder.blockCount;
          final sent = (need * 1.6).ceil();

          final decoder = RlncDecoder();
          var i = 0;
          while (i < sent) {
            final take = batchSize > sent - i ? sent - i : batchSize;
            final dropWholeFrame = batchSize > 1 && rng.nextDouble() < loss;
            for (var k = 0; k < take; k++) {
              final drop =
                  batchSize > 1 ? dropWholeFrame : rng.nextDouble() < loss;
              if (!drop) decoder.addDatagram(encoder.datagramAt(i + k));
            }
            i += take;
          }
          if (decoder.isComplete) ok++;
        }
        return ok / trials;
      }

      for (final loss in [0.1, 0.2, 0.3]) {
        final single = successRate(batchSize: 1, loss: loss);
        final batched = successRate(batchSize: 10, loss: loss);
        // ignore: avoid_print
        print(
          'loss ${(loss * 100).round()}%: decode success — '
          'per-symbol ${(single * 100).toStringAsFixed(1)}% · '
          'batched N=10 ${(batched * 100).toStringAsFixed(1)}% '
          '(delta ${((batched - single) * 100).toStringAsFixed(1)} pt)',
        );
      }

      // What must hold for the trade to be acceptable at the redundancy this
      // project actually plans for (1.2/(1-p), so 1.6x covers 25% loss): at
      // 10% loss, batching must not collapse the transfer. A weak bar on
      // purpose — the printed deltas are the result, and a bar tight enough to
      // encode today's numbers would fail on a future allocator change for
      // reasons unrelated to batching.
      expect(successRate(batchSize: 10, loss: 0.1), greaterThan(0.8));
    });

    test('MEASURED: the batch size that minimises wire bytes per SUCCESS', () {
      // The two effects above pull in opposite directions, and neither table
      // alone chooses a batch size. One metric contains both: the wire bytes
      // actually spent per object DELIVERED. Bytes that go out and fail to
      // decode are not cheaper for having been cheap.
      //
      //   E[wire bytes per success] = bytes sent on the wire / success rate
      //
      // The N that minimises it at each loss level IS the policy, and it is
      // read off this table rather than chosen.
      final carriage = MediaCarriage(carrier: MediaCarrier.sctpDataChannel);
      const object = 3000;
      const trials = 150;
      const candidates = [1, 2, 4, 10, 20, 40, 80];

      ({double wire, double success}) run(int batchSize, double loss, int seed) {
        final rng = Random(seed);
        var ok = 0;
        var wireTotal = 0;
        for (var t = 0; t < trials; t++) {
          final encoder = RlncEncoder(
            Uint8List.fromList(
              List.generate(object, (i) => ((i + t) * 17) & 0xFF),
            ),
            blockSize: _blockSize,
          );
          // Redundancy follows the MEASURED LAW (F-3: 1.2/(1-p)) rather than a
          // fixed 1.6x. A fixed factor under-provisions every high-loss row
          // equally, which makes those rows a comparison between different
          // ways of failing rather than between batch sizes.
          final sent = (encoder.blockCount * 1.2 / (1 - loss)).ceil();
          final decoder = RlncDecoder();
          var i = 0;
          while (i < sent) {
            final take = batchSize > sent - i ? sent - i : batchSize;
            final syms = [
              for (var k = 0; k < take; k++) encoder.datagramAt(i + k),
            ];
            final frame = CliffFreeBatchCodec.encode(
              objectId: 1,
              type: MediaType.photo,
              layerCount: 1,
              layerIndex: 0,
              symbols: syms,
            );
            // Every frame is paid for whether or not it lands.
            wireTotal += carriage.wrap(TaggedDatagram(1, frame)).length;
            if (rng.nextDouble() >= loss) {
              for (final s in syms) {
                decoder.addDatagram(s);
              }
            }
            i += take;
          }
          if (decoder.isComplete) ok++;
        }
        return (wire: wireTotal / trials, success: ok / trials);
      }

      // ignore: avoid_print
      print('');
      // ignore: avoid_print
      print('wire bytes per SUCCESSFUL 3000 B object (lower is better):');
      // ignore: avoid_print
      print('  loss |' +
          candidates.map((n) => 'N=$n'.padLeft(9)).join() +
          '   best');

      final best = <double, int>{};
      for (final loss in [0.05, 0.1, 0.2, 0.3, 0.4]) {
        final row = <int, double>{};
        for (final n in candidates) {
          final r = run(n, loss, 900 + n);
          // A success rate of zero is an infinite cost, not a small one.
          row[n] = r.success == 0 ? double.infinity : r.wire / r.success;
        }
        var bestN = candidates.first;
        for (final n in candidates) {
          if (row[n]! < row[bestN]!) bestN = n;
        }
        best[loss] = bestN;
        // ignore: avoid_print
        print('  ${(loss * 100).round().toString().padLeft(4)}% |' +
            candidates
                .map((n) => (row[n]!.isFinite
                        ? row[n]!.round().toString()
                        : 'fail')
                    .padLeft(9))
                .join() +
            '   N=$bestN');
      }

      // WHAT THIS TABLE OVERTURNED. The first policy written against it was a
      // ladder that SHRANK the batch as loss rose, on the reasoning that burst
      // loss is worse on a bad link. The measurement says the opposite at every
      // level: the pad on a small batch (x3.85) costs more than the bursts ever
      // do, so bytes-per-success falls monotonically with N right through 40%
      // loss. The intuition was backwards and the table is what caught it.
      //
      // So loss does NOT bound the batch size. What bounds it is asserted
      // separately below, and it is time, not bytes.
      for (final entry in best.entries) {
        expect(
          entry.value,
          greaterThanOrEqualTo(10),
          reason: 'at ${entry.key} loss the cheapest batch was ${entry.value}; '
              'if this ever drops below 10 the padding constant has changed '
              'and the policy must be re-derived',
        );
      }
    });

    test('MEASURED: the binding constraint is TIME, not loss', () {
      // Since bytes-per-success only improves with N, something else has to
      // stop it, and on this project that something is the promise the
      // cliff-free path exists to keep: the base layer renders EARLY. A frame
      // is atomic on the wire, so nothing inside it can be decoded until all
      // of it has arrived. On a slow link a large frame is simply a delay.
      //
      // The `narrow` profile is 16 Kbit/s = 2,000 B/s. That is the number that
      // decides the batch size, and it is measured here rather than assumed.
      const bytesPerSecondNarrow = 2000.0;
      const bytesPerSecondBandwidth = 4000.0; // the 32 Kbit/s profile

      // ignore: avoid_print
      print('');
      // ignore: avoid_print
      print('time to put ONE frame on the wire (frame is atomic to decode):');
      for (final n in [2, 4, 10, 20, 40, 80]) {
        final frame = CliffFreeBatchCodec.encode(
          objectId: 1,
          type: MediaType.photo,
          layerCount: 1,
          layerIndex: 0,
          symbols: _symbols(n),
        );
        final wire =
            MediaCarriage(carrier: MediaCarrier.sctpDataChannel)
                .wrap(TaggedDatagram(1, frame))
                .length;
        // ignore: avoid_print
        print(
          '  N=${n.toString().padLeft(2)}: $wire B  ->  '
          '${(wire / bytesPerSecondNarrow).toStringAsFixed(2)} s at 16 Kbit/s · '
          '${(wire / bytesPerSecondBandwidth).toStringAsFixed(2)} s at 32 Kbit/s',
        );
      }

      // The contract: on the narrowest profile the project measures against,
      // one frame must not hold the link longer than the head budget. 0.5 s is
      // the figure CFV §15 uses for "first visual"; a frame that takes longer
      // than that has spent the whole budget before anything can be decoded.
      final chosen = CliffFreeBatcher.batchSizeForLinkRate(
        bytesPerSecond: bytesPerSecondNarrow,
      );
      final frame = CliffFreeBatchCodec.encode(
        objectId: 1,
        type: MediaType.photo,
        layerCount: 1,
        layerIndex: 0,
        symbols: _symbols(chosen),
      );
      final wire = MediaCarriage(carrier: MediaCarrier.sctpDataChannel)
          .wrap(TaggedDatagram(1, frame))
          .length;
      expect(
        wire / bytesPerSecondNarrow,
        lessThanOrEqualTo(0.5),
        reason: 'N=$chosen holds the narrow link too long to render early',
      );

      // And the shape: a faster link affords a bigger frame in the same time.
      expect(
        CliffFreeBatcher.batchSizeForLinkRate(bytesPerSecond: 200000),
        greaterThan(
          CliffFreeBatcher.batchSizeForLinkRate(
            bytesPerSecond: bytesPerSecondNarrow,
          ),
        ),
      );

      // An unusable rate takes the conservative end, on the same principle as
      // everywhere else in this codebase: no estimate is not evidence of a
      // fast link.
      expect(
        CliffFreeBatcher.batchSizeForLinkRate(bytesPerSecond: double.nan),
        lessThanOrEqualTo(
          CliffFreeBatcher.batchSizeForLinkRate(bytesPerSecond: 200000),
        ),
      );
      expect(
        CliffFreeBatcher.batchSizeForLinkRate(bytesPerSecond: 0),
        greaterThanOrEqualTo(1),
        reason: 'a zero rate must not produce a zero-symbol batch',
      );
    });
  });
}
