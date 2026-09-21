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

import 'package:hamseda_codec/src/voice_frame_codec.dart';
import 'package:hamseda_codec/src/voice_note_codec.dart';

void main(List<String> args) {
  final pcm = File(args[0]).readAsBytesSync();
  final samples = Int16List.view(
    pcm.buffer,
    pcm.offsetInBytes,
    pcm.lengthInBytes ~/ 2,
  );
  // Optional third argument: opusVbr|opus6k|3200|2400|1600|1200|700C
  // (default 700C); optional fourth: the Opus VBR bitrate (default 10000).
  // The input PCM must be at the mode's rate: 16 kHz for opusVbr, 8 kHz
  // for everything else.
  final mode = args.length > 2
      ? VoiceNoteMode.values.firstWhere(
          (m) =>
              m.name == args[2] || m.name == 'c${args[2].replaceAll('C', '')}',
        )
      : VoiceNoteMode.c700;
  final codec = voiceFrameCodecFor(
    mode,
    opusBitrate: args.length > 3 ? int.parse(args[3]) : 10000,
  );
  final n = codec.samplesPerFrame;
  final frames = <Uint8List>[];
  for (var at = 0; at < samples.length; at += n) {
    final chunk = Int16List(n);
    final take = (samples.length - at).clamp(0, n);
    chunk.setRange(0, take, samples, at);
    frames.add(Uint8List.fromList(codec.encodeFrame(chunk)));
  }
  codec.dispose();
  final wire = packVoiceNote(frames: frames, mode: mode);
  File(args[1]).writeAsBytesSync(wire);
  final seconds = samples.length / mode.sampleRate;
  stdout.writeln(
    'encoded ${frames.length} frames (${seconds.toStringAsFixed(1)} s, ${mode.name}) '
    '-> ${wire.length} B ${args[1]}',
  );
}
