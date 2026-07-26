#!/usr/bin/env python3
"""Phase 4b record: per-row adaptive prediction filter.

A single fixed predictor is always wrong somewhere: Paeth wins on
photographic gradients, plain "up" wins on flat bands, "sub" wins on
horizontal texture. Real image coders therefore choose per row.

This adds AdaptiveFilter: for every row it evaluates six predictors
(none, sub, up, average, Paeth, and the LOCO-I / JPEG-LS median edge
detector), scores them by the sum of absolute signed residuals, and keeps
the cheapest. The chosen filter id is stored as one byte at the head of
each row, so the inverse is exact and needs no side channel. Predictions
on the inverse path read reconstructed pixels, which is what makes the
round-trip bit-exact.
"""
import pathlib
import sys

PKG = pathlib.Path(
    "/Users/behnam/Downloads/voice_call_kit_v3/packages/connection_orchestrator"
)
FRONTENDS = PKG / "lib/src/media_codecs/media_frontends.dart"

CLASS = '''
/// Per-row adaptive prediction, the way production image coders do it:
/// every row picks the predictor that leaves the least residual energy,
/// and records which one it picked.
///
/// Layout: for each row, one filter-id byte followed by that row's
/// residual bytes. The id makes the inverse exact without any side
/// channel, and costs one byte per row.
class AdaptiveFilter {
  static const int filterNone = 0;
  static const int filterSub = 1;
  static const int filterUp = 2;
  static const int filterAverage = 3;
  static const int filterPaeth = 4;

  /// LOCO-I / JPEG-LS median edge detector: picks min, max, or the
  /// gradient prediction depending on whether an edge is detected.
  static const int filterMed = 5;

  static const int filterCount = 6;

  static int _predict(
      int filter, int a, int b, int c) {
    switch (filter) {
      case filterNone:
        return 0;
      case filterSub:
        return a;
      case filterUp:
        return b;
      case filterAverage:
        return (a + b) >> 1;
      case filterPaeth:
        final p = a + b - c;
        final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
        return pa <= pb && pa <= pc ? a : (pb <= pc ? b : c);
      case filterMed:
        if (c >= a && c >= b) return a < b ? a : b;
        if (c <= a && c <= b) return a > b ? a : b;
        return (a + b - c).clamp(0, 255);
      default:
        throw ArgumentError('unknown filter $filter');
    }
  }

  /// Encode [px] (w x h, [ch] interleaved channels) into filtered rows.
  static Uint8List forward(Uint8List px, int w, int h, int ch) {
    final stride = w * ch;
    final out = Uint8List(h * (stride + 1));
    final row = Uint8List(stride);
    for (var y = 0; y < h; y++) {
      var bestFilter = filterNone;
      var bestCost = -1;
      for (var f = 0; f < filterCount; f++) {
        var cost = 0;
        for (var x = 0; x < stride; x++) {
          final a = x >= ch ? px[y * stride + x - ch] : 0;
          final b = y > 0 ? px[(y - 1) * stride + x] : 0;
          final c = (x >= ch && y > 0) ? px[(y - 1) * stride + x - ch] : 0;
          var r = (px[y * stride + x] - _predict(f, a, b, c)) & 0xFF;
          // Score by distance from zero on the signed byte circle: 250
          // is a residual of -6, not a large value.
          if (r > 127) r = 256 - r;
          cost += r;
        }
        if (bestCost < 0 || cost < bestCost) {
          bestCost = cost;
          bestFilter = f;
        }
      }
      for (var x = 0; x < stride; x++) {
        final a = x >= ch ? px[y * stride + x - ch] : 0;
        final b = y > 0 ? px[(y - 1) * stride + x] : 0;
        final c = (x >= ch && y > 0) ? px[(y - 1) * stride + x - ch] : 0;
        row[x] = (px[y * stride + x] - _predict(bestFilter, a, b, c)) & 0xFF;
      }
      final base = y * (stride + 1);
      out[base] = bestFilter;
      out.setRange(base + 1, base + 1 + stride, row);
    }
    return out;
  }

  /// Exact inverse of [forward]; predictions read reconstructed pixels.
  static Uint8List inverse(Uint8List filtered, int w, int h, int ch) {
    final stride = w * ch;
    if (filtered.length != h * (stride + 1)) {
      throw const FormatException('filtered plane has the wrong length');
    }
    final out = Uint8List(h * stride);
    for (var y = 0; y < h; y++) {
      final base = y * (stride + 1);
      final filter = filtered[base];
      for (var x = 0; x < stride; x++) {
        final a = x >= ch ? out[y * stride + x - ch] : 0;
        final b = y > 0 ? out[(y - 1) * stride + x] : 0;
        final c = (x >= ch && y > 0) ? out[(y - 1) * stride + x - ch] : 0;
        out[y * stride + x] =
            (filtered[base + 1 + x] + _predict(filter, a, b, c)) & 0xFF;
      }
    }
    return out;
  }
}
'''

text = FRONTENDS.read_text(encoding="utf-8")
if "class AdaptiveFilter" in text:
    sys.exit("AdaptiveFilter already present")
FRONTENDS.write_text(text.rstrip() + "\n" + CLASS, encoding="utf-8")
print(f"patched {FRONTENDS.name}")

# Route the image pyramid's base level through the adaptive filter.
IMG = PKG / "lib/src/media_codecs/low_rate_image_compressor.dart"
img = IMG.read_text(encoding="utf-8")
pairs = [
    (
        "      if (prevQ == null) {\n"
        "        coded = SpatialResidual.paeth(q, lw, lh, 1);",
        "      if (prevQ == null) {\n"
        "        coded = AdaptiveFilter.forward(q, lw, lh, 1);",
    ),
    (
        "        q = SpatialResidual.unPaeth(payload, level.width, level.height, 1);",
        "        q = AdaptiveFilter.inverse(payload, level.width, level.height, 1);",
    ),
]
for old, new in pairs:
    if old not in img:
        sys.exit(f"image anchor not found:\n{old[:70]}")
    img = img.replace(old, new, 1)
IMG.write_text(img, encoding="utf-8")
print(f"patched {IMG.name}")
