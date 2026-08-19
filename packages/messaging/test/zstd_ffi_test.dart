/// Host-side proof of the zstd FFI binding (measured-on-host; the device
/// loads the same zstd revision from the vendored framework).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:messaging/src/zstd_ffi.dart';
import 'package:test/test.dart';

Uint8List _dict() {
  final f = File('assets/zstd_chat.dict');
  expect(f.existsSync(), isTrue,
      reason: 'trained chat dictionary must ship with the package');
  return f.readAsBytesSync();
}

void main() {
  test('dictionary round trip on chat-shaped text', () {
    final z = ZstdChat(_dict());
    addTearDown(z.dispose);
    final msgs = [
      'سلام، فردا ساعت پنج می‌بینمت؟',
      'باشه عزیزم، همون کافه همیشگی. راستی مدارک را هم بیار لطفا.',
      'ok see you at 5 — bring the docs please',
    ];
    for (final m in msgs) {
      final raw = Uint8List.fromList(utf8.encode(m));
      final out = z.decompress(z.compress(raw));
      expect(out, raw, reason: 'round trip must be byte-exact for: $m');
    }
  });

  test('dictionary actually engages: chat text compresses below raw', () {
    final z = ZstdChat(_dict());
    addTearDown(z.dispose);
    final long = Uint8List.fromList(utf8.encode(
        'سلام، امشب جلسه‌ی خانوادگی داریم و شام هم همون‌جا هستیم؛ '
        'اگر می‌رسی قبلش زنگ بزن که هماهنگ کنیم، بعدش هم عکس‌ها را بفرست.'));
    final c = z.compress(long);
    expect(c.length, lessThan(long.length),
        reason: 'trained dict + level 19 must beat raw on chat text');
  });

  test('interop: CLI-produced frame (the phase-5 measurer path) decodes',
      () {
    final cli = Process.runSync('sh', [
      '-c',
      'command -v zstd',
    ]);
    expect(cli.exitCode, 0, reason: 'zstd CLI is part of this rig');
    final raw = utf8.encode('پیام آزمون بین دو پیاده‌سازی — باید یکی باشد');
    final tmp = Directory.systemTemp.createTempSync('zstdffi');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final rawF = File('${tmp.path}/m.txt')..writeAsBytesSync(raw);
    final r = Process.runSync('zstd', [
      '-19',
      '-D',
      'assets/zstd_chat.dict',
      '-f',
      rawF.path,
      '-o',
      '${tmp.path}/m.zst',
    ]);
    expect(r.exitCode, 0, reason: 'CLI compress failed: ${r.stderr}');
    final wire = File('${tmp.path}/m.zst').readAsBytesSync();
    final z = ZstdChat(_dict());
    addTearDown(z.dispose);
    expect(z.decompress(Uint8List.fromList(wire)), raw,
        reason: 'FFI decode must accept the measurer-produced frame');
  });
}
