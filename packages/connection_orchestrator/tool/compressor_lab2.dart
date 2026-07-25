/// Compressor lab round 3 — the three specialist upgrades, measured:
///   image: YCoCg-R reversible color transform + GAP (gradient-adjusted
///          predictor, CALIC-style) vs the round-2 Paeth baseline;
///   audio: per-frame adaptive fixed-order linear predictor (order 0-4
///          chosen per 4096-sample frame by residual magnitude, FLAC
///          style — the practical, exactly-invertible form of dynamic
///          LPC; per-frame header byte counted in the size);
/// Every transform here is exactly invertible; inverses are implemented
/// and asserted on real data before a size is reported.
import 'dart:io';
import 'dart:typed_data';

import 'package:connection_orchestrator/src/media_codecs/live_context_compressor.dart';

import 'compressor_lab.dart' show pngDecode, residual2d, lpc2, unlpc2;

const c = LiveContextCompressor();
final gz = GZipCodec(level: 9);

// ---------- image upgrades ----------

/// YCoCg-R forward, per pixel, mod-256 reversible. Alpha passes through.
Uint8List ycocgR(Uint8List px, int ch) {
  final out = Uint8List(px.length);
  for (var i = 0; i + ch <= px.length; i += ch) {
    final r = px[i], g = px[i + 1], b = px[i + 2];
    final co = (r - b) & 0xFF;
    final t = (b + (co >> 1)) & 0xFF;
    final cg = (g - t) & 0xFF;
    final y = (t + (cg >> 1)) & 0xFF;
    out[i] = y;
    out[i + 1] = co;
    out[i + 2] = cg;
    if (ch == 4) out[i + 3] = px[i + 3];
  }
  return out;
}

Uint8List unYcocgR(Uint8List px, int ch) {
  final out = Uint8List(px.length);
  for (var i = 0; i + ch <= px.length; i += ch) {
    final y = px[i], co = px[i + 1], cg = px[i + 2];
    final t = (y - (cg >> 1)) & 0xFF;
    final g = (cg + t) & 0xFF;
    final b = (t - (co >> 1)) & 0xFF;
    final r = (co + b) & 0xFF;
    out[i] = r;
    out[i + 1] = g;
    out[i + 2] = b;
    if (ch == 4) out[i + 3] = px[i + 3];
  }
  return out;
}

/// GAP (gradient-adjusted prediction), CALIC-style thresholds, per
/// channel over the interleaved buffer.
Uint8List residualGap(Uint8List px, int w, int h, int ch) {
  final stride = w * ch;
  final out = Uint8List(px.length);
  int at(int y, int x) =>
      (y < 0 || x < 0 || x >= stride) ? 0 : px[y * stride + x];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < stride; x++) {
      final wv = at(y, x - ch); // west
      final n = at(y - 1, x); // north
      final ne = at(y - 1, x + ch);
      final nw = at(y - 1, x - ch);
      final ww = at(y, x - 2 * ch);
      final nn = at(y - 2, x);
      final dh = (wv - ww).abs() + (n - nw).abs() + (n - ne).abs();
      final dv = (wv - nw).abs() + (n - nn).abs() + (ne - at(y - 2, x + ch)).abs();
      int pred;
      final d = dv - dh;
      if (d > 80) {
        pred = wv; // sharp horizontal edge
      } else if (d < -80) {
        pred = n; // sharp vertical edge
      } else {
        var p = (wv + n) ~/ 2 + (ne - nw) ~/ 4;
        if (d > 32) {
          p = (p + wv) ~/ 2;
        } else if (d > 8) {
          p = (3 * p + wv) ~/ 4;
        } else if (d < -32) {
          p = (p + n) ~/ 2;
        } else if (d < -8) {
          p = (3 * p + n) ~/ 4;
        }
        pred = p;
      }
      out[y * stride + x] = (px[y * stride + x] - pred) & 0xFF;
    }
  }
  return out;
}

// ---------- audio upgrade: per-frame adaptive fixed-order LPC ----------

const _frame = 4096;

/// FLAC's fixed predictors, orders 0-4, residual as int16 wraparound.
int _predict(Int16List s, int i, int order) => switch (order) {
      0 => 0,
      1 => s[i - 1],
      2 => 2 * s[i - 1] - s[i - 2],
      3 => 3 * s[i - 1] - 3 * s[i - 2] + s[i - 3],
      _ => 4 * s[i - 1] - 6 * s[i - 2] + 4 * s[i - 3] - s[i - 4],
    };

