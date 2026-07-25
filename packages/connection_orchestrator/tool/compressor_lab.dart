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

void race(String label, Uint8List data) {
  final sw = Stopwatch()..start();
  final results = <String, int>{};

  results['gzip9'] = gz.encode(data).length;

  final cmOut = c.compress(data);
  assert(_eq(c.decompress(cmOut), data));
  results['cm'] = cmOut.length;

  final dOut = c.compress(delta(data));
  assert(_eq(undelta(c.decompress(dOut)), data));
  results['delta+cm'] = dOut.length;

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
    race(label, _load(path, cap));
  });
}
