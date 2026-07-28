/// Colour on a link that can barely carry a picture.
///
/// The claim is narrow and measurable: a coarse two-bit chroma plane costs
/// a small fraction of the luma pyramid and recovers the one thing
/// grayscale cannot express — whether the thing in the picture is fire, or
/// water, or a uniform. Every number here is measured by the test rather
/// than quoted.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:test/test.dart';

/// A scene with two strongly coloured regions of equal brightness.
///
/// Equal brightness is the point: in grayscale these are the same
/// picture, so any ability to tell them apart came from the chroma plane
/// and nowhere else.
Uint8List _twoTone(
  int w,
  int h, {
  required List<int> left,
  required List<int> right,
}) {
  final px = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = x < w ~/ 2 ? left : right;
      final i = (y * w + x) * 3;
      px[i] = c[0];
      px[i + 1] = c[1];
      px[i + 2] = c[2];
    }
  }
  return px;
}

/// A textured scene, so a size ratio means something.
///
/// A flat two-tone image compresses to almost nothing, which makes any
/// "fraction of the luma pyramid" claim measured against it meaningless —
/// the denominator is the artefact, not the codec.
Uint8List _texturedScene(int w, int h) {
  final px = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final dx = x - w / 2, dy = y - h / 2;
      final inDisc = math.sqrt(dx * dx + dy * dy) < w / 4;
      final noise = ((x * 37 + y * 53) % 29) - 14;
      final base = (40 + x * 150 ~/ w + y * 40 ~/ h + noise).clamp(0, 255);
      final i = (y * w + x) * 3;
      px[i] = inDisc ? (base + 60).clamp(0, 255) : base;
      px[i + 1] = (base * 3 ~/ 4).clamp(0, 255);
      px[i + 2] = inDisc ? (base ~/ 3) : (255 - base);
    }
  }
  return px;
}

/// Mean absolute error per channel between two interleaved RGB buffers.
double _rgbError(Uint8List a, Uint8List b) {
  var total = 0;
  for (var i = 0; i < a.length; i++) {
    total += (a[i] - b[i]).abs();
  }
  return total / a.length;
}

/// The average colour of one half of a decoded RGB buffer.
List<int> _meanOfHalf(Uint8List rgb, int w, int h, {required bool leftHalf}) {
  var r = 0, g = 0, b = 0, n = 0;
  for (var y = 0; y < h; y++) {
    final from = leftHalf ? 0 : w ~/ 2;
    final to = leftHalf ? w ~/ 2 : w;
    for (var x = from; x < to; x++) {
      final i = (y * w + x) * 3;
      r += rgb[i];
      g += rgb[i + 1];
      b += rgb[i + 2];
      n++;
    }
  }
  return [r ~/ n, g ~/ n, b ~/ n];
}

