/// Phase 4b — photo compression for a few-hundred-bytes-per-second wire.
///
/// Two forms, per the brief:
///  1. Progressive thumbnail (~1 KB target): grayscale mean-downsampled
///     pyramid (coarse level first), 4-bit quantized, row-delta filtered,
///     each level entropy-coded by the live context compressor. The
///     receiver renders something after the FIRST level (~tens of bytes)
///     and refines as later levels arrive. Lossy by design: the claim is
///     size + structural fidelity, never bit-exactness (that claim
///     belongs to the transport, which carries these bytes losslessly).
///  2. Contour trace (300-800 B target): threshold at the image mean,
///     horizontal run-length rectangles merged into an SVG path — a
///     recognizable outline for the first seconds of a transfer.
library;

import 'dart:typed_data';

import 'live_context_compressor.dart';
import 'media_frontends.dart';

/// How a pyramid level's plane was prepared before entropy coding.
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
}

class DecodedThumbnail {
  DecodedThumbnail(this.width, this.height, this.gray);
  final int width;
  final int height;
  final Uint8List gray; // 8-bit grayscale (upscaled from 4-bit)
}

class LowRateImageCompressor {
  const LowRateImageCompressor({this.levels = const [12, 24, 48]});

  /// Pyramid widths, coarse first. Heights follow the aspect ratio.
  final List<int> levels;

  static const _cm = LiveContextCompressor();

  /// Grayscale mean-downsample of an interleaved 8-bit image.
  static Uint8List _grayDown(
      Uint8List px, int w, int h, int ch, int ow, int oh) {
    final out = Uint8List(ow * oh);
    for (var oy = 0; oy < oh; oy++) {
      final y0 = oy * h ~/ oh, y1 = ((oy + 1) * h ~/ oh).clamp(y0 + 1, h);
      for (var ox = 0; ox < ow; ox++) {
        final x0 = ox * w ~/ ow, x1 = ((ox + 1) * w ~/ ow).clamp(x0 + 1, w);
        var sum = 0, cnt = 0;
        for (var y = y0; y < y1; y++) {
          for (var x = x0; x < x1; x++) {
            final i = (y * w + x) * ch;
            sum += (px[i] + px[i + 1] + px[i + 2]) ~/ 3;
            cnt++;
          }
        }
        out[oy * ow + ox] = sum ~/ cnt;
      }
    }
    return out;
  }

  /// Nearest-neighbour upsample of a single-channel plane. Deterministic
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
      // The plane this level has to convey: the image itself for the
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
      out.add(ProgressiveLevel(lw, lh, best, bestCoder));
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
  }

  /// Contour trace: threshold at the mean, emit merged horizontal runs
  /// of the dark region as SVG rects on a coarse grid. Deterministic.
  String contourSvg(Uint8List px, int w, int h, int ch, {int gridW = 48}) {
    final gridH = (h * gridW / w).round().clamp(1, 1 << 12);
    final gray = _grayDown(px, w, h, ch, gridW, gridH);
    var mean = 0;
    for (final g in gray) {
      mean += g;
    }
    mean ~/= gray.length;
    final sb = StringBuffer(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $gridW $gridH">'
        '<path d="');
    for (var y = 0; y < gridH; y++) {
      var x = 0;
      while (x < gridW) {
        if (gray[y * gridW + x] < mean) {
          final start = x;
          while (x < gridW && gray[y * gridW + x] < mean) {
            x++;
          }
          sb.write('M$start ${y}h${x - start}');
        } else {
          x++;
        }
      }
    }
    sb.write('" stroke="#000"/></svg>');
    return sb.toString();
  }
}
