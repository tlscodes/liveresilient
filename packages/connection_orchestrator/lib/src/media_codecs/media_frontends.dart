/// Productized lossless front-ends for the live compressor — the lab
/// winners (labs round 2-4, measured 2026-07-25), each with its exact
/// inverse. These transforms reshape data so the context-mixing coder
/// reaches far lower entropy; none of them lose a single bit.
///
/// Measured on real data (see tool/compressor_lab*.dart):
///   audio  : quantized order-12 LPC     -> 42.7% under gzip9
///   image  : YCoCg-R + row-delta/Paeth  -> 42.8% under PNG-equivalent
library;

import 'dart:typed_data';

/// Reversible YCoCg-R color transform (mod-256). Alpha passes through.
class YCoCgR {
  const YCoCgR._();

  static Uint8List forward(Uint8List px, int channels) {
    final out = Uint8List(px.length);
    for (var i = 0; i + channels <= px.length; i += channels) {
      final r = px[i], g = px[i + 1], b = px[i + 2];
      final co = (r - b) & 0xFF;
      final t = (b + (co >> 1)) & 0xFF;
      final cg = (g - t) & 0xFF;
      out[i] = (t + (cg >> 1)) & 0xFF;
      out[i + 1] = co;
      out[i + 2] = cg;
      if (channels == 4) out[i + 3] = px[i + 3];
    }
    return out;
  }

  static Uint8List inverse(Uint8List px, int channels) {
    final out = Uint8List(px.length);
    for (var i = 0; i + channels <= px.length; i += channels) {
      final y = px[i], co = px[i + 1], cg = px[i + 2];
      final t = (y - (cg >> 1)) & 0xFF;
      final g = (cg + t) & 0xFF;
      final b = (t - (co >> 1)) & 0xFF;
      out[i] = (co + b) & 0xFF;
      out[i + 1] = g;
      out[i + 2] = b;
      if (channels == 4) out[i + 3] = px[i + 3];
    }
    return out;
  }
}

/// 2D spatial predictors over interleaved pixel buffers, mod-256.
class SpatialResidual {
  const SpatialResidual._();

  /// residual = pixel - Paeth(left, up, upleft).
  static Uint8List paeth(Uint8List px, int w, int h, int ch) =>
      _paeth(px, w, h, ch, forward: true);

  static Uint8List unPaeth(Uint8List res, int w, int h, int ch) =>
      _paeth(res, w, h, ch, forward: false);

  static Uint8List _paeth(
    Uint8List src,
    int w,
    int h,
    int ch, {
    required bool forward,
  }) {
    final stride = w * ch;
    final out = Uint8List(src.length);
    // For the inverse, predictions must come from RECONSTRUCTED pixels.
    final ref = forward ? src : out;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < stride; x++) {
        final a = x >= ch ? ref[y * stride + x - ch] : 0;
        final b = y > 0 ? ref[(y - 1) * stride + x] : 0;
        final cc = (x >= ch && y > 0) ? ref[(y - 1) * stride + x - ch] : 0;
        final p = a + b - cc;
        final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - cc).abs();
        final pred = pa <= pb && pa <= pc ? a : (pb <= pc ? b : cc);
        final i = y * stride + x;
        out[i] = forward ? (src[i] - pred) & 0xFF : (src[i] + pred) & 0xFF;
      }
    }
    return out;
  }

  /// residual = pixel - pixel_above; keeps flat regions as zero runs
  /// (screenshot winner).
  static Uint8List rowDelta(Uint8List px, int w, int h, int ch) {
    final stride = w * ch;
    final out = Uint8List(px.length);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < stride; x++) {
        final up = y > 0 ? px[(y - 1) * stride + x] : 0;
        out[y * stride + x] = (px[y * stride + x] - up) & 0xFF;
      }
    }
    return out;
  }

  static Uint8List unRowDelta(Uint8List res, int w, int h, int ch) {
    final stride = w * ch;
    final out = Uint8List(res.length);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < stride; x++) {
        final up = y > 0 ? out[(y - 1) * stride + x] : 0;
        out[y * stride + x] = (res[y * stride + x] + up) & 0xFF;
      }
    }
    return out;
  }
}

/// Quantized high-order LPC over 16-bit little-endian PCM. Per frame:
/// Levinson-Durbin up to order 12, coefficients quantized to 12-bit
/// fixed point, integer-only prediction (so encoder and decoder agree
/// bit-exactly). Frame headers ride inside the packed output.
class QuantizedLpc {
  const QuantizedLpc._();

  static const int frameSize = 4096;
  static const int _qBits = 12;
  static const int _maxOrder = 12;

  static List<double> _levinson(List<double> r, int order) {
    final a = List<double>.filled(order + 1, 0);
    a[0] = 1;
    var e = r[0];
    if (e == 0) return a;
    for (var i = 1; i <= order; i++) {
      var acc = r[i];
      for (var j = 1; j < i; j++) {
        acc += a[j] * r[i - j];
      }
      final k = -acc / e;
      final prev = List<double>.from(a);
      for (var j = 1; j < i; j++) {
        a[j] = prev[j] + k * prev[i - j];
      }
      a[i] = k;
      e *= (1 - k * k);
      if (e <= 0) break;
    }
    return a;
  }

