import 'dart:math' as math;
import 'dart:typed_data';

import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

Uint8List _solid(int w, int h, int r, int g, int b) {
  final px = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    px[i * 4] = r;
    px[i * 4 + 1] = g;
    px[i * 4 + 2] = b;
    px[i * 4 + 3] = 255;
  }
  return px;
}

Uint8List _gradient(int w, int h) {
  final px = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final o = (y * w + x) * 4;
      px[o] = (255 * x / (w - 1)).round();
      px[o + 1] = (255 * y / (h - 1)).round();
      px[o + 2] = 96;
      px[o + 3] = 255;
    }
  }
  return px;
}

double _lumaOf(Uint8List rgba, int i) =>
    (rgba[i * 4] + rgba[i * 4 + 1] + rgba[i * 4 + 2]) / 3.0;

void main() {
  test('hash stays announcement-small (~30 bytes) and is deterministic', () {
    final a = ThumbHash.encodeRgba(64, 64, _gradient(64, 64));
    final b = ThumbHash.encodeRgba(64, 64, _gradient(64, 64));
    expect(a, equals(b));
    expect(a.length, lessThanOrEqualTo(40));
    expect(a.length, greaterThanOrEqualTo(20));
  });

  test('flat color round-trips within quantization error', () {
    final hash = ThumbHash.encodeRgba(48, 48, _solid(48, 48, 200, 120, 40));
    final img = ThumbHash.decodeToRgba(hash);
    for (var i = 0; i < img.width * img.height; i++) {
      expect((img.rgba[i * 4] - 200).abs(), lessThan(20));
      expect((img.rgba[i * 4 + 1] - 120).abs(), lessThan(20));
      expect((img.rgba[i * 4 + 2] - 40).abs(), lessThan(20));
      expect(img.rgba[i * 4 + 3], 255);
    }
  });

  test('gradient round-trips: luma error bounded, orientation preserved', () {
    const w = 64, h = 64;
    final src = _gradient(w, h);
    final img = ThumbHash.decodeToRgba(ThumbHash.encodeRgba(w, h, src),
        longSidePx: w);
    expect(img.width, w);
    expect(img.height, h);
    var errSum = 0.0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        errSum +=
            (_lumaOf(img.rgba, y * w + x) - _lumaOf(src, y * w + x)).abs();
      }
    }
    expect(errSum / (w * h), lessThan(0.15 * 255),
        reason: 'blurred placeholder must still resemble the photo');
    // The gradient brightens left-to-right; the decoded placeholder must
    // keep that shape.
    expect(_lumaOf(img.rgba, h ~/ 2 * w + (w - 4)),
        greaterThan(_lumaOf(img.rgba, h ~/ 2 * w + 3)));
  });

  test('aspect survives the round trip via the coefficient grid', () {
    final wide = ThumbHash.decodeToRgba(
        ThumbHash.encodeRgba(128, 64, _gradient(128, 64)));
    expect(wide.width, greaterThan(wide.height));
    final tall = ThumbHash.decodeToRgba(
        ThumbHash.encodeRgba(64, 128, _gradient(64, 128)));
    expect(tall.height, greaterThan(tall.width));
  });

  test('corrupt input is rejected, never mis-rendered', () {
    expect(() => ThumbHash.decodeToRgba(Uint8List(3)), throwsArgumentError);
    expect(
        () => ThumbHash.decodeToRgba(
            Uint8List.fromList([9, 6, 6, 0, 0, 0, 0, 0])),
        throwsArgumentError);
    expect(() => ThumbHash.encodeRgba(300, 4, Uint8List(300 * 4 * 4)),
        throwsArgumentError);
    // Random noise with a valid header byte must either decode or throw a
    // typed error — never crash unclassified.
    final rng = math.Random(7);
    for (var round = 0; round < 50; round++) {
      final junk = Uint8List.fromList(
          [1, ...List.generate(30, (_) => rng.nextInt(256))]);
      try {
        ThumbHash.decodeToRgba(junk);
      } on ArgumentError {
        // acceptable — typed rejection
      }
    }
  });
}
