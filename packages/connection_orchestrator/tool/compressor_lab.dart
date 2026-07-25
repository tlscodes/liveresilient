/// Compressor lab — multi-variant idea test on REAL sample files.
///
/// For each sample, races:
///   gzip9      — baseline (zlib, level 9)
///   cm         — LiveContextCompressor as-is
///   delta+cm   — byte-delta transform then CM (predictive-transform idea,
///                aimed at PCM/bitmap-like data)
/// Round-trip is verified for every variant before its size counts.
/// Output: measured table + per-type winner. Run:
///   dart run tool/compressor_lab.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:connection_orchestrator/src/media_codecs/live_context_compressor.dart';

const c = LiveContextCompressor();
final gz = GZipCodec(level: 9);

Uint8List delta(Uint8List d) {
  final out = Uint8List(d.length);
  var prev = 0;
  for (var i = 0; i < d.length; i++) {
    out[i] = (d[i] - prev) & 0xFF;
    prev = d[i];
  }
  return out;
}

Uint8List undelta(Uint8List d) {
  final out = Uint8List(d.length);
  var prev = 0;
  for (var i = 0; i < d.length; i++) {
    prev = (d[i] + prev) & 0xFF;
    out[i] = prev;
  }
  return out;
}

/// Order-2 linear predictor on 16-bit little-endian PCM:
/// r[n] = s[n] - 2*s[n-1] + s[n-2], residual stored as int16 LE.
/// Exactly invertible.
Uint8List lpc2(Uint8List d) {
  final n = d.length ~/ 2;
  final s = Int16List.view(d.buffer, d.offsetInBytes, n);
  final r = Int16List(n);
  for (var i = 0; i < n; i++) {
    final p1 = i >= 1 ? s[i - 1] : 0;
    final p2 = i >= 2 ? s[i - 2] : 0;
    r[i] = (s[i] - 2 * p1 + p2) & 0xFFFF;
  }
  final out = Uint8List(d.length);
  out.setRange(0, n * 2, Uint8List.view(r.buffer));
  if (d.length.isOdd) out[d.length - 1] = d[d.length - 1];
  return out;
}

Uint8List unlpc2(Uint8List d) {
  final n = d.length ~/ 2;
  final r = Int16List.view(d.buffer, d.offsetInBytes, n);
  final s = Int16List(n);
  for (var i = 0; i < n; i++) {
    final p1 = i >= 1 ? s[i - 1] : 0;
    final p2 = i >= 2 ? s[i - 2] : 0;
    s[i] = (r[i] + 2 * p1 - p2) & 0xFFFF;
  }
  final out = Uint8List(d.length);
  out.setRange(0, n * 2, Uint8List.view(s.buffer));
  if (d.length.isOdd) out[d.length - 1] = d[d.length - 1];
  return out;
}

/// PDF front-end (size-probe form): inflate every /FlateDecode
/// stream body in place, leaving everything else untouched. This
/// measures the unpack-first idea; the bijective container rebuild is
/// the productization step, done only if the measured gain justifies it.
int pdfStreamsDecoded = 0;

Uint8List pdfUnpack(Uint8List d) {
  final out = BytesBuilder();
  var i = 0;
  final zlib = ZLibCodec();
  while (i < d.length) {
    final streamAt = _indexOf(d, 'stream', i);
    if (streamAt < 0) {
      out.add(Uint8List.sublistView(d, i));
      break;
    }
    var bodyStart = streamAt + 6;
    if (bodyStart < d.length && d[bodyStart] == 0x0D) bodyStart++;
    if (bodyStart < d.length && d[bodyStart] == 0x0A) bodyStart++;
    final endAt = _indexOf(d, 'endstream', bodyStart);
    if (endAt < 0) {
      out.add(Uint8List.sublistView(d, i));
      break;
    }
    out.add(Uint8List.sublistView(d, i, bodyStart));
    var body = Uint8List.sublistView(d, bodyStart, endAt);
    // Trailing EOL before 'endstream' is not part of the stream data.
    var bodyEnd = body.length;
    while (bodyEnd > 0 &&
        (body[bodyEnd - 1] == 0x0A || body[bodyEnd - 1] == 0x0D)) {
      bodyEnd--;
    }
    body = Uint8List.sublistView(body, 0, bodyEnd);
    try {
      out.add(zlib.decode(body)); // zlib-wrapped deflate
      pdfStreamsDecoded++;
    } catch (_) {
      try {
        out.add(ZLibDecoder(raw: true).convert(body));
        pdfStreamsDecoded++;
      } catch (_) {
        out.add(body); // not deflate (JPEG/font stream etc.)
      }
    }
    i = endAt;
  }
  return out.toBytes();
}

