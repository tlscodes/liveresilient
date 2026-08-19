/// Host-side proof of the brotli FFI binding (measured-on-host; the device
/// loads the same brotli revision from the vendored frameworks).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:broadcast_media/src/brotli_ffi.dart';
import 'package:broadcast_media/src/compact_news_codec.dart';
import 'package:test/test.dart';

void main() {
  test('q11 round trip through the news codec', () {
    final page = <String, Object?>{
      'ver': 1,
      'title': 'تیتر آزمون بین دو پیاده‌سازی',
      'dek': 'زیرتیتر کوتاه',
      'published': 1755600000,
      'source': 'واحد آزمون',
      'image': <String, Object?>{
        'type': 'blurhash',
        'hash': 'LKO2?U%2Tw=w]~RBVZRi};RPxuwH',
        'w': 4,
        'h': 3,
        'alt': 'تصویر آزمایشی',
      },
      'body': List.generate(
          40, (i) => 'بند شماره‌ی $i از متن خبر برای فشرده‌سازی.').join(' '),
    };
    final wire = encodeNewsPage(page, brotliEncode);
    final back = decodeNewsPage(Uint8List.fromList(wire), brotliDecode);
    expect(back, page, reason: 'codec round trip must be exact');
  });

  test('interop: CLI-produced wire (the phase-5 measurer path) decodes', () {
    final probe = Process.runSync('sh', ['-c', 'command -v brotli']);
    expect(probe.exitCode, 0, reason: 'brotli CLI is part of this rig');
    final raw = utf8.encode('متن خبر برای آزمون تطابق دو پیاده‌سازی');
    final tmp = Directory.systemTemp.createTempSync('brffi');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final rawF = File('${tmp.path}/n.txt')..writeAsBytesSync(raw);
    final r = Process.runSync(
        'brotli', ['-q', '11', '-f', rawF.path, '-o', '${tmp.path}/n.br']);
    expect(r.exitCode, 0, reason: 'CLI compress failed: ${r.stderr}');
    final wire = File('${tmp.path}/n.br').readAsBytesSync();
    expect(brotliDecode(Uint8List.fromList(wire)), raw,
        reason: 'FFI decode must accept the measurer-produced stream');
  });

  test('oversize plaintext claim is rejected, not allocated', () {
    final bomb = brotliEncode(Uint8List(64 * 1024));
    expect(() => brotliDecode(bomb, maxOut: 1024), throwsStateError);
  });
}
