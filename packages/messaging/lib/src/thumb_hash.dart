import 'dart:math' as math;
import 'dart:typed_data';

/// Compact DCT thumbnail hash — the instant placeholder rung of the staged
/// photo pipeline (RIG_GUIDE §0.2 item 1b): ~30 bytes that ride INSIDE the
/// photo announcement itself, so the bubble renders a blurred preview the
/// moment the chat message lands — even under 60% loss, where the binary
/// stages may still be minutes away.
///
/// A ThumbHash-family codec: luma plus two chroma-difference channels, each
/// reduced to a few DCT coefficients and quantized. Both codec ends live in
/// this file; the wire format is project-internal, versioned, and pinned by
/// round-trip tests. It is NOT asserted byte-compatible with external
/// thumbhash libraries.
///
/// Layout (version 1):
///   [0]      version
///   [1] [2]  lx, ly — luma coefficient grid (also encodes rough aspect)
///   [3]      luma DC        (unsigned, 0..1)
///   [4] [5]  P, Q chroma DC (signed, -1..1)
///   [6] [7]  luma AC scale, chroma AC scale (unsigned, 0..2)
///   then     (lx*ly - 1) luma AC nibbles, packed two per byte
///   then     8 + 8 chroma AC nibbles (3x3 grid minus DC, P then Q)
class ThumbHash {
  static const int version = 1;
  static const int _chromaN = 3;

  /// Encodes [rgba] (w*h*4 bytes) into the compact hash. The caller
  /// downsamples first — anything <= 128 px per side is accepted; the app
  /// feeds ~64 px. Alpha is ignored (photo pipeline; opaque by contract).
  static Uint8List encodeRgba(int w, int h, Uint8List rgba) {
    if (w <= 0 || h <= 0 || w > 128 || h > 128) {
      throw ArgumentError('thumbhash input must be 1..128 px per side');
    }
    if (rgba.length != w * h * 4) {
      throw ArgumentError('rgba length ${rgba.length} != ${w * h * 4}');
    }
    final n = w * h;
    final l = Float64List(n), p = Float64List(n), q = Float64List(n);
    for (var i = 0; i < n; i++) {
      final r = rgba[i * 4] / 255.0;
      final g = rgba[i * 4 + 1] / 255.0;
      final b = rgba[i * 4 + 2] / 255.0;
      l[i] = (r + g + b) / 3.0;
      p[i] = (r + g) / 2.0 - b;
      q[i] = r - g;
    }
    final longSide = math.max(w, h);
    final lx = math.max(1, (6 * w / longSide).round());
    final ly = math.max(1, (6 * h / longSide).round());

    final lCoef = _dct(l, w, h, lx, ly);
    final pCoef = _dct(p, w, h, _chromaN, _chromaN);
    final qCoef = _dct(q, w, h, _chromaN, _chromaN);

    double acMax(List<double> c) {
      var m = 0.0;
      for (var i = 1; i < c.length; i++) {
        m = math.max(m, c[i].abs());
      }
      return m;
    }

    final lScale = acMax(lCoef);
    final pqScale = math.max(acMax(pCoef), acMax(qCoef));

    final out = BytesBuilder();
    out.addByte(version);
    out.addByte(lx);
    out.addByte(ly);
    // DC terms carry factor 2 from the forward transform: /2 restores range.
    out.addByte(_u8(lCoef[0] / 2.0, 0, 1));
    out.addByte(_u8(pCoef[0] / 2.0, -1, 1));
    out.addByte(_u8(qCoef[0] / 2.0, -1, 1));
    out.addByte(_u8(lScale, 0, 2));
    out.addByte(_u8(pqScale, 0, 2));

    final nibbles = <int>[];
    void addAcs(List<double> c, double scale) {
      for (var i = 1; i < c.length; i++) {
        final v = scale <= 0 ? 0.0 : (c[i] / scale);
        nibbles.add(((v * 7.5) + 7.5).round().clamp(0, 15));
      }
    }

    addAcs(lCoef, lScale);
    addAcs(pCoef, pqScale);
    addAcs(qCoef, pqScale);
    for (var i = 0; i < nibbles.length; i += 2) {
      final hi = nibbles[i];
      final lo = i + 1 < nibbles.length ? nibbles[i + 1] : 0;
      out.addByte((hi << 4) | lo);
    }
    return out.toBytes();
  }