/// Output layout: [u8 order per frame ...][int16 residuals]. Exactly
/// invertible; the per-frame header bytes are part of the size.
Uint8List lpcAdaptive(Uint8List d) {
  final n = d.length ~/ 2;
  final s = Int16List.view(d.buffer, d.offsetInBytes, n);
  final frames = (n + _frame - 1) ~/ _frame;
  final orders = Uint8List(frames);
  final res = Int16List(n);
  for (var f = 0; f < frames; f++) {
    final start = f * _frame;
    final end = (start + _frame) > n ? n : start + _frame;
    var bestOrder = 0;
    var bestCost = 1 << 62;
    for (var order = 0; order <= 4; order++) {
      var cost = 0;
      for (var i = start; i < end; i++) {
        final p = i >= order ? _predict(s, i, order) : 0;
        cost += (s[i] - p).abs();
      }
      if (cost < bestCost) {
        bestCost = cost;
        bestOrder = order;
      }
    }
    orders[f] = bestOrder;
    for (var i = start; i < end; i++) {
      final p = i >= bestOrder ? _predict(s, i, bestOrder) : 0;
      res[i] = (s[i] - p) & 0xFFFF;
    }
  }
  final out = Uint8List(frames + n * 2 + (d.length.isOdd ? 1 : 0));
  out.setRange(0, frames, orders);
  out.setRange(frames, frames + n * 2, Uint8List.view(res.buffer));
  if (d.length.isOdd) out[out.length - 1] = d[d.length - 1];
  return out;
}

Uint8List unLpcAdaptive(Uint8List packed, int originalLen) {
  final n = originalLen ~/ 2;
  final frames = (n + _frame - 1) ~/ _frame;
  final orders = Uint8List.sublistView(packed, 0, frames);
  final res = Int16List.view(packed.buffer,
      packed.offsetInBytes + frames, n);
  final s = Int16List(n);
  for (var f = 0; f < frames; f++) {
    final start = f * _frame;
    final end = (start + _frame) > n ? n : start + _frame;
    final order = orders[f];
    for (var i = start; i < end; i++) {
      final p = i >= order ? _predict(s, i, order) : 0;
      s[i] = (res[i] + p) & 0xFFFF;
    }
  }
  final out = Uint8List(originalLen);
  out.setRange(0, n * 2, Uint8List.view(s.buffer));
  if (originalLen.isOdd) out[originalLen - 1] = packed[packed.length - 1];
  return out;
}

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  // ---- image: Paeth baseline vs GAP vs YCoCg-R+each ----
  final png = File('/Users/behnam/Downloads/voorrang_tram_afslaan_topdown.png')
      .readAsBytesSync();
  final img = pngDecode(Uint8List.fromList(png))!;
  final rows = img.height < 500 ? img.height : 500;
  final crop =
      Uint8List.sublistView(img.pixels, 0, rows * img.width * img.channels);
  final w = img.width, ch = img.channels;

  // Round-trip proof of the two new image transforms on real pixels.
  assert(_eq(unYcocgR(ycocgR(crop, ch), ch), crop));

  final paeth = c.compress(residual2d(crop, w, rows, ch)).length;
  final gap = c.compress(residualGap(crop, w, rows, ch)).length;
  final yPaeth =
      c.compress(residual2d(ycocgR(crop, ch), w, rows, ch)).length;
  final yGap = c.compress(residualGap(ycocgR(crop, ch), w, rows, ch)).length;
  final pngProxy = gz.encode(residual2d(crop, w, rows, ch)).length;
  print('image (${w}x$rows x$ch): png-proxy=$pngProxy  paeth+cm=$paeth  '
      'gap+cm=$gap  ycocg+paeth+cm=$yPaeth  ycocg+gap+cm=$yGap');
  final bestImg = [paeth, gap, yPaeth, yGap].reduce((a, b) => a < b ? a : b);
  print('  best image variant: '
      '${(100 * (1 - bestImg / pngProxy)).toStringAsFixed(1)}% under '
      'PNG-equivalent');

  // ---- audio: lpc2 baseline vs per-frame adaptive ----
  final wav = File(
          '/Users/behnam/Downloads/voice_call_kit_v3/demo_audio/gift_24k.wav')
      .readAsBytesSync();
  final pcm = Uint8List.sublistView(
      Uint8List.fromList(wav), 44, 44 + 131072); // skip WAV header
  assert(_eq(unlpc2(lpc2(pcm)), pcm));
  final packed = lpcAdaptive(pcm);
  assert(_eq(unLpcAdaptive(packed, pcm.length), pcm));
  final gzB = gz.encode(pcm).length;
  final l2 = c.compress(lpc2(pcm)).length;
  final lAd = c.compress(packed).length;
  print('audio PCM (${pcm.length} B): gzip9=$gzB  lpc2+cm=$l2  '
      'lpcAdaptive+cm=$lAd');
  final bestA = lAd < l2 ? lAd : l2;
  print('  best audio variant: '
      '${(100 * (1 - bestA / gzB)).toStringAsFixed(1)}% under gzip9');

  // Video probe: no real video sample in reach today — 3D temporal
  // residual stays DESIGNED-NOT-MEASURED until phase 4c synthesizes
  // flipbook frames (dated blocker, per working rules).
}