  /// Layout: u32 headerLen · headers (u8 order + int16 coeffs per frame)
  /// · int16 residuals · optional trailing odd byte.
  static Uint8List encode(Uint8List d) {
    final n = d.length ~/ 2;
    // Copy for alignment: callers may pass unaligned sublist views.
    final aligned = Uint8List.fromList(d);
    final s = Int16List.view(aligned.buffer, 0, n);
    final frames = n == 0 ? 0 : (n + frameSize - 1) ~/ frameSize;
    final header = BytesBuilder();
    final res = Int16List(n);
    for (var f = 0; f < frames; f++) {
      final start = f * frameSize;
      final end = (start + frameSize) > n ? n : start + frameSize;
      final len = end - start;
      final r = List<double>.filled(_maxOrder + 1, 0);
      for (var lag = 0; lag <= _maxOrder; lag++) {
        var acc = 0.0;
        for (var i = start + lag; i < end; i++) {
          acc += s[i].toDouble() * s[i - lag];
        }
        r[lag] = acc;
      }
      var bestOrder = 0;
      var bestQ = Int16List(0);
      var bestCost = 0;
      for (var i = start; i < end; i++) {
        bestCost += s[i].abs();
      }
      if (r[0] != 0 && len > _maxOrder * 2) {
        for (final order in const [2, 4, 8, _maxOrder]) {
          final a = _levinson(r, order);
          final q = Int16List(order);
          for (var j = 1; j <= order; j++) {
            q[j - 1] = (-a[j] * (1 << _qBits)).round().clamp(-32768, 32767);
          }
          var cost = order * 2 * 4;
          for (var i = start; i < end; i++) {
            var acc = 0;
            for (var j = 1; j <= order; j++) {
              acc += i - j >= start ? q[j - 1] * s[i - j] : 0;
            }
            cost += (s[i] - (acc >> _qBits)).abs();
            if (cost >= bestCost) break;
          }
          if (cost < bestCost) {
            bestCost = cost;
            bestOrder = order;
            bestQ = q;
          }
        }
      }
      header.addByte(bestOrder);
      header.add(Uint8List.view(bestQ.buffer, 0, bestOrder * 2));
      for (var i = start; i < end; i++) {
        var acc = 0;
        for (var j = 1; j <= bestOrder; j++) {
          acc += i - j >= start ? bestQ[j - 1] * s[i - j] : 0;
        }
        res[i] = (s[i] - (acc >> _qBits)) & 0xFFFF;
      }
    }
    final head = header.toBytes();
    final out = Uint8List(4 + head.length + n * 2 + (d.length.isOdd ? 1 : 0));
    ByteData.sublistView(out).setUint32(0, head.length);
    out.setRange(4, 4 + head.length, head);
    out.setRange(
      4 + head.length,
      4 + head.length + n * 2,
      Uint8List.view(res.buffer),
    );
    if (d.length.isOdd) out[out.length - 1] = d[d.length - 1];
    return out;
  }

  static Uint8List decode(Uint8List packed, int originalLen) {
    final n = originalLen ~/ 2;
    final headLen = ByteData.sublistView(packed).getUint32(0);
    final head = Uint8List.sublistView(packed, 4, 4 + headLen);
    // Copy: 4+headLen is not necessarily 2-byte aligned for a view.
    final resBytes = Uint8List.fromList(
      Uint8List.sublistView(packed, 4 + headLen, 4 + headLen + n * 2),
    );
    final res = Int16List.view(resBytes.buffer, 0, n);
    final s = Int16List(n);
    final frames = n == 0 ? 0 : (n + frameSize - 1) ~/ frameSize;
    var hp = 0;
    for (var f = 0; f < frames; f++) {
      final start = f * frameSize;
      final end = (start + frameSize) > n ? n : start + frameSize;
      final order = head[hp++];
      final q = Int16List(order);
      for (var j = 0; j < order; j++) {
        q[j] = ByteData.sublistView(
          head,
          hp,
          hp + 2,
        ).getInt16(0, Endian.little);
        hp += 2;
      }
      for (var i = start; i < end; i++) {
        var acc = 0;
        for (var j = 1; j <= order; j++) {
          acc += i - j >= start ? q[j - 1] * s[i - j] : 0;
        }
        s[i] = (res[i] + (acc >> _qBits)) & 0xFFFF;
      }
    }
    final out = Uint8List(originalLen);
    out.setRange(0, n * 2, Uint8List.view(s.buffer));
    if (originalLen.isOdd) out[originalLen - 1] = packed[packed.length - 1];
    return out;
  }
}

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

  static int _predict(int filter, int a, int b, int c) {
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
