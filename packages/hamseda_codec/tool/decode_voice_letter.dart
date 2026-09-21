// TEMP diagnostic script — not part of the package's shipped tool set.
// Decodes a DNS-valve voice letter (voice_note_codec.dart wire format)
// back to raw s16le PCM via the same FFI Codec2 path used to encode it.
// Usage: dart run tool/decode_voice_letter.dart <in.letter> <out.raw|out.wav> [opus complexity]
// The PCM is s16le mono at the MODE's rate (8 kHz for Codec2 and mode 12,
// 16 kHz for mode 6); an out path ending in .wav gets a RIFF header so
// no caller has to know the rate.
import 'dart:io';
import 'dart:typed_data';

import 'package:hamseda_codec/src/voice_frame_codec.dart';
import 'package:hamseda_codec/src/voice_note_codec.dart';

void main(List<String> args) {
  final bytes = File(args[0]).readAsBytesSync();
  final wire = Uint8List.fromList(bytes);
  final frames = unpackVoiceNote(wire);
  final mode = voiceNoteModeOf(wire);
  // Optional third argument: Opus decoder complexity (6 = LACE, 7 = NoLACE
  // OSCE enhancement; default 0 = plain). Ignored for Codec2 modes.
  final codec = voiceFrameCodecFor(
    mode,
    decoderComplexity: args.length > 2 ? int.parse(args[2]) : 0,
  );
  final out = BytesBuilder();
  for (final f in frames) {
    final samples = codec.decodeFrame(f);
    out.add(
      samples.buffer.asUint8List(samples.offsetInBytes, samples.lengthInBytes),
    );
  }
  codec.dispose();
  final pcm = out.takeBytes();
  File(args[1]).writeAsBytesSync(
    args[1].endsWith('.wav') ? wavOf(pcm, mode.sampleRate) : pcm,
  );
  stdout.writeln(
    'decoded ${frames.length} frames (${mode.name}, ${frames.length * mode.frameMs / 1000} s, '
    '${mode.sampleRate} Hz) -> ${args[1]}',
  );
}

/// A 44-byte RIFF/WAVE header over s16le mono [pcm] at [rate].
Uint8List wavOf(Uint8List pcm, int rate) {
  final b = ByteData(44);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  b.setUint32(4, 36 + pcm.length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  b.setUint32(40, pcm.length, Endian.little);
  return Uint8List.fromList([...b.buffer.asUint8List(), ...pcm]);
}
