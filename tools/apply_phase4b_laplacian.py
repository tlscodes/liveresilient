#!/usr/bin/env python3
"""Phase 4b record: Laplacian pyramid + 2D Paeth prediction.

Before: every pyramid level independently coded the whole downsampled
image with a 1D row-delta filter, so the fine levels re-paid for
information the coarse levels had already delivered.

After: level 0 is coded with the 2D Paeth predictor (uses left, above and
above-left instead of left only). Every finer level codes only its
residual against the nearest-neighbour upsample of the level before it,
in mod-16 arithmetic so the inverse is exact. Progressive prefix decoding
is preserved: level i is reconstructed from the already-decoded level
i-1, which prefix order guarantees is present.
"""
import pathlib
import sys

TARGET = pathlib.Path(
    "/Users/behnam/Downloads/voice_call_kit_v3/packages/connection_orchestrator"
    "/lib/src/media_codecs/low_rate_image_compressor.dart"
)

OLD = '''  /// Encode the progressive pyramid; levels decode independently in
  /// prefix order (coarse first).
  List<ProgressiveLevel> encodeProgressive(
      Uint8List px, int w, int h, int ch) {
    final out = <ProgressiveLevel>[];
    for (final lw in levels) {
      final lh = (h * lw / w).round().clamp(1, 1 << 14);
      final gray = _grayDown(px, w, h, ch, lw, lh);
      // 4-bit quantize, two pixels per byte, then row-delta + CM.
      final q = Uint8List(gray.length);
      for (var i = 0; i < gray.length; i++) {
        q[i] = gray[i] >> 4;
      }
      final filtered = SpatialResidual.rowDelta(q, lw, lh, 1);
      out.add(ProgressiveLevel(lw, lh, _cm.compress(filtered)));
    }
    return out;
  }

  /// Decode any prefix of levels; returns the finest available.
  DecodedThumbnail decodeProgressive(List<ProgressiveLevel> received) {
    if (received.isEmpty) {
      throw ArgumentError('no levels received');
    }
    final level = received.last;
    final filtered = _cm.decompress(level.bytes);
    final q =
        SpatialResidual.unRowDelta(filtered, level.width, level.height, 1);
    final gray = Uint8List(q.length);
    for (var i = 0; i < q.length; i++) {
      gray[i] = (q[i] << 4) | q[i]; // 4-bit -> 8-bit
    }
    return DecodedThumbnail(level.width, level.height, gray);
  }'''

NEW = '''  /// Nearest-neighbour upsample of a single-channel plane. Deterministic
  /// and identical on both sides, which is what lets the pyramid residual
  /// invert exactly.
  static Uint8List _upsample(
      Uint8List src, int sw, int sh, int dw, int dh) {
    final out = Uint8List(dw * dh);
    for (var y = 0; y < dh; y++) {
      final sy = (y * sh) ~/ dh;
      for (var x = 0; x < dw; x++) {
        out[y * dw + x] = src[sy * sw + (x * sw) ~/ dw];
      }
    }
    return out;
  }

  /// Encode the progressive pyramid as a Laplacian pyramid: the coarsest
  /// level carries the image, every finer level carries only what its
  /// predecessor could not predict.
  ///
  /// Level 0 uses the 2D Paeth predictor (left, above, above-left) rather
  /// than a 1D row delta, so vertical structure is predicted too. Finer
  /// levels subtract the upsampled previous level in mod-16 arithmetic;
  /// the residual concentrates around zero, which is exactly what the
  /// context-mixing coder exploits.
  List<ProgressiveLevel> encodeProgressive(
      Uint8List px, int w, int h, int ch) {
    final out = <ProgressiveLevel>[];
    Uint8List? prevQ;
    var prevW = 0, prevH = 0;
    for (final lw in levels) {
      final lh = (h * lw / w).round().clamp(1, 1 << 14);
      final gray = _grayDown(px, w, h, ch, lw, lh);
      final q = Uint8List(gray.length);
      for (var i = 0; i < gray.length; i++) {
        q[i] = gray[i] >> 4; // 4-bit quantize
      }
      final Uint8List coded;
      if (prevQ == null) {
        coded = SpatialResidual.paeth(q, lw, lh, 1);
      } else {
        final pred = _upsample(prevQ, prevW, prevH, lw, lh);
        final residual = Uint8List(q.length);
        for (var i = 0; i < q.length; i++) {
          residual[i] = (q[i] - pred[i]) & 0x0F;
        }
        coded = residual;
      }
      out.add(ProgressiveLevel(lw, lh, _cm.compress(coded)));
      prevQ = q;
      prevW = lw;
      prevH = lh;
    }
    return out;
  }

  /// Decode any prefix of levels; returns the finest available. Each
  /// level after the first is reconstructed on top of the one before it,
  /// which prefix ordering guarantees has already been decoded.
  DecodedThumbnail decodeProgressive(List<ProgressiveLevel> received) {
    if (received.isEmpty) {
      throw ArgumentError('no levels received');
    }
    Uint8List? prevQ;
    var prevW = 0, prevH = 0;
    for (final level in received) {
      final payload = _cm.decompress(level.bytes);
      final Uint8List q;
      if (prevQ == null) {
        q = SpatialResidual.unPaeth(payload, level.width, level.height, 1);
      } else {
        final pred =
            _upsample(prevQ, prevW, prevH, level.width, level.height);
        q = Uint8List(payload.length);
        for (var i = 0; i < payload.length; i++) {
          q[i] = (payload[i] + pred[i]) & 0x0F;
        }
      }
      prevQ = q;
      prevW = level.width;
      prevH = level.height;
    }
    final q = prevQ!;
    final gray = Uint8List(q.length);
    for (var i = 0; i < q.length; i++) {
      gray[i] = (q[i] << 4) | q[i]; // 4-bit -> 8-bit
    }
    return DecodedThumbnail(prevW, prevH, gray);
  }'''

text = TARGET.read_text(encoding="utf-8")
if OLD not in text:
    sys.exit("anchor not found in low_rate_image_compressor.dart")
TARGET.write_text(text.replace(OLD, NEW, 1), encoding="utf-8")
print(f"patched {TARGET.name}")
