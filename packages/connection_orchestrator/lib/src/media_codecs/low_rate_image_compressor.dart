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

  /// The plane is a coarse chroma pair, two bits each of Co and Cg packed
  /// into one byte per sample.
  ///
  /// Colour is carried separately from the luma pyramid, and far coarser,
  /// because that is where the information actually is: a viewer reads
  /// shape from brightness and almost nothing from the precision of hue.
  /// A crisis photograph is a different photograph in colour — fire,
  /// blood, a uniform — and this buys that for a fraction of the bytes
  /// the same detail would cost in the luma plane.
  chromaPair,
}

class ProgressiveLevel {
  ProgressiveLevel(this.width, this.height, this.bytes, this.coder);
  final int width;
  final int height;
  final Uint8List bytes; // compressed payload for this level
  final LevelCoder coder;
}

class DecodedThumbnail {
  DecodedThumbnail(this.width, this.height, this.gray, {this.rgb});
  final int width;
  final int height;
  final Uint8List gray; // 8-bit grayscale (upscaled from 4-bit)

  /// Interleaved 8-bit RGB, present only when a chroma level arrived.
  ///
  /// Null is the ordinary case, not an error: colour is the last thing
  /// sent and the first thing a thin link drops, so a decoder that has
  /// only luma returns a picture without it rather than nothing.
  final Uint8List? rgb;

  bool get hasColour => rgb != null;
}

class LowRateImageCompressor {
  const LowRateImageCompressor({this.levels = const [12, 24, 48]});

  /// Pyramid widths, coarse first. Heights follow the aspect ratio.
  final List<int> levels;

  static const _cm = LiveContextCompressor();