  /// Decodes a hash into (w, h, rgba) at roughly [longSidePx] on the long
  /// side, aspect recovered from the stored coefficient grid.
  static ThumbHashImage decodeToRgba(Uint8List hash, {int longSidePx = 32}) {
    if (hash.length < 8 || hash[0] != version) {
      throw ArgumentError('unsupported thumbhash (len=${hash.length})');
    }
    final lx = hash[1], ly = hash[2];
    if (lx < 1 || ly < 1 || lx > 8 || ly > 8) {
      throw ArgumentError('corrupt thumbhash grid $lx x $ly');
    }
    final lDc = _fromU8(hash[3], 0, 1) * 2.0;
    final pDc = _fromU8(hash[4], -1, 1) * 2.0;
    final qDc = _fromU8(hash[5], -1, 1) * 2.0;
    final lScale = _fromU8(hash[6], 0, 2);
    final pqScale = _fromU8(hash[7], 0, 2);

    final lAcN = lx * ly - 1;
    const cAcN = _chromaN * _chromaN - 1;
    final nibbles = <int>[];
    for (var i = 8; i < hash.length; i++) {
      nibbles.add(hash[i] >> 4);
      nibbles.add(hash[i] & 15);
    }
    if (nibbles.length < lAcN + 2 * cAcN) {
      throw ArgumentError('truncated thumbhash');
    }
    List<double> unpack(int offset, int count, double scale) {
      final c = List<double>.filled(count + 1, 0);
      for (var i = 0; i < count; i++) {
        c[i + 1] = ((nibbles[offset + i] - 7.5) / 7.5) * scale;
      }
      return c;
    }

    final lCoef = unpack(0, lAcN, lScale)..[0] = lDc;
    final pCoef = unpack(lAcN, cAcN, pqScale)..[0] = pDc;
    final qCoef = unpack(lAcN + cAcN, cAcN, pqScale)..[0] = qDc;

    final aspect = lx / ly;
    final w = aspect >= 1
        ? longSidePx
        : math.max(1, (longSidePx * aspect).round());
    final h = aspect >= 1
        ? math.max(1, (longSidePx / aspect).round())
        : longSidePx;

    final rgba = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final lv = _idctAt(lCoef, lx, ly, x, y, w, h);
        final pv = _idctAt(pCoef, _chromaN, _chromaN, x, y, w, h);
        final qv = _idctAt(qCoef, _chromaN, _chromaN, x, y, w, h);
        // Inverse of l=(r+g+b)/3, p=(r+g)/2-b, q=r-g.
        final b = lv - 2.0 * pv / 3.0;
        final r = lv + pv / 3.0 + qv / 2.0;
        final g = lv + pv / 3.0 - qv / 2.0;
        final o = (y * w + x) * 4;
        rgba[o] = _px(r);
        rgba[o + 1] = _px(g);
        rgba[o + 2] = _px(b);
        rgba[o + 3] = 255;
      }
    }
    return ThumbHashImage(w, h, rgba);
  }

  /// Forward DCT over the [nx]x[ny] lowest-frequency grid, row-major
  /// (cy*nx+cx). Uniform normalization 2/(w*h); the reconstruction factor
  /// per term is 2^(nonzeroIndexCount - 1) — see [_idctAt].
  static List<double> _dct(Float64List ch, int w, int h, int nx, int ny) {
    final out = List<double>.filled(nx * ny, 0);
    for (var cy = 0; cy < ny; cy++) {
      for (var cx = 0; cx < nx; cx++) {
        var sum = 0.0;
        for (var y = 0; y < h; y++) {
          final fy = math.cos(math.pi * cy * (y + 0.5) / h);
          for (var x = 0; x < w; x++) {
            sum += ch[y * w + x] * fy * math.cos(math.pi * cx * (x + 0.5) / w);
          }
        }
        out[cy * nx + cx] = 2.0 * sum / (w * h);
      }
    }
    return out;
  }

  static double _idctAt(
    List<double> coef,
    int nx,
    int ny,
    int x,
    int y,
    int w,
    int h,
  ) {
    var v = 0.0;
    for (var cy = 0; cy < ny; cy++) {
      final fy = math.cos(math.pi * cy * (y + 0.5) / h);
      for (var cx = 0; cx < nx; cx++) {
        final nz = (cx > 0 ? 1 : 0) + (cy > 0 ? 1 : 0);
        v +=
            coef[cy * nx + cx] *
            fy *
            math.cos(math.pi * cx * (x + 0.5) / w) *
            math.pow(2.0, nz - 1);
      }
    }
    return v;
  }

  static int _u8(double v, double lo, double hi) =>
      (((v - lo) / (hi - lo)) * 255.0).round().clamp(0, 255);

  static double _fromU8(int b, double lo, double hi) =>
      lo + (b / 255.0) * (hi - lo);

  static int _px(double v) => (v * 255.0).round().clamp(0, 255);
}

/// A decoded placeholder image: raw RGBA suitable for direct rasterization.
class ThumbHashImage {
  final int width;
  final int height;
  final Uint8List rgba;
  ThumbHashImage(this.width, this.height, this.rgba);
}
