// Decodes a video letter's length-prefixed Opus tail (nibble 6: SILK WB VBR
// at 16 kHz, [u8 len][packet] per 60 ms) with the phone's own libopus at
// decoder complexity 7 (NoLACE) — the ear's decode. open_video_letter.sh
// calls it instead of ffmpeg's plain decoder, so the Mac judges the video's
// sound the way it judged the voice letter (2026-09-22).
// Usage: dart run tool/decode_video_tail.dart <a.bits> <out.wav> [complexity]
import 'dart:io';
import 'dart:typed_data';

import 'package:hamseda_codec/src/opus_ffi.dart';

import 'decode_voice_letter.dart' show wavOf;

void main(List<String> args) {
  final bits = File(args[0]).readAsBytesSync();
  final codec = OpusVoice.configured(
    OpusVoiceConfig.vbr(12000), // decoder side: only the 16 kHz rate matters
    decoderComplexity: args.length > 2 ? int.parse(args[2]) : 7,
  );
  final out = BytesBuilder(copy: false);
  var packets = 0;
  try {
    var p = 0;
    while (p < bits.length) {
      final n = bits[p];
      if (n == 0 || p + 1 + n > bits.length) break;
      final s = codec.decodeFrame(
        Uint8List.sublistView(bits, p + 1, p + 1 + n),
      );
      out.add(s.buffer.asUint8List(s.offsetInBytes, s.lengthInBytes));
      packets++;
      p += 1 + n;
    }
  } finally {
    codec.dispose();
  }
  File(args[1]).writeAsBytesSync(wavOf(out.takeBytes(), codec.sampleRate));
  stdout.writeln(
    'decoded $packets packets (${packets * 60 / 1000} s, '
    '${codec.sampleRate} Hz) -> ${args[1]}',
  );
}
