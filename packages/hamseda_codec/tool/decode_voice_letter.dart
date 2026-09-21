// TEMP diagnostic script — not part of the package's shipped tool set.
// Decodes a DNS-valve voice letter (voice_note_codec.dart wire format)
// back to raw s16le PCM via the same FFI Codec2 path used to encode it.
// Usage: dart run tool/decode_voice_letter.dart <in.letter> <out.raw> [opus complexity]
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
  File(args[1]).writeAsBytesSync(out.takeBytes());
  stdout.writeln(
    'decoded ${frames.length} frames (${mode.name}, ${frames.length * mode.frameMs / 1000} s) -> ${args[1]}',
  );
}
