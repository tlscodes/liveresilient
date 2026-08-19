import 'dart:convert';
import 'dart:typed_data';

import 'package:messaging/src/compact_text_codec.dart';
import 'package:test/test.dart';

// Deterministic stand-in compressor for pure-Dart tests: byte-run RLE
// (pairs of [byte, runLength<=255]). Repetitive payloads shrink, mixed text
// inflates — so both codec paths get exercised. It is NOT a real compressor;
// byte-budget numbers come only from tools/phase5/gate_1.sh with real zstd.
Uint8List _rleCompress(Uint8List raw) {
  final out = <int>[];
  var i = 0;
  while (i < raw.length) {
    var run = 1;
    while (i + run < raw.length && raw[i + run] == raw[i] && run < 255) {
      run++;
    }
    out..add(raw[i])..add(run);
    i += run;
  }
  return Uint8List.fromList(out);
}

Uint8List _rleDecompress(Uint8List body) {
  final out = <int>[];
  for (var i = 0; i + 1 < body.length; i += 2) {
    out.addAll(List.filled(body[i + 1], body[i]));
  }
  return Uint8List.fromList(out);
}

void main() {
  test('compressed path round-trips with matching dict version', () {
    final raw = Uint8List.fromList(List.filled(64, 0x61)); // shrinks under RLE
    final frame = encodeCompactText(
        utf8Text: raw, msgId: 4242, dictVer: 7, compress: _rleCompress);
    expect(frame.compressed, isTrue);
    expect(frame.msgId, 4242);
    expect(frame.dictVer, 7);
    final back = decodeCompactText(
        frame: frame, localDictVer: 7, decompress: _rleDecompress);
    expect(back, raw);
  });

  test('incompressible message is stored raw and round-trips', () {
    final raw =
        Uint8List.fromList(utf8.encode('سلام، فردا ساعت ۹ تماس می‌گیرم 🙂'));
    final frame = encodeCompactText(
        utf8Text: raw, msgId: 1, dictVer: 7, compress: _rleCompress);
    expect(frame.compressed, isFalse);
    expect(frame.bytes.length, compactTextHeaderBytes + raw.length);
    final back = decodeCompactText(
        frame: frame,
        localDictVer: 99, // mismatched, but raw body must still decode cleanly
        decompress: _rleDecompress);
    expect(back, raw);
  });

  test('dict version mismatch on compressed frame fails cleanly', () {
    final raw = Uint8List.fromList(List.filled(64, 0x62));
    final frame = encodeCompactText(
        utf8Text: raw, msgId: 2, dictVer: 3, compress: _rleCompress);
    expect(frame.compressed, isTrue);
    expect(
      () => decodeCompactText(
          frame: frame, localDictVer: 4, decompress: _rleDecompress),
      throwsA(isA<DictVersionMismatch>()),
    );
  });

  test('truncated frame fails cleanly', () {
    expect(
      () => decodeCompactText(
          frame: CompactTextFrame(Uint8List(2)),
          localDictVer: 1,
          decompress: _rleDecompress),
      throwsA(isA<MalformedTextFrame>()),
    );
  });
}
