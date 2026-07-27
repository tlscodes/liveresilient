/// Phase 4b — size bands, prefix decodability, determinism.
/// Honest note per the brief: this codec is LOSSY; assertions are size
/// plus structural similarity, never bit-exactness.
import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/src/media_codecs/low_rate_image_compressor.dart';
import 'package:test/test.dart';

Uint8List _synthetic(int w, int h, int ch, int kind) {
  final px = Uint8List(w * h * ch);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * ch;
      int v;
      switch (kind) {
        case 0: // smooth gradient photo-like
          v = ((x * 255 / w) + (y * 128 / h)).round() & 0xFF;
        case 1: // dark disc on light ground (portrait-ish silhouette)
          final dx = x - w / 2, dy = y - h / 2;
          v = dx * dx + dy * dy < (w * h / 12) ? 40 : 220;
        default: // noisy texture
          v = Random(y * w + x).nextInt(256);
      }
      px[i] = v;
      px[i + 1] = (v * 3 ~/ 4) & 0xFF;
      px[i + 2] = (v ~/ 2) & 0xFF;
      if (ch == 4) px[i + 3] = 255;
    }
  }
  return px;
}

void main() {
  const c = LowRateImageCompressor();
  const w = 640, h = 480, ch = 4;

  test('progressive form: total inside ~1KB target band, per-level '
      'prefix decode works, coarse level is tiny', () {
    for (final kind in [0, 1]) {
      final px = _synthetic(w, h, ch, kind);
      final levels = c.encodeProgressive(px, w, h, ch);
      final sizes = levels.map((l) => l.bytes.length).toList();
      final total = sizes.reduce((a, b) => a + b);
      // ignore: avoid_print
      print('progressive kind=$kind sizes=$sizes total=$total B');
      expect(
        total,
        inInclusiveRange(200, 2048),
        reason: 'total must sit in the ~1KB band',
      );
      expect(
        sizes.first,
        lessThan(200),
        reason: 'first level must land within the first datagrams',
      );
      // Every prefix decodes without error.
      for (var k = 1; k <= levels.length; k++) {
        final t = c.decodeProgressive(levels.sublist(0, k));
        expect(t.gray.length, t.width * t.height);
      }
    }
  });

  test('decoding is deterministic and structurally faithful', () {
    final px = _synthetic(w, h, ch, 1);
    final a = c.decodeProgressive(c.encodeProgressive(px, w, h, ch));
    final b = c.decodeProgressive(c.encodeProgressive(px, w, h, ch));
    expect(a.gray, equals(b.gray), reason: 'deterministic');
    // Structural check: disc center must be darker than the corners.
    int at(DecodedThumbnail t, double fx, double fy) =>
        t.gray[(fy * t.height).floor() * t.width + (fx * t.width).floor()];
    expect(at(a, 0.5, 0.5), lessThan(at(a, 0.05, 0.05) - 40));
  });

  test('contour SVG inside the 300-800 B declared band', () {
    for (final kind in [0, 1]) {
      final px = _synthetic(w, h, ch, kind);
      final svg = c.contourSvg(px, w, h, ch);
      // ignore: avoid_print
      print('contour kind=$kind: ${svg.length} B');
      expect(svg.length, inInclusiveRange(300, 800), reason: 'kind $kind');
      expect(svg, startsWith('<svg'));
    }
  });
}