void main() {
  const codec = LowRateImageCompressor();

  group('what colour costs', () {
    test('a chroma plane is a small fraction of the luma pyramid', () {
      // The trade this whole feature rests on, measured on a scene with
      // real texture rather than a flat field.
      final px = _texturedScene(160, 120);
      final luma = codec.encodeProgressive(px, 160, 120, 3);
      final chroma = codec.encodeChroma(px, 160, 120, 3);

      final lumaBytes = luma.fold<int>(0, (sum, l) => sum + l.bytes.length);
      expect(chroma.bytes.length, lessThan(lumaBytes ~/ 4));
      expect(
        chroma.bytes.length,
        lessThan(200),
        reason: 'colour must stay affordable on the worst link',
      );
    });

    test('the chroma plane is far coarser than the luma', () {
      final px = _twoTone(160, 120, left: [200, 40, 40], right: [40, 60, 200]);
      final chroma = codec.encodeChroma(px, 160, 120, 3);
      expect(chroma.width, LowRateImageCompressor.chromaWidth);
      expect(chroma.width, lessThan(codec.levels.first));
      expect(chroma.coder, LevelCoder.chromaPair);
    });
  });

  group('what colour buys', () {
    test('two regions of equal brightness become distinguishable', () {
      // In grayscale these two halves are identical. If the decoded
      // picture can tell them apart at all, the chroma plane is the only
      // place that information could have come from.
      final px = _twoTone(160, 120, left: [180, 60, 60], right: [60, 60, 180]);

      final grey = codec.decodeProgressive(
        codec.encodeProgressive(px, 160, 120, 3),
      );
      expect(grey.hasColour, isFalse);

      final colour = codec.decodeProgressive([
        ...codec.encodeProgressive(px, 160, 120, 3),
        codec.encodeChroma(px, 160, 120, 3),
      ]);
      expect(colour.hasColour, isTrue);

      final left = _meanOfHalf(
        colour.rgb!,
        colour.width,
        colour.height,
        leftHalf: true,
      );
      final right = _meanOfHalf(
        colour.rgb!,
        colour.width,
        colour.height,
        leftHalf: false,
      );
      // Red-dominant on the left, blue-dominant on the right.
      expect(left[0], greaterThan(left[2]), reason: 'left reads as warm');
      expect(right[2], greaterThan(right[0]), reason: 'right reads as cool');
    });

    test('a red scene decodes red and a blue scene decodes blue', () {
      for (final scene in [
        (name: 'fire', colour: [220, 70, 30], warm: true),
        (name: 'water', colour: [30, 80, 200], warm: false),
      ]) {
        final px = _twoTone(96, 72, left: scene.colour, right: scene.colour);
        final decoded = codec.decodeProgressive([
          ...codec.encodeProgressive(px, 96, 72, 3),
          codec.encodeChroma(px, 96, 72, 3),
        ]);
        final mean = _meanOfHalf(
          decoded.rgb!,
          decoded.width,
          decoded.height,
          leftHalf: true,
        );
        if (scene.warm) {
          expect(
            mean[0],
            greaterThan(mean[2]),
            reason: '${scene.name} is warm',
          );
        } else {
          expect(
            mean[2],
            greaterThan(mean[0]),
            reason: '${scene.name} is cool',
          );
        }
      }
    });

    test('a grey scene stays grey rather than acquiring a tint', () {
      // The failure mode a two-bit quantizer invites: colour appearing
      // where there was none.
      final px = _twoTone(
        96,
        72,
        left: [128, 128, 128],
        right: [128, 128, 128],
      );
      final decoded = codec.decodeProgressive([
        ...codec.encodeProgressive(px, 96, 72, 3),
        codec.encodeChroma(px, 96, 72, 3),
      ]);
      final mean = _meanOfHalf(
        decoded.rgb!,
        decoded.width,
        decoded.height,
        leftHalf: true,
      );
      final spread = [
        (mean[0] - mean[1]).abs(),
        (mean[1] - mean[2]).abs(),
        (mean[0] - mean[2]).abs(),
      ].reduce(math.max);
      expect(spread, lessThan(60), reason: 'no invented tint on a grey field');
    });
  });

  group('order and absence', () {
    test('colour is order independent', () {
      // A chroma level is painted over whatever luma arrived, so it is
      // just as usable whether it came before or after the refinements.
      final px = _twoTone(96, 72, left: [200, 50, 50], right: [50, 50, 200]);
      final luma = codec.encodeProgressive(px, 96, 72, 3);
      final chroma = codec.encodeChroma(px, 96, 72, 3);

      final after = codec.decodeProgressive([...luma, chroma]);
      final before = codec.decodeProgressive([chroma, ...luma]);
      expect(before.hasColour, isTrue);
      expect(_rgbError(after.rgb!, before.rgb!), 0);
    });

    test('a partial luma pyramid still takes colour', () {
      // The realistic case on a thin link: the coarse level and the
      // colour arrive, the refinements do not.
      final px = _twoTone(96, 72, left: [200, 50, 50], right: [50, 50, 200]);
      final luma = codec.encodeProgressive(px, 96, 72, 3);
      final decoded = codec.decodeProgressive([
        luma.first,
        codec.encodeChroma(px, 96, 72, 3),
      ]);
      expect(decoded.hasColour, isTrue);
      expect(decoded.width, luma.first.width);
      expect(decoded.rgb!.length, decoded.width * decoded.height * 3);
    });

    test('no chroma level means a picture without colour, not a failure', () {
      final px = _twoTone(96, 72, left: [200, 50, 50], right: [50, 50, 200]);
      final decoded = codec.decodeProgressive(
        codec.encodeProgressive(px, 96, 72, 3),
      );
      expect(decoded.hasColour, isFalse);
      expect(decoded.rgb, isNull);
      expect(decoded.gray, isNotEmpty);
    });

    test('a chroma level with no luma is refused, not painted on grey', () {
      // Inventing a flat field and tinting it would be the same class of
      // mistake as showing a refinement level as though it were a photo.
      final px = _twoTone(96, 72, left: [200, 50, 50], right: [50, 50, 200]);
      expect(
        () => codec.decodeProgressive([codec.encodeChroma(px, 96, 72, 3)]),
        throwsArgumentError,
      );
    });

    test('colour needs three channels', () {
      expect(
        () => codec.encodeChroma(Uint8List(96 * 72), 96, 72, 1),
        throwsArgumentError,
      );
    });
  });

  test('the whole colour picture still fits the low-rate budget', () {
    // The claim that matters for the product: a recognisable colour
    // photograph on a link that can carry a few hundred bytes a second.
    final px = _twoTone(320, 240, left: [210, 60, 40], right: [40, 90, 190]);
    final luma = codec.encodeProgressive(px, 320, 240, 3);
    final chroma = codec.encodeChroma(px, 320, 240, 3);
    final total =
        luma.fold<int>(0, (sum, l) => sum + l.bytes.length) +
        chroma.bytes.length;
    expect(total, lessThan(2048));

    // And the coarsest useful colour picture — one luma level plus
    // chroma — is far smaller again.
    final firstGlimpse = luma.first.bytes.length + chroma.bytes.length;
    expect(firstGlimpse, lessThan(400));
  });
}
