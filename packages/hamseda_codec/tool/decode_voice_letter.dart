// TEMP diagnostic script — not part of the package's shipped tool set.
// Decodes a DNS-valve voice letter (voice_note_codec.dart wire format)
// back to raw s16le PCM via the same FFI Codec2 path used to encode it.
// Usage: dart run tool/decode_voice_letter_tmp.dart <in.letter> <out.raw>
import 'dart:io';
import 'dart:typed_data';

import 'package:hamseda_codec/src/codec2_ffi.dart';
import 'package:hamseda_codec/src/voice_note_codec.dart';

void main(List<String> args) {
  final bytes = File(args[0]).readAsBytesSync();
  final wire = Uint8List.fromList(bytes);
  final frames = unpackVoiceNote(wire);
  final codec = Codec2(codec2Mode700C);
  final out = BytesBuilder();
  for (final f in frames) {
    final samples = codec.decodeFrame(f);
    out.add(
      samples.buffer.asUint8List(samples.offsetInBytes, samples.lengthInBytes),
    );
  }
  codec.dispose();
  File(args[1]).writeAsBytesSync(out.takeBytes());
  stdout.writeln('decoded ${frames.length} frames -> ${args[1]}');
}
