/// RIFF/WAVE probe: the format chunk and the data chunk found by WALKING the
/// chunk list, never by fixed offsets. Real writers put other chunks before
/// `data` — macOS `say` emits a 4,044-byte `FLLR` pad, ffmpeg's ADPCM writer
/// emits a 20-byte `fmt ` plus `fact` and `LIST` — so a parser that assumes
/// `data` at offset 36 shows a wrong clock for both.
///
/// Pure Dart, no Flutter import: usable from widget code and plain tests.
library;

import 'dart:math' as math;

/// WAVE_FORMAT_PCM.
const int wavFormatPcm = 1;

/// WAVE_FORMAT_MULAW (G.711 mu-law, 8 bits per sample).
const int wavFormatMuLaw = 7;

/// What the `fmt ` and `data` chunks of a WAV say about it.
class WavInfo {
  const WavInfo({
    required this.formatTag,
    required this.channels,
    required this.sampleRate,
    required this.byteRate,
    required this.blockAlign,
    required this.bitsPerSample,
    required this.dataBytes,
    required this._bytes,
    required this._dataStart,
  });

  final int formatTag;
  final int channels;
  final int sampleRate;

  /// Bytes per second of audio as declared by the writer (format-agnostic:
  /// correct for ADPCM as well as PCM, which is why the clock uses it).
  final int byteRate;
  final int blockAlign;
  final int bitsPerSample;

  /// Length of the `data` chunk, clamped to the bytes actually present so a
  /// truncated file reports the audio it holds, not the audio it promised.
  final int dataBytes;

  final List<int> _bytes;
  final int _dataStart;

  /// Playback length: `dataBytes / byteRate`. Zero when the writer declared
  /// no byte rate, which the player bar renders as "no clock".
  Duration get duration => byteRate > 0
      ? Duration(microseconds: dataBytes * 1000000 ~/ byteRate)
      : Duration.zero;

  /// Real amplitude bars: [barCount] equal windows over channel 0, each bar
  /// the window's RMS normalized so the loudest bar is 1.0 (floor 0.05).
  /// Only PCM16 and mu-law are decoded; every other format returns null so
  /// the caller can fall back to decorative bars instead of guessing.
  List<double>? peaks(int barCount) {
    if (barCount <= 0) return null;
    try {
      final int bytesPerSample;
      final int Function(int offset) sample;
      if (formatTag == wavFormatPcm && bitsPerSample == 16) {
        bytesPerSample = 2;
        sample = _pcm16At;
      } else if (formatTag == wavFormatMuLaw && bitsPerSample == 8) {
        bytesPerSample = 1;
        sample = _muLawAt;
      } else {
        return null;
      }
      final int frameBytes = blockAlign > 0
          ? blockAlign
          : bytesPerSample * math.max<int>(1, channels);
      if (frameBytes < bytesPerSample) return null;
      final available = math.min(dataBytes, _bytes.length - _dataStart);
      final frames = available ~/ frameBytes;
      if (frames <= 0) return null;
      final rms = List<double>.filled(barCount, 0);
      var loudest = 0.0;
      for (var bar = 0; bar < barCount; bar++) {
        final from = bar * frames ~/ barCount;
        final to = (bar + 1) * frames ~/ barCount;
        if (to <= from) continue;
        var sum = 0.0;
        for (var frame = from; frame < to; frame++) {
          final s = sample(_dataStart + frame * frameBytes).toDouble();
          sum += s * s;
        }
        final value = math.sqrt(sum / (to - from));
        rms[bar] = value;
        if (value > loudest) loudest = value;
      }
      return [
        for (final value in rms)
          loudest > 0 ? math.max(0.05, value / loudest) : 0.05,
      ];
    } catch (_) {
      return null;
    }
  }

  int _pcm16At(int offset) {
    final raw = (_bytes[offset] & 0xFF) | ((_bytes[offset + 1] & 0xFF) << 8);
    return raw >= 0x8000 ? raw - 0x10000 : raw;
  }