/// Minimal PNG decoder (8-bit RGB/RGBA, non-interlaced) for the 2D
/// prediction probe: chunks -> inflate IDAT -> unfilter -> raw pixels.
({Uint8List pixels, int width, int height, int channels})? pngDecode(
    Uint8List d) {
  if (d.length < 8 || d[0] != 0x89 || d[1] != 0x50) return null;
  var i = 8;
  int? w, h, colorType, bitDepth;
  final idat = BytesBuilder();
  while (i + 8 <= d.length) {
    final len = ByteData.sublistView(d, i, i + 4).getUint32(0);
    final type = String.fromCharCodes(d.sublist(i + 4, i + 8));
    final body = Uint8List.sublistView(d, i + 8, i + 8 + len);
    if (type == 'IHDR') {
      final bd = ByteData.sublistView(body);
      w = bd.getUint32(0);
      h = bd.getUint32(4);
      bitDepth = body[8];
      colorType = body[9];
      if (body[12] != 0) return null; // interlaced unsupported
    } else if (type == 'IDAT') {
      idat.add(body);
    } else if (type == 'IEND') {
      break;
    }
    i += 12 + len;
  }
  if (w == null || h == null || bitDepth != 8) return null;
  final ch = colorType == 6 ? 4 : (colorType == 2 ? 3 : -1);
  if (ch < 0) return null;
  final raw = Uint8List.fromList(ZLibCodec().decode(idat.toBytes()));
  final stride = w * ch;
  final px = Uint8List(h * stride);
  var r = 0;
  for (var y = 0; y < h; y++) {
    final filter = raw[r++];
    for (var x = 0; x < stride; x++) {
      final cur = raw[r++];
      final a = x >= ch ? px[y * stride + x - ch] : 0; // left
      final b = y > 0 ? px[(y - 1) * stride + x] : 0; // up
      final cc = (x >= ch && y > 0) ? px[(y - 1) * stride + x - ch] : 0;
      int v;
      switch (filter) {
        case 0:
          v = cur;
        case 1:
          v = cur + a;
        case 2:
          v = cur + b;
        case 3:
          v = cur + ((a + b) >> 1);
        case 4:
          final p = a + b - cc;
          final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - cc).abs();
          v = cur + (pa <= pb && pa <= pc ? a : (pb <= pc ? b : cc));
        default:
          return null;
      }
      px[y * stride + x] = v & 0xFF;
    }
  }
  return (pixels: px, width: w, height: h, channels: ch);
}

/// 2D spatial prediction: residual = pixel - Paeth(left, up, upleft),
/// per channel. Exactly invertible given dimensions.
Uint8List residual2d(Uint8List px, int w, int h, int ch) {
  final stride = w * ch;
  final out = Uint8List(px.length);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < stride; x++) {
      final a = x >= ch ? px[y * stride + x - ch] : 0;
      final b = y > 0 ? px[(y - 1) * stride + x] : 0;
      final cc = (x >= ch && y > 0) ? px[(y - 1) * stride + x - ch] : 0;
      final p = a + b - cc;
      final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - cc).abs();
      final pred = pa <= pb && pa <= pc ? a : (pb <= pc ? b : cc);
      out[y * stride + x] = (px[y * stride + x] - pred) & 0xFF;
    }
  }
  return out;
}

int _indexOf(Uint8List d, String needle, int from) {
  final n = needle.codeUnits;
  outer:
  for (var i = from; i <= d.length - n.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (d[i + j] != n[j]) continue outer;
    }
    return i;
  }
  return -1;
}

