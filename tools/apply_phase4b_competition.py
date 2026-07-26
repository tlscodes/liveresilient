#!/usr/bin/env python3
"""Phase 4b record: every pyramid level picks its own coder.

The adaptive per-row filter pays for itself on detailed planes but its
one-byte-per-row header loses on the tiny coarse level, and the pyramid
residual is sometimes better left unfiltered. Rather than guess, each
level now codes all three candidates and keeps the smallest:

  fixedPaeth    2D Paeth over the plane
  adaptiveRow   per-row choice among six predictors (one id byte per row)
  rawResidual   the mod-16 pyramid residual coded directly

The winner is recorded on the level, so output can never be larger than
the best single strategy would have produced.
"""
import pathlib
import sys

IMG = pathlib.Path(
    "/Users/behnam/Downloads/voice_call_kit_v3/packages/connection_orchestrator"
    "/lib/src/media_codecs/low_rate_image_compressor.dart"
)

OLD_LEVEL = '''class ProgressiveLevel {
  ProgressiveLevel(this.width, this.height, this.bytes);
  final int width;
  final int height;
  final Uint8List bytes; // compressed payload for this level
}'''

NEW_LEVEL = '''/// How a pyramid level's plane was prepared before entropy coding.
enum LevelCoder {
  /// 2D Paeth prediction over the whole plane.
  fixedPaeth,

  /// Per-row choice among six predictors, one id byte per row.
  adaptiveRow,

  /// The plane is already a pyramid residual; code it directly.
  rawResidual,
}

class ProgressiveLevel {
  ProgressiveLevel(this.width, this.height, this.bytes, this.coder);
  final int width;
  final int height;
  final Uint8List bytes; // compressed payload for this level
  final LevelCoder coder;
}'''

OLD_ENC = '''      final Uint8List coded;
      if (prevQ == null) {
        coded = AdaptiveFilter.forward(q, lw, lh, 1);
      } else {
        final pred = _upsample(prevQ, prevW, prevH, lw, lh);
        final residual = Uint8List(q.length);
        for (var i = 0; i < q.length; i++) {
          residual[i] = (q[i] - pred[i]) & 0x0F;
        }
        coded = residual;
      }
      out.add(ProgressiveLevel(lw, lh, _cm.compress(coded)));'''

NEW_ENC = '''      // The plane this level has to convey: the image itself for the
      // base level, the residual against the upsampled predecessor for
      // every level after it.
      final Uint8List plane;
      if (prevQ == null) {
        plane = q;
      } else {
        final pred = _upsample(prevQ, prevW, prevH, lw, lh);
        plane = Uint8List(q.length);
        for (var i = 0; i < q.length; i++) {
          plane[i] = (q[i] - pred[i]) & 0x0F;
        }
      }
      // Three candidate preparations, smallest compressed output wins.
      final candidates = <LevelCoder, Uint8List>{
        LevelCoder.fixedPaeth: _cm.compress(
            SpatialResidual.paeth(plane, lw, lh, 1)),
        LevelCoder.adaptiveRow:
            _cm.compress(AdaptiveFilter.forward(plane, lw, lh, 1)),
        LevelCoder.rawResidual: _cm.compress(plane),
      };
      var bestCoder = LevelCoder.fixedPaeth;
      var best = candidates[bestCoder]!;
      candidates.forEach((coder, bytes) {
        if (bytes.length < best.length) {
          best = bytes;
          bestCoder = coder;
        }
      });
      out.add(ProgressiveLevel(lw, lh, best, bestCoder));'''

OLD_DEC = '''      final payload = _cm.decompress(level.bytes);
      final Uint8List q;
      if (prevQ == null) {
        q = AdaptiveFilter.inverse(payload, level.width, level.height, 1);
      } else {
        final pred =
            _upsample(prevQ, prevW, prevH, level.width, level.height);
        q = Uint8List(payload.length);
        for (var i = 0; i < payload.length; i++) {
          q[i] = (payload[i] + pred[i]) & 0x0F;
        }
      }'''

NEW_DEC = '''      final payload = _cm.decompress(level.bytes);
      final Uint8List plane;
      switch (level.coder) {
        case LevelCoder.fixedPaeth:
          plane = SpatialResidual.unPaeth(
              payload, level.width, level.height, 1);
        case LevelCoder.adaptiveRow:
          plane = AdaptiveFilter.inverse(
              payload, level.width, level.height, 1);
        case LevelCoder.rawResidual:
          plane = payload;
      }
      final Uint8List q;
      if (prevQ == null) {
        q = plane;
      } else {
        final pred =
            _upsample(prevQ, prevW, prevH, level.width, level.height);
        q = Uint8List(plane.length);
        for (var i = 0; i < plane.length; i++) {
          q[i] = (plane[i] + pred[i]) & 0x0F;
        }
      }'''

text = IMG.read_text(encoding="utf-8")
for old, new in ((OLD_LEVEL, NEW_LEVEL), (OLD_ENC, NEW_ENC), (OLD_DEC, NEW_DEC)):
    if old not in text:
        sys.exit(f"anchor not found:\n{old[:80]}")
    text = text.replace(old, new, 1)
IMG.write_text(text, encoding="utf-8")
print(f"patched {IMG.name}")
