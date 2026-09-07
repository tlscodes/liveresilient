import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/wav_probe.dart';

/// A RIFF/WAVE file made of [chunks] in order (id, body); odd bodies are
/// padded to an even length exactly as a real writer pads them.
List<int> wavBytes(List<(String, List<int>)> chunks) {
  final body = <int>[...'WAVE'.codeUnits];
  for (final (id, data) in chunks) {
    body
      ..addAll(id.codeUnits)
      ..addAll(_u32(data.length))
      ..addAll(data);
    if (data.length.isOdd) body.add(0);
  }
  return [...'RIFF'.codeUnits, ..._u32(body.length), ...body];
}

List<int> fmtBody({
  required int tag,
  required int channels,
  required int sampleRate,
  required int byteRate,
  required int blockAlign,
  required int bits,
  List<int> extra = const [],
}) => [
  ..._u16(tag),
  ..._u16(channels),
  ..._u32(sampleRate),
  ..._u32(byteRate),
  ..._u16(blockAlign),
  ..._u16(bits),
  ...extra,
];

List<int> _u16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
List<int> _u32(int v) => [
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
];

/// PCM16 LE samples: a square wave of [quiet] for the first three quarters
/// and [loud] for the last quarter.
List<int> pcm16Samples(int count, {required int quiet, required int loud}) {
  final out = <int>[];
  for (var i = 0; i < count; i++) {
    final amplitude = i < count * 3 ~/ 4 ? quiet : loud;
    final s = i.isEven ? amplitude : -amplitude;
    out.addAll(_u16(s & 0xFFFF));
  }
  return out;
}

void main() {
  group('probeWav', () {
    test('walks past a FLLR pad (macOS say) to the fmt and data chunks', () {
      final data = pcm16Samples(21440, quiet: 2000, loud: 20000);
      expect(data.length, 42880);
      final bytes = wavBytes([
        (
          'fmt ',
          fmtBody(
            tag: 1,
            channels: 1,
            sampleRate: 8000,
            byteRate: 16000,
            blockAlign: 2,
            bits: 16,
          ),
        ),
        ('FLLR', List<int>.filled(4044, 0)),
        ('data', data),
      ]);
      final info = probeWav(bytes);
      expect(info, isNotNull);
      expect(info!.formatTag, 1);
      expect(info.channels, 1);
      expect(info.sampleRate, 8000);
      expect(info.byteRate, 16000);
      expect(info.bitsPerSample, 16);
      expect(info.dataBytes, 42880);
      expect(info.duration.inMilliseconds, 2680);

      final peaks = info.peaks(4);
      expect(peaks, isNotNull);
      expect(peaks!.length, 4);
      expect(peaks[3], 1.0);
      for (final quiet in peaks.take(3)) {
        expect(quiet, closeTo(0.1, 0.001));
      }
    });

    test('IMA ADPCM with a 20-byte fmt, fact and LIST: clock yes, bars no', () {
      final bytes = wavBytes([
        (
          'fmt ',
          fmtBody(
            tag: 17,
            channels: 1,
            sampleRate: 8000,
            byteRate: 4013,
            blockAlign: 1024,
            bits: 4,
            extra: [..._u16(2), ..._u16(2041)],
          ),
        ),
        ('fact', _u32(42880)),
        (
          'LIST',
          [
            ...'INFO'.codeUnits,
            ...'ISFT'.codeUnits,
            ..._u32(6),
            ...'Lavf62'.codeUnits,
          ],
        ),
        ('data', List<int>.filled(21504, 0x11)),
      ]);
      final info = probeWav(bytes);
      expect(info, isNotNull);
      expect(info!.formatTag, 17);
      expect(info.dataBytes, 21504);
      expect(info.duration.inMilliseconds, closeTo(5359, 5));
      expect(info.peaks(32), isNull);
    });

    test('mu-law decodes through the G.711 table and yields real bars', () {
      expect(muLawDecodeTable[0xFF], 0);
      expect(muLawDecodeTable[0x00], -32124);
      expect(muLawDecodeTable[0x80], 32124);
      final data = List<int>.generate(8000, (i) => i < 6000 ? 0xFF : 0x00);
      final bytes = wavBytes([
        (
          'fmt ',
          fmtBody(
            tag: 7,
            channels: 1,
            sampleRate: 8000,
            byteRate: 8000,
            blockAlign: 1,
            bits: 8,
          ),
        ),
        ('data', data),
      ]);
      final info = probeWav(bytes);
      expect(info, isNotNull);
      expect(info!.duration.inMilliseconds, 1000);
      final peaks = info.peaks(32);
      expect(peaks, isNotNull);
      expect(peaks!.length, 32);
      expect(peaks.reduce(math.max), 1.0);
      expect(peaks.first, 0.05);
      expect(peaks.last, 1.0);
    });

    test('stereo PCM16 reads channel 0 only', () {
      final frames = <int>[];
      for (var i = 0; i < 4000; i++) {
        frames
          ..addAll(_u16((i.isEven ? 10000 : -10000) & 0xFFFF))
          ..addAll(_u16(0));
      }
      final bytes = wavBytes([
        (
          'fmt ',
          fmtBody(
            tag: 1,
            channels: 2,
            sampleRate: 8000,
            byteRate: 32000,
            blockAlign: 4,
            bits: 16,
          ),
        ),
        ('data', frames),
      ]);
      final info = probeWav(bytes)!;
      expect(info.duration.inMilliseconds, 500);
      final peaks = info.peaks(8)!;
      expect(peaks.every((p) => p == 1.0), isTrue);
    });

    test('a data chunk that promises more than the file holds is clamped', () {
      final good = wavBytes([
        (
          'fmt ',
          fmtBody(
            tag: 1,
            channels: 1,
            sampleRate: 8000,
            byteRate: 16000,
            blockAlign: 2,
            bits: 16,
          ),
        ),
        ('data', List<int>.filled(16000, 0)),
      ]);
      final short = good.sublist(0, good.length - 8000);
      final info = probeWav(short);
      expect(info, isNotNull);
      expect(info!.dataBytes, 8000);
      expect(info.duration.inMilliseconds, 500);
    });

    test('garbage, truncated headers and non-WAV RIFF return null', () {
      final random = math.Random(7);
      expect(
        probeWav(List<int>.generate(100, (_) => random.nextInt(256))),
        isNull,
      );
      expect(probeWav(const []), isNull);
      expect(probeWav('RIFF'.codeUnits), isNull);
      final good = wavBytes([
        (
          'fmt ',
          fmtBody(
            tag: 1,
            channels: 1,
            sampleRate: 8000,
            byteRate: 16000,
            blockAlign: 2,
            bits: 16,
          ),
        ),
        ('data', List<int>.filled(1600, 0)),
      ]);
      expect(probeWav(good.sublist(0, 30)), isNull, reason: 'cut inside fmt');
      expect(probeWav(good.sublist(0, 40)), isNull, reason: 'no data chunk');
      final avi = [...good];
      avi.setRange(8, 12, 'AVI '.codeUnits);
      expect(probeWav(avi), isNull);
      final noFmt = wavBytes([('data', List<int>.filled(16, 0))]);
      expect(probeWav(noFmt), isNull);
    });
  });
}
