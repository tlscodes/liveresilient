import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:hamseda_codec/hamseda_codec.dart';
import 'package:test/test.dart';

List<List<int>> speechLike(int frames, int nRows, int seed) {
  // Speech-like stream: a small recurring sound alphabet plus novelty,
  // mirroring the real EnCodec column statistics (many repeats).
  final rng = Random(seed);
  final alphabet = [
    for (var i = 0; i < 40; i++)
      [for (var r = 0; r < nRows; r++) rng.nextInt(rawSymbols)]
  ];
  return [
    for (var i = 0; i < frames; i++)
      rng.nextDouble() < 0.7
          ? List.of(alphabet[rng.nextInt(alphabet.length)])
          : [for (var r = 0; r < nRows; r++) rng.nextInt(rawSymbols)]
  ];
}

void main() {
  group('bit-exact roundtrip', () {
    test('encode/decode reproduces the exact column stream', () {
      final cols = speechLike(400, 2, 1);
      final enc = HamsedaState(2);
      final dec = HamsedaState(2);
      final data = encodeColumns(cols, enc);
      expect(decodeColumns(data, cols.length, dec), equals(cols));
    });

    test('cold call is capped at raw+1 byte; warm call compresses hard', () {
      final cols = speechLike(1000, 2, 2);
      final rawBits = 1000 * 2 * 10;
      final st = HamsedaState(2);
      final cold = encodeColumns(cols, st);
      // v4 contract: a cold call may not beat raw, but can NEVER cost
      // more than raw plus the 1-byte path flag.
      expect(cold.length * 8, lessThanOrEqualTo(rawBits + 8));
      final warm = encodeColumns(cols, st);
      expect(warm.length * 8, lessThan(rawBits ~/ 4),
          reason: 'converged dictionary must crush repeated speech');
    });

    test('single frame and empty stream', () {
      expect(encodeColumns([], HamsedaState(2)), isNotEmpty); // header only
      final one = [
        [7, 900]
      ];
      final data = encodeColumns(one, HamsedaState(2));
      expect(decodeColumns(data, 1, HamsedaState(2)), equals(one));
    });
  });

  group('cross-call persistence', () {
    test('persisted state decodes call 2 and shrinks warm re-encode', () {
      final call1 = speechLike(500, 2, 3);
      final enc = HamsedaState(2);
      final dec = HamsedaState(2);
      final d1 = encodeColumns(call1, enc);
      expect(decodeColumns(d1, call1.length, dec), equals(call1));

      // serialize both ends between calls (JSON persistence)
      final enc2 = HamsedaState.fromJson(
          jsonDecode(jsonEncode(enc.toJson())) as Map<String, dynamic>);
      final dec2 = HamsedaState.fromJson(
          jsonDecode(jsonEncode(dec.toJson())) as Map<String, dynamic>);

      final d2 = encodeColumns(call1, enc2); // same speech, warm dict
      expect(decodeColumns(d2, call1.length, dec2), equals(call1));
      expect(d2.length, lessThan(d1.length ~/ 2),
          reason: 'warm dictionary must at least halve repeated speech');
    });
  });

  group('loss tolerance (ack-gated sessions)', () {
    test('no divergence at 0%/5%/20% block loss', () {
      for (final lossPct in [0, 5, 20]) {
        final rng = Random(42);
        final cols = speechLike(600, 2, 4);
        final sender = HamsedaSession(2);
        final receiver = HamsedaSession(2);
        for (var i = 0; i < cols.length; i += 25) {
          final block = cols.sublist(i, min(i + 25, cols.length));
          final data = sender.encodeBlock(block);
          if (rng.nextInt(100) < lossPct) {
            sender.rollback(); // never acked
            continue;
          }
          final got = receiver.decodeBlock(data, block.length);
          expect(got, equals(block), reason: 'loss=$lossPct% block@$i');
          sender.commit();
          receiver.commit();
        }
        expect(jsonEncode(sender.committed.toJson()),
            equals(jsonEncode(receiver.committed.toJson())),
            reason: 'state diverged at loss=$lossPct%');
      }
    });

    test('re-encoding after rollback matches a never-sent encoding', () {
      final cols = speechLike(100, 2, 5);
      final a = HamsedaSession(2);
      final block = cols.sublist(0, 50);
      a.encodeBlock(block);
      a.rollback();
      final again = a.encodeBlock(block);
      final fresh = HamsedaSession(2).encodeBlock(block);
      expect(again, equals(fresh));
    });
  });

  group('boundaries', () {
    test('wrong column arity throws', () {
      expect(() => encodeColumns([
            [1, 2, 3]
          ], HamsedaState(2)),
          throwsArgumentError);
    });

    test('corrupt input throws or mismatches, never hangs', () {
      final cols = speechLike(200, 2, 6);
      final data = encodeColumns(cols, HamsedaState(2));
      final corrupt = Uint8List.fromList(data);
      corrupt[8] ^= 0xFF;
      List<List<int>>? out;
      try {
        out = decodeColumns(corrupt, cols.length, HamsedaState(2));
      } on StateError {
        out = null; // detected corruption — acceptable
      } on RangeError {
        out = null;
      }
      if (out != null) expect(out, isNot(equals(cols)));
    });

    test('dictionary growth is deterministic across ends', () {
      final cols = speechLike(300, 2, 7);
      final enc = HamsedaState(2);
      final dec = HamsedaState(2);
      final data = encodeColumns(cols, enc);
      decodeColumns(data, cols.length, dec);
      expect(jsonEncode(dec.toJson()), equals(jsonEncode(enc.toJson())));
    });

    test('capped growth: long stream crossing both caps stays bit-exact, '
        'state stops growing, both ends identical', () {
      final oldDict = maxDictEntries;
      final oldCtx2 = maxCtx2Tables;
      maxDictEntries = 200;
      maxCtx2Tables = 300;
      try {
        final cols = speechLike(2500, 2, 99);
        final enc = HamsedaState(2);
        final dec = HamsedaState(2);
        final data = encodeColumns(cols, enc);
        expect(decodeColumns(data, cols.length, dec), equals(cols));
        expect(enc.dict.cols.length, lessThanOrEqualTo(200));
        expect(enc.ctx2.length, lessThanOrEqualTo(300));
        expect(jsonEncode(dec.toJson()), equals(jsonEncode(enc.toJson())));
      } finally {
        maxDictEntries = oldDict;
        maxCtx2Tables = oldCtx2;
      }
    });

    test('frequency halving keeps both ends identical (long stream)', () {
      // enough symbols to cross the 65536 halving threshold repeatedly
      final cols = speechLike(4000, 2, 8);
      final enc = HamsedaState(2);
      final dec = HamsedaState(2);
      final data = encodeColumns(cols, enc);
      expect(decodeColumns(data, cols.length, dec), equals(cols));
      expect(jsonEncode(dec.toJson()), equals(jsonEncode(enc.toJson())));
    });
  });
}