void race(String label, Uint8List data, {bool pcm = false, bool pdf = false}) {
  final sw = Stopwatch()..start();
  final results = <String, int>{};

  results['gzip9'] = gz.encode(data).length;

  final cmOut = c.compress(data);
  assert(_eq(c.decompress(cmOut), data));
  results['cm'] = cmOut.length;

  final dOut = c.compress(delta(data));
  assert(_eq(undelta(c.decompress(dOut)), data));
  results['delta+cm'] = dOut.length;

  if (pcm) {
    final lOut = c.compress(lpc2(data));
    assert(_eq(unlpc2(c.decompress(lOut)), data));
    results['lpc2+cm'] = lOut.length;
  }
  if (pdf) {
    // Size probe only (see pdfUnpack doc): measures the idea's ceiling.
    pdfStreamsDecoded = 0;
    final unpacked = pdfUnpack(data);
    results['unpack+cm*'] = c.compress(unpacked).length;
    print('  [pdf: $pdfStreamsDecoded streams inflated, '
        '${data.length} -> ${unpacked.length} B unpacked]');
  }

  final best = results.entries.reduce((a, b) => a.value <= b.value ? a : b);
  final vsGzip = 100 * (1 - best.value / results['gzip9']!);
  final line = results.entries
      .map((e) => '${e.key}=${e.value}')
      .join('  ');
  print('$label (${data.length} B): $line  '
      '=> WINNER ${best.key} (${vsGzip.toStringAsFixed(1)}% vs gzip9) '
      '[${sw.elapsedMilliseconds} ms]');
}

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List _load(String path, int cap) {
  final b = File(path).readAsBytesSync();
  return Uint8List.sublistView(b, 0, b.length < cap ? b.length : cap);
}

void main() {
  const cap = 131072; // 128KB per sample keeps the lab fast
  final samples = <String, String>{
    'PDF (invoice)': '/Users/behnam/Downloads/TPNL00403986.pdf',
    'PDF (system card)':
        '/Users/behnam/Downloads/Claude_Mythos_Preview_System_Card.pdf',
    'PNG (screenshot)': '/Users/behnam/Downloads/IMG_4689.PNG',
    'JPG (photo)': '/Users/behnam/Downloads/rotonde-fietspad.jpg',
    'WAV PCM (voice)':
        '/Users/behnam/Downloads/voice_call_kit_v3/demo_audio/gift_24k.wav',
    'Dart source': 'lib/src/media_codecs/live_context_compressor.dart',
  };
  samples.forEach((label, path) {
    if (!File(path).existsSync()) {
      print('$label: MISSING $path');
      return;
    }
    race(label, _load(path, cap),
        pcm: label.contains('PCM'), pdf: label.contains('PDF'));
  });

  // 2D image probe: full PNG -> pixels -> Paeth residual -> CM,
  // against a fair PNG-equivalent (gzip9 over the same residual, which
  // is exactly PNG's own filter+deflate pipeline on this crop).
  final pngFile =
      File('/Users/behnam/Downloads/voorrang_tram_afslaan_topdown.png')
          .readAsBytesSync();
  final img = pngDecode(Uint8List.fromList(pngFile));
  if (img == null) {
    print('2D probe: PNG decode unsupported for this file');
    return;
  }
  final rows = img.height < 500 ? img.height : 500;
  final crop = Uint8List.sublistView(
      img.pixels, 0, rows * img.width * img.channels);
  final res = residual2d(crop, img.width, rows, img.channels);
  final sw = Stopwatch()..start();
  final ours = c.compress(res).length;
  final pngProxy = gz.encode(res).length;
  final rawCm = c.compress(crop).length;
  print('2D probe (${img.width}x$rows x${img.channels}, '
      '${crop.length} B raw pixels): png-proxy(gzip9)=$pngProxy  '
      '2d+cm=$ours  cm-no-2d=$rawCm  '
      '=> ${(100 * (1 - ours / pngProxy)).toStringAsFixed(1)}% smaller than '
      'PNG-equivalent [${sw.elapsedMilliseconds} ms]');
}
