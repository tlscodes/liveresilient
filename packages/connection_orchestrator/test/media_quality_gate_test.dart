/// A gate on what the codecs mean, not only on what they cost.
///
/// Every other test around these compressors asserts a size. None of them
/// would notice if an optimisation made the output smaller and the picture
/// unrecognisable — which is the failure mode a lossy codec invites, and
/// the one a byte count is structurally unable to see.
///
/// So this measures fidelity directly, against fixed synthetic scenes, and
/// fails when it regresses. The scenes are generated rather than stored so
/// the test carries no binary fixtures, and the thresholds are set from
/// what the codec achieves today with room beneath them: the purpose is to
/// catch a fall, not to freeze a number.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:test/test.dart';

/// A scene with structure at several scales: a gradient, a hard-edged
/// disc, and fine texture. Between them they exercise what a pyramid
/// codec is good and bad at.
Uint8List _scene(int w, int h, {int seed = 1}) {
  final px = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final dx = x - w / 2, dy = y - h / 2;
      final radius = math.sqrt(dx * dx + dy * dy);
      final inDisc = radius < w / 4;
      final texture = ((x * seed * 31 + y * 17) % 23) - 11;
      final base = (30 + x * 170 ~/ w + texture).clamp(0, 255);
      final i = (y * w + x) * 3;
      px[i] = inDisc ? 235 : base;
      px[i + 1] = inDisc ? 90 : (base * 4 ~/ 5).clamp(0, 255);
      px[i + 2] = inDisc ? 40 : (255 - base);
    }
  }
  return px;
}

/// Mean-downsample an interleaved image to grayscale at [ow] x [oh].
Uint8List _grayAt(Uint8List px, int w, int h, int ow, int oh) {
  final out = Uint8List(ow * oh);
  for (var oy = 0; oy < oh; oy++) {
    final y0 = oy * h ~/ oh, y1 = ((oy + 1) * h ~/ oh).clamp(y0 + 1, h);
    for (var ox = 0; ox < ow; ox++) {
      final x0 = ox * w ~/ ow, x1 = ((ox + 1) * w ~/ ow).clamp(x0 + 1, w);
      var sum = 0, n = 0;
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final i = (y * w + x) * 3;
          sum += (px[i] + px[i + 1] + px[i + 2]) ~/ 3;
          n++;
        }
      }
      out[oy * ow + ox] = sum ~/ n;
    }
  }
  return out;
}

/// Structural similarity between two single-channel planes of equal size.
///
/// The global form of SSIM: luminance, contrast and structure compared
/// over the whole plane. Chosen over a per-pixel error because that is
/// the point — a picture can be numerically far from the original and
/// still show the same thing, and a picture can be numerically close and
/// show nothing at all.
double _ssim(Uint8List a, Uint8List b) {
  if (a.length != b.length || a.isEmpty) {
    throw ArgumentError('planes must match and be non-empty');
  }
  final n = a.length;
  var meanA = 0.0, meanB = 0.0;
  for (var i = 0; i < n; i++) {
    meanA += a[i];
    meanB += b[i];
  }
  meanA /= n;
  meanB /= n;

  var varA = 0.0, varB = 0.0, covar = 0.0;
  for (var i = 0; i < n; i++) {
    final da = a[i] - meanA, db = b[i] - meanB;
    varA += da * da;
    varB += db * db;
    covar += da * db;
  }
  varA /= n;
  varB /= n;
  covar /= n;

  // The usual stabilisers for an 8-bit dynamic range.
  const c1 = 6.5025, c2 = 58.5225;
  return ((2 * meanA * meanB + c1) * (2 * covar + c2)) /
      ((meanA * meanA + meanB * meanB + c1) * (varA + varB + c2));
}

