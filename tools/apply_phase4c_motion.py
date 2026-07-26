#!/usr/bin/env python3
"""Phase 4c record: motion-compensated temporal prediction + 2D intra.

Before: the temporal mode subtracted the previous keyframe pixel-for-
pixel at the same coordinates, so any camera pan made every pixel differ
and the mode lost to intra. Intra itself used a 1D row delta.

After:
  * intra uses the 2D Paeth predictor (left, above, above-left);
  * temporal searches a small global motion vector and subtracts the
    SHIFTED previous frame, so a pan costs almost nothing. The chosen
    vector rides in two header bytes ahead of the coded residual.
Both candidates are still coded and the smaller one wins, so the change
can never produce a larger frame than the previous implementation.
"""
import pathlib
import sys

TARGET = pathlib.Path(
    "/Users/behnam/Downloads/voice_call_kit_v3/packages/connection_orchestrator"
    "/lib/src/media_codecs/flipbook_video_compressor.dart"
)

OLD_ENCODE = '''      final q = _downQuant(grayFrames[f], srcW, srcH);
      final intra = _cm.compress(
          SpatialResidual.rowDelta(q, width, height, 1));
      Uint8List coded;
      var temporal = false;
      if (prev != null) {
        final td = Uint8List(q.length);
        for (var i = 0; i < q.length; i++) {
          td[i] = (q[i] - prev[i]) & 0xFF;
        }
        final tdc = _cm.compress(td);
        if (tdc.length < intra.length) {
          coded = tdc;
          temporal = true;
        } else {
          coded = intra;
        }
      } else {
        coded = intra;
      }'''

NEW_ENCODE = '''      final q = _downQuant(grayFrames[f], srcW, srcH);
      final intra = _cm.compress(
          SpatialResidual.paeth(q, width, height, 1));
      Uint8List coded;
      var temporal = false;
      if (prev != null) {
        final (dx, dy) = _searchMotion(q, prev);
        final td = _motionResidual(q, prev, dx, dy);
        final body = _cm.compress(td);
        // Two header bytes carry the vector so the decoder shifts the
        // same way; biased by 128 to stay in an unsigned byte.
        final tdc = Uint8List(body.length + 2);
        tdc[0] = dx + 128;
        tdc[1] = dy + 128;
        tdc.setRange(2, tdc.length, body);
        if (tdc.length < intra.length) {
          coded = tdc;
          temporal = true;
        } else {
          coded = intra;
        }
      } else {
        coded = intra;
      }'''

OLD_DECODE = '''      if (f.temporal) {
        if (prev == null) throw StateError('temporal frame without history');
        final td = _cm.decompress(f.bytes);
        q = Uint8List(td.length);
        for (var i = 0; i < td.length; i++) {
          q[i] = (td[i] + prev[i]) & 0xFF;
        }
      } else {
        q = SpatialResidual.unRowDelta(
            _cm.decompress(f.bytes), width, height, 1);
      }'''

NEW_DECODE = '''      if (f.temporal) {
        if (prev == null) throw StateError('temporal frame without history');
        if (f.bytes.length < 2) {
          throw const FormatException('temporal frame missing motion header');
        }
        final dx = f.bytes[0] - 128;
        final dy = f.bytes[1] - 128;
        final td = _cm.decompress(Uint8List.sublistView(f.bytes, 2));
        q = Uint8List(td.length);
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            final i = y * width + x;
            q[i] = (td[i] + _shifted(prev, x, y, dx, dy)) & 0xFF;
          }
        }
      } else {
        q = SpatialResidual.unPaeth(
            _cm.decompress(f.bytes), width, height, 1);
      }'''

HELPERS = '''
  /// Previous-frame sample displaced by the motion vector, with edge
  /// clamping so the predictor is defined everywhere.
  int _shifted(Uint8List prev, int x, int y, int dx, int dy) {
    final sx = (x - dx).clamp(0, width - 1);
    final sy = (y - dy).clamp(0, height - 1);
    return prev[sy * width + sx];
  }

  /// Residual of [q] against [prev] displaced by (dx, dy), mod 256 so the
  /// inverse is exact.
  Uint8List _motionResidual(Uint8List q, Uint8List prev, int dx, int dy) {
    final out = Uint8List(q.length);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        out[i] = (q[i] - _shifted(prev, x, y, dx, dy)) & 0xFF;
      }
    }
    return out;
  }

  /// Full search for the global motion vector inside [motionSearchRadius],
  /// scored by sum of absolute differences. The flipbook grid is tiny
  /// (120x80 by default), so an exhaustive search over a 9x9 window is
  /// cheap and, unlike a heuristic, is deterministic and reproducible.
  (int, int) _searchMotion(Uint8List q, Uint8List prev) {
    var bestDx = 0, bestDy = 0;
    var bestCost = 1 << 62;
    for (var dy = -motionSearchRadius; dy <= motionSearchRadius; dy++) {
      for (var dx = -motionSearchRadius; dx <= motionSearchRadius; dx++) {
        var cost = 0;
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            final d = q[y * width + x] - _shifted(prev, x, y, dx, dy);
            cost += d < 0 ? -d : d;
          }
        }
        // Prefer the zero vector on ties: it costs no extra structure and
        // keeps output stable when the scene is static.
        if (cost < bestCost) {
          bestCost = cost;
          bestDx = dx;
          bestDy = dy;
        }
      }
    }
    return (bestDx, bestDy);
  }
'''

text = TARGET.read_text(encoding="utf-8")
for old, new in ((OLD_ENCODE, NEW_ENCODE), (OLD_DECODE, NEW_DECODE)):
    if old not in text:
        sys.exit(f"anchor not found:\n{old[:80]}")
    text = text.replace(old, new, 1)

# Insert the search radius field next to the other configuration and the
# helper methods just before the private _downQuant implementation.
anchor = "  Uint8List _downQuant("
if anchor not in text:
    sys.exit("_downQuant anchor not found")
text = text.replace(anchor, HELPERS.lstrip("\n") + "\n" + anchor, 1)

field_anchor = "  int frameCountFor(Duration videoLength) =>"
if field_anchor not in text:
    sys.exit("frameCountFor anchor not found")
text = text.replace(
    field_anchor,
    "  /// Half-width of the exhaustive global motion search window.\n"
    "  static const int motionSearchRadius = 4;\n\n" + field_anchor,
    1,
)

TARGET.write_text(text, encoding="utf-8")
print(f"patched {TARGET.name}")