  int _muLawAt(int offset) => muLawDecodeTable[_bytes[offset] & 0xFF];
}

/// G.711 mu-law byte to 16-bit linear PCM (the standard expansion).
final List<int> muLawDecodeTable = List<int>.generate(256, (code) {
  final inverted = ~code & 0xFF;
  final exponent = (inverted >> 4) & 0x07;
  final mantissa = inverted & 0x0F;
  final magnitude = (((mantissa << 3) + 0x84) << exponent) - 0x84;
  return (inverted & 0x80) != 0 ? -magnitude : magnitude;
});

/// Parses the RIFF chunk list of [bytes]. Null for anything that is not a
/// well-formed WAV with both a `fmt ` and a `data` chunk; no exception
/// escapes.
WavInfo? probeWav(List<int> bytes) {
  try {
    return _probe(bytes);
  } catch (_) {
    return null;
  }
}

WavInfo? _probe(List<int> bytes) {
  final length = bytes.length;
  if (length < 12) return null;
  if (_fourCc(bytes, 0) != 'RIFF' || _fourCc(bytes, 8) != 'WAVE') return null;

  int? formatTag;
  int? channels;
  int? sampleRate;
  int? byteRate;
  int? blockAlign;
  int? bitsPerSample;
  int? dataStart;
  int? dataBytes;

  var offset = 12;
  while (offset + 8 <= length) {
    final id = _fourCc(bytes, offset);
    final size = _u32le(bytes, offset + 4);
    final body = offset + 8;
    if (id == 'fmt ') {
      if (size < 16 || body + 16 > length) return null;
      formatTag = _u16le(bytes, body);
      channels = _u16le(bytes, body + 2);
      sampleRate = _u32le(bytes, body + 4);
      byteRate = _u32le(bytes, body + 8);
      blockAlign = _u16le(bytes, body + 12);
      bitsPerSample = _u16le(bytes, body + 14);
    } else if (id == 'data') {
      dataStart = body;
      // A streaming writer may declare more than it wrote (or 0xFFFFFFFF);
      // the clock counts the bytes that are actually here.
      dataBytes = math.min(size, length - body);
    }
    if (formatTag != null && dataStart != null) break;
    // Chunk bodies are padded to an even length.
    final next = body + size + (size & 1);
    if (next > length) {
      // Only the data chunk may run to the end of the file (see above).
      if (id != 'data') return null;
      break;
    }
    offset = next;
  }
  if (formatTag == null || dataStart == null) return null;
  return WavInfo(
    formatTag: formatTag,
    channels: channels!,
    sampleRate: sampleRate!,
    byteRate: byteRate!,
    blockAlign: blockAlign!,
    bitsPerSample: bitsPerSample!,
    dataBytes: dataBytes!,
    bytes: bytes,
    dataStart: dataStart,
  );
}

String _fourCc(List<int> bytes, int offset) {
  if (offset + 4 > bytes.length) return '';
  return String.fromCharCodes([
    bytes[offset] & 0xFF,
    bytes[offset + 1] & 0xFF,
    bytes[offset + 2] & 0xFF,
    bytes[offset + 3] & 0xFF,
  ]);
}

int _u16le(List<int> bytes, int offset) {
  if (offset + 2 > bytes.length) throw RangeError('u16 past end');
  return (bytes[offset] & 0xFF) | ((bytes[offset + 1] & 0xFF) << 8);
}

int _u32le(List<int> bytes, int offset) {
  if (offset + 4 > bytes.length) throw RangeError('u32 past end');
  return (bytes[offset] & 0xFF) |
      ((bytes[offset + 1] & 0xFF) << 8) |
      ((bytes[offset + 2] & 0xFF) << 16) |
      ((bytes[offset + 3] & 0xFF) << 24);
}