void main() {
  const codec = LowRateImageCompressor();
  const flipbook = FlipbookVideoCompressor();

  group('a decoded picture still shows what was photographed', () {
    test('the full pyramid keeps its structure', () {
      // The headline claim of a lossy image codec, measured rather than
      // asserted by its author's confidence.
      for (final seed in [1, 3, 7]) {
        final px = _scene(160, 120, seed: seed);
        final decoded = codec.decodeProgressive(
          codec.encodeProgressive(px, 160, 120, 3),
        );
        final reference = _grayAt(px, 160, 120, decoded.width, decoded.height);
        final score = _ssim(reference, decoded.gray);
        expect(
          score,
          greaterThan(0.90),
          reason: 'scene $seed decoded at SSIM $score',
        );
      }
    });

    test('the coarsest level alone is already recognisable', () {
      // The property the progressive design exists for: something worth
      // looking at after the first few dozen bytes.
      final px = _scene(160, 120);
      final levels = codec.encodeProgressive(px, 160, 120, 3);
      final decoded = codec.decodeProgressive([levels.first]);
      final reference = _grayAt(px, 160, 120, decoded.width, decoded.height);
      final score = _ssim(reference, decoded.gray);
      expect(score, greaterThan(0.75), reason: 'first glimpse SSIM $score');
      expect(levels.first.bytes.length, lessThan(200));
    });

    test('each refinement is at least as good as the one before it', () {
      // A refinement that made the picture worse would be bytes spent to
      // lose information, and nothing in a size assertion would catch it.
      final px = _scene(200, 150, seed: 5);
      final levels = codec.encodeProgressive(px, 200, 150, 3);
      var previous = 0.0;
      for (var count = 1; count <= levels.length; count++) {
        final decoded = codec.decodeProgressive(levels.sublist(0, count));
        final reference = _grayAt(px, 200, 150, decoded.width, decoded.height);
        final score = _ssim(reference, decoded.gray);
        expect(
          score,
          greaterThanOrEqualTo(previous - 0.05),
          reason: 'level $count fell to SSIM $score from $previous',
        );
        previous = score;
      }
      expect(previous, greaterThan(0.90));
    });

    test('colour does not damage the luma it is painted on', () {
      // Adding a chroma plane must not disturb the brightness structure,
      // which is where all the shape information lives.
      final px = _scene(160, 120);
      final luma = codec.encodeProgressive(px, 160, 120, 3);
      final withoutColour = codec.decodeProgressive(luma);
      final withColour = codec.decodeProgressive([
        ...luma,
        codec.encodeChroma(px, 160, 120, 3),
      ]);
      expect(_ssim(withoutColour.gray, withColour.gray), 1.0);
    });
  });

  group('a decoded clip still shows what moved', () {
    test('frames keep their structure through the flipbook', () {
      final frames = <Uint8List>[];
      const w = 64, h = 48;
      for (var f = 0; f < 4; f++) {
        final frame = Uint8List(w * h);
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final moving = x >= f * 4 && x < f * 4 + 14 && y > 8 && y < 34;
            frame[y * w + x] = moving ? 230 : (30 + (x * 3 % 40));
          }
        }
        frames.add(frame);
      }

      final decoded = flipbook.decode(flipbook.encode(frames, w, h));
      expect(decoded, hasLength(frames.length));
      for (var i = 0; i < frames.length; i++) {
        // Compared against the codec's own declared downsampling, not
        // against the full-resolution source. Those are two different
        // questions, and only one of them is a regression: losing detail
        // the format says it discards is the design, while losing detail
        // it says it keeps is a bug. This measures the second.
        final reference = flipbook.downQuant(frames[i], w, h);
        expect(decoded[i].length, reference.length);
        final score = _ssim(reference, decoded[i]);
        expect(
          score,
          greaterThan(0.90),
          reason: 'frame $i decoded at SSIM $score',
        );
      }
    });
  });

  group('the metric itself', () {
    test('is 1 for an identical plane', () {
      final plane = Uint8List.fromList(
        List.generate(64, (i) => (i * 7) & 0xFF),
      );
      expect(_ssim(plane, plane), closeTo(1.0, 1e-9));
    });

    test('is low for an unrelated plane', () {
      // Without this the whole gate could be passing on a metric that
      // says everything is fine.
      final a = Uint8List.fromList(List.generate(256, (i) => i & 0xFF));
      final b = Uint8List.fromList(List.generate(256, (i) => (255 - i) & 0xFF));
      expect(_ssim(a, b), lessThan(0.5));
    });

    test('refuses mismatched or empty planes', () {
      expect(() => _ssim(Uint8List(4), Uint8List(5)), throwsArgumentError);
      expect(() => _ssim(Uint8List(0), Uint8List(0)), throwsArgumentError);
    });
  });
}
