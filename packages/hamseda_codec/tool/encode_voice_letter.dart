// Inverse of decode_voice_letter.dart: raw s16le mono 8 kHz PCM in, one
// DNS-valve voice letter (Codec2 700C, packVoiceNote wire) out — the same
// bytes the phone's VoiceLetterRecorder produces, made on the Mac so a
// Mac-authored voice letter can ride the rig's `JOURNEY_VALVE_CHAT_FILE`.
//
//   dart run tool/encode_voice_letter.dart in.pcm out.letter
//
// Frames the input into samplesPerFrame chunks (the last partial chunk is
// zero-padded), prints the frame count, the wire length and the seconds.
import 'dart:io';
import 'dart:typed_data';

import 'package:hamseda_codec/src/codec2_ffi.dart';
import 'package:hamseda_codec/src/voice_note_codec.dart';

void main(List<String> args) {
  final pcm = File(args[0]).readAsBytesSync();
  final samples = Int16List.view(
    pcm.buffer,
    pcm.offsetInBytes,
    pcm.lengthInBytes ~/ 2,
  );
  final codec = Codec2(codec2Mode700C);
  final n = codec.samplesPerFrame;
  final frames = <Uint8List>[];
  for (var at = 0; at < samples.length; at += n) {
    final chunk = Int16List(n);
    final take = (samples.length - at).clamp(0, n);
    chunk.setRange(0, take, samples, at);
    frames.add(Uint8List.fromList(codec.encodeFrame(chunk)));
  }
  codec.dispose();
  final wire = packVoiceNote(frames: frames, mode: VoiceNoteMode.c700);
  File(args[1]).writeAsBytesSync(wire);
  final seconds = samples.length / 8000;
  stdout.writeln(
    'encoded ${frames.length} frames (${seconds.toStringAsFixed(1)} s) '
    '-> ${wire.length} B ${args[1]}',
  );
}
