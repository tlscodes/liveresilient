/// Productized front-ends: exact-inverse proofs on random and
/// structured data, including the inverses the labs did not need
/// (unPaeth, unRowDelta reconstruction-order correctness).
import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/src/media_codecs/media_frontends.dart';
import 'package:test/test.dart';

void main() {
  final rng = Random(77);

  Uint8List randomBytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));

  test('YCoCgR forward/inverse identity, 3 and 4 channels', () {
    for (final ch in [3, 4]) {
      final px = randomBytes(60 * 40 * ch);
      expect(YCoCgR.inverse(YCoCgR.forward(px, ch), ch), equals(px));
    }
  });

  test('Paeth residual inverse reconstructs from residuals alone', () {
    for (final ch in [3, 4]) {
      const w = 50, h = 30;
      final px = randomBytes(w * h * ch);
      final res = SpatialResidual.paeth(px, w, h, ch);
      expect(SpatialResidual.unPaeth(res, w, h, ch), equals(px));
    }
  });

  test('rowDelta inverse identity, structured gradient image', () {
    const w = 64, h = 48, ch = 4;
    final px = Uint8List(w * h * ch);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w * ch; x++) {
        px[y * w * ch + x] = (x + 2 * y) & 0xFF; // smooth gradient
      }
    }
    final res = SpatialResidual.rowDelta(px, w, h, ch);
    expect(SpatialResidual.unRowDelta(res, w, h, ch), equals(px));
  });

  test('QuantizedLpc bit-exact on sine, speech-like, random, edges', () {
    final cases = <Uint8List>[
      Uint8List(0),
      Uint8List.fromList([7]), // odd length
      randomBytes(2 * 4096 + 3),
      // sine-like strongly predictable signal
      (() {
        final s = Int16List(9000);
        for (var i = 0; i < s.length; i++) {
          s[i] =
              (12000 * (i % 200 < 100 ? (i % 100) / 100 : 1 - (i % 100) / 100))
                  .round();
        }
        return Uint8List.view(s.buffer);
      })(),
    ];
    for (final d in cases) {
      final packed = QuantizedLpc.encode(d);
      expect(
        QuantizedLpc.decode(packed, d.length),
        equals(d),
        reason: 'len ${d.length}',
      );
    }
  });
}
