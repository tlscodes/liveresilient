/// Compressor lab round 4 — the quantum-leap probes.
///
/// AUDIO — true high-order LPC, exactly invertible:
///   per 4096-sample frame: autocorrelation -> Levinson-Durbin up to
///   order 12 -> coefficients QUANTIZED to 12-bit fixed point (the
///   decoder uses the same integers, so integer prediction is bit-exact)
///   -> int16 residuals. Frame header (order + quantized coeffs) is
///   counted in the compressed size. Falls back per frame to the best
///   fixed predictor when that is cheaper (order chosen by cost).
///
/// IMAGE — screenshot-specialist paths on top of round-3's winner
///   (YCoCg-R + Paeth): row-delta variants that preserve the long zero
///   runs of flat UI regions, which the CM match model then eats.
///
/// Every transform asserted invertible on the real data before sizing.
import 'dart:io';
import 'dart:typed_data';

import 'package:connection_orchestrator/src/media_codecs/live_context_compressor.dart';

import 'compressor_lab.dart' show pngDecode, residual2d;
import 'compressor_lab2.dart' show ycocgR, unYcocgR, lpcAdaptive;

const c = LiveContextCompressor();
final gz = GZipCodec(level: 9);

// ---------------- true quantized LPC ----------------

const _frame = 4096;
const _qBits = 12; // coefficient fixed-point precision
const int _maxOrder = 12;

/// Levinson-Durbin on autocorrelation r[0..order], returns LPC coeffs.
List<double> _levinson(List<double> r, int order) {
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

/// Per-frame layout: u8 order · order*int16 quantized coeffs · residuals
/// appended in one int16 block at the end (aligned per frame count).
({Uint8List packed, int headerBytes}) lpcQuantized(Uint8List d) {
  final n = d.length ~/ 2;
  final s = Int16List.view(d.buffer, d.offsetInBytes, n);
  final frames = (n + _frame - 1) ~/ _frame;
  final header = BytesBuilder();
  final res = Int16List(n);
  for (var f = 0; f < frames; f++) {
    final start = f * _frame;
    final end = (start + _frame) > n ? n : start + _frame;
    final len = end - start;
    // autocorrelation (windowless, double)
    final r = List<double>.filled(_maxOrder + 1, 0);
    for (var lag = 0; lag <= _maxOrder; lag++) {
      var acc = 0.0;
      for (var i = start + lag; i < end; i++) {
        acc += s[i].toDouble() * s[i - lag];
      }
      r[lag] = acc;
    }
    // pick best order by trying quantized prediction cost
    var bestOrder = 0;
    Int16List bestQ = Int16List(0);
    var bestCost = 1 << 62;
    // order 0 baseline = raw
    {
      var cost = 0;
      for (var i = start; i < end; i++) {
        cost += s[i].abs();
      }
      bestCost = cost;
    }
    if (r[0] != 0 && len > _maxOrder * 2) {
      for (final order in [2, 4, 8, _maxOrder]) {
        final a = _levinson(r, order);
        final q = Int16List(order);
        for (var j = 1; j <= order; j++) {
          q[j - 1] = (-a[j] * (1 << _qBits)).round().clamp(-32768, 32767);
        }
        var cost = order * 2 * 4; // rough header penalty in |res| units
        for (var i = start; i < end; i++) {
          var acc = 0;
          for (var j = 1; j <= order; j++) {
            acc += i - j >= start
                ? q[j - 1] * s[i - j]
                : 0; // frame-local warmup: first samples predicted 0
          }
          final pred = acc >> _qBits;
          cost += (s[i] - pred).abs();
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
  return (packed: out, headerBytes: head.length);
}

Uint8List unLpcQuantized(Uint8List packed, int originalLen) {
  final n = originalLen ~/ 2;
  final headLen = ByteData.sublistView(packed).getUint32(0);
  final head = Uint8List.sublistView(packed, 4, 4 + headLen);
  final res = Int16List.view(
    packed.buffer,
    packed.offsetInBytes + 4 + headLen,
    n,
  );
  final s = Int16List(n);
  final frames = (n + _frame - 1) ~/ _frame;
  var hp = 0;
  for (var f = 0; f < frames; f++) {
    final start = f * _frame;
    final end = (start + _frame) > n ? n : start + _frame;
    final order = head[hp++];
    final q = Int16List(order);
    for (var j = 0; j < order; j++) {
      q[j] = ByteData.sublistView(head, hp, hp + 2).getInt16(0, Endian.little);
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

// ---------------- screenshot image paths ----------------

/// Row delta: pixel minus the pixel directly above (zero row for y=0).
/// Flat vertical regions become long zero runs. Exactly invertible.
Uint8List rowDelta(Uint8List px, int w, int h, int ch) {
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

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  // ---- audio ----
  final wav = File(
    '$REPO/demo_audio/gift_24k.wav',
  ).readAsBytesSync();
  final pcm = Uint8List.sublistView(Uint8List.fromList(wav), 44, 44 + 131072);
  final q = lpcQuantized(pcm);
  assert(
    _eq(unLpcQuantized(q.packed, pcm.length), pcm),
    'quantized LPC must round-trip bit-exact',
  );
  final gzB = gz.encode(pcm).length;
  final ad = c.compress(lpcAdaptive(pcm)).length;
  final lq = c.compress(q.packed).length;
  print(
    'audio (131072 B): gzip9=$gzB  lpcAdaptive+cm=$ad  '
    'lpcQ12+cm=$lq (headers ${q.headerBytes} B included)',
  );
  print(
    '  audio best: ${(100 * (1 - (lq < ad ? lq : ad) / gzB)).toStringAsFixed(1)}% under gzip9',
  );

  // ---- image ----
  final png = File(
    '$HOME/Downloads/voorrang_tram_afslaan_topdown.png',
  ).readAsBytesSync();
  final img = pngDecode(Uint8List.fromList(png))!;
  final rows = img.height < 500 ? img.height : 500;
  final crop = Uint8List.sublistView(
    img.pixels,
    0,
    rows * img.width * img.channels,
  );
  final w = img.width, ch = img.channels;
  final y = ycocgR(crop, ch);
  assert(_eq(unYcocgR(y, ch), crop));
  final pngProxy = gz.encode(residual2d(crop, w, rows, ch)).length;
  final base = c.compress(residual2d(y, w, rows, ch)).length; // round-3 best
  final rd = c.compress(rowDelta(y, w, rows, ch)).length;
  print(
    'image: png-proxy=$pngProxy  ycocg+paeth+cm=$base  '
    'ycocg+rowdelta+cm=$rd',
  );
  final bestI = rd < base ? rd : base;
  print(
    '  image best: ${(100 * (1 - bestI / pngProxy)).toStringAsFixed(1)}% under PNG-equivalent',
  );
}