  /// Grayscale mean-downsample of an interleaved 8-bit image.
  static Uint8List _grayDown(
    Uint8List px,
    int w,
    int h,
    int ch,
    int ow,
    int oh,
  ) {
    final out = Uint8List(ow * oh);
    for (var oy = 0; oy < oh; oy++) {
      final y0 = oy * h ~/ oh, y1 = ((oy + 1) * h ~/ oh).clamp(y0 + 1, h);
      for (var ox = 0; ox < ow; ox++) {
        final x0 = ox * w ~/ ow, x1 = ((ox + 1) * w ~/ ow).clamp(x0 + 1, w);
        var sum = 0, cnt = 0;
        for (var y = y0; y < y1; y++) {
          for (var x = x0; x < x1; x++) {
            final i = (y * w + x) * ch;
            // A single-channel source is already luminance. Reading three
            // channels from it walked off the end of the buffer, which is
            // the kind of defect that only shows up the first time
            // somebody hands this a grayscale photograph.
            sum += ch >= 3 ? (px[i] + px[i + 1] + px[i + 2]) ~/ 3 : px[i];
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
  static Uint8List _upsample(Uint8List src, int sw, int sh, int dw, int dh) {
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
  ///
  /// Colour is not part of this pyramid; see [encodeChroma].

  /// Width of the chroma plane, as a fraction of the coarsest luma level.
  ///
  /// Colour survives brutal subsampling in a way brightness does not, so
  /// the chroma plane is deliberately coarser than the coarsest luma
  /// level rather than matching the finest.
  static const int chromaWidth = 8;

  /// Encode a coarse chroma plane for [px], as a level a decoder applies
  /// on top of whatever luma it managed to receive.
  ///
  /// Two bits per component: four steps of Co and four of Cg is enough to
  /// tell a fire from a flood, which is the decision this layer exists to
  /// support. More precision costs bytes that the luma pyramid spends
  /// better.
  ProgressiveLevel encodeChroma(Uint8List px, int w, int h, int ch) {
    if (ch < 3) {
      throw ArgumentError.value(ch, 'ch', 'colour needs at least 3 channels');
    }
    final cw = chromaWidth.clamp(1, w);
    final chh = (h * cw / w).round().clamp(1, 1 << 12);
    final plane = Uint8List(cw * chh);
    for (var y = 0; y < chh; y++) {
      for (var x = 0; x < cw; x++) {
        // Box-average the source block, so a single loud pixel does not
        // decide the colour of a whole region.
        final x0 = x * w ~/ cw;
        final x1 = ((x + 1) * w ~/ cw).clamp(x0 + 1, w);
        final y0 = y * h ~/ chh;
        final y1 = ((y + 1) * h ~/ chh).clamp(y0 + 1, h);
        var r = 0, g = 0, b = 0, n = 0;
        for (var sy = y0; sy < y1; sy++) {
          for (var sx = x0; sx < x1; sx++) {
            final i = (sy * w + sx) * ch;
            r += px[i];
            g += px[i + 1];
            b += px[i + 2];
            n++;
          }
        }
        r ~/= n;
        g ~/= n;
        b ~/= n;
        final co = (r - b).clamp(-255, 255);
        final cg = (g - (r + b) ~/ 2).clamp(-255, 255);
        plane[y * cw + x] = (_quant2(co) << 2) | _quant2(cg);
      }
    }
    return ProgressiveLevel(
      cw,
      chh,
      _cm.compress(plane),
      LevelCoder.chromaPair,
    );
  }

  /// Map a signed chroma difference onto two bits.
  static int _quant2(int value) => (((value + 256) * 3) ~/ 512).clamp(0, 3);

  /// The centre of the band a two-bit code stands for.
  static int _dequant2(int code) => (code * 512) ~/ 3 - 256 + 85;

  List<ProgressiveLevel> encodeProgressive(Uint8List px, int w, int h, int ch) {
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
          SpatialResidual.paeth(plane, lw, lh, 1),
        ),
        LevelCoder.adaptiveRow: _cm.compress(
          AdaptiveFilter.forward(plane, lw, lh, 1),
        ),
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
    Uint8List? chroma;
    var chromaW = 0, chromaH = 0;
    for (final level in received) {
      final payload = _cm.decompress(level.bytes);
      if (level.coder == LevelCoder.chromaPair) {
        // Colour is applied at the end, over whatever luma arrived, so it
        // is order-independent: a chroma level is just as usable whether
        // it came before or after the refinements it will be painted on.
        chroma = payload;
        chromaW = level.width;
        chromaH = level.height;
        continue;
      }
      final Uint8List plane;
      switch (level.coder) {
        case LevelCoder.fixedPaeth:
          plane = SpatialResidual.unPaeth(
            payload,
            level.width,
            level.height,
            1,
          );
        case LevelCoder.adaptiveRow:
          plane = AdaptiveFilter.inverse(payload, level.width, level.height, 1);
        case LevelCoder.rawResidual:
          plane = payload;
        case LevelCoder.chromaPair:
          // Handled above; unreachable, and stated rather than defaulted.
          continue;
      }
      final Uint8List q;
      if (prevQ == null) {
        q = plane;
      } else {
        final pred = _upsample(prevQ, prevW, prevH, level.width, level.height);
        q = Uint8List(plane.length);
        for (var i = 0; i < plane.length; i++) {
          q[i] = (plane[i] + pred[i]) & 0x0F;
        }
      }
      prevQ = q;
      prevW = level.width;
      prevH = level.height;
    }
    if (prevQ == null) {
      // Chroma with nothing to paint it on. Refused rather than invented:
      // a flat grey field tinted by colour is not a photograph, and
      // returning one would be the same class of mistake as rendering a
      // refinement level as though it were a picture.
      throw ArgumentError('a chroma level needs a luma level');
    }
    final q = prevQ;
    final gray = Uint8List(q.length);
    for (var i = 0; i < q.length; i++) {
      gray[i] = (q[i] << 4) | q[i]; // 4-bit -> 8-bit
    }
    if (chroma == null) {
      // A picture without colour: the ordinary outcome, not a failure.
      // Chroma is the last thing sent and the first thing a thin link
      // drops.
      return DecodedThumbnail(prevW, prevH, gray);
    }
    return DecodedThumbnail(
      prevW,
      prevH,
      gray,
      rgb: _paint(gray, prevW, prevH, chroma, chromaW, chromaH),
    );
  }

  /// Rebuild interleaved RGB from a luma plane and a coarse chroma plane.
  ///
  /// The chroma plane is nearest-sampled up to the luma resolution, which
  /// is the right choice for a plane this coarse: interpolating four
  /// two-bit samples invents gradients that were never measured.
  static Uint8List _paint(
    Uint8List gray,
    int w,
    int h,
    Uint8List chroma,
    int cw,
    int chh,
  ) {
    final rgb = Uint8List(w * h * 3);
    for (var y = 0; y < h; y++) {
      final cy = (y * chh ~/ h).clamp(0, chh - 1);
      for (var x = 0; x < w; x++) {
        final cx = (x * cw ~/ w).clamp(0, cw - 1);
        final packed = chroma[cy * cw + cx];
        final co = _dequant2((packed >> 2) & 0x03);
        final cg = _dequant2(packed & 0x03);
        final luma = gray[y * w + x];

        // The YCoCg inverse, in integers.
        final tmp = luma - (cg >> 1);
        final g = (cg + tmp).clamp(0, 255);
        final b = (tmp - (co >> 1)).clamp(0, 255);
        final r = (b + co).clamp(0, 255);

        final i = (y * w + x) * 3;
        rgb[i] = r;
        rgb[i + 1] = g;
        rgb[i + 2] = b;
      }
    }
    return rgb;
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
      '<path d="',
    );
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
