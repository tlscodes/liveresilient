// Runs the phone's own video-letter builder on the Mac, so a refusal the
// phone reports can be reproduced with numbers: raw I420 frames + s16le
// 16 kHz audio in, the wire (or the refusal with its smallest size) out.
// Usage: dart run tool/build_video_letter.dart <in.i420> <in.s16le16k> <w> <h> <fps> <budget> [out.bin]
import 'dart:io';
import 'dart:typed_data';

import 'package:broadcast_media/src/av1_encoder.dart';

void main(List<String> args) {
  final i420 = File(args[0]).readAsBytesSync();
  final pcm = File(args[1]).readAsBytesSync();
  final w = int.parse(args[2]), h = int.parse(args[3]);
  final fps = int.parse(args[4]), budget = int.parse(args[5]);
  final started = DateTime.now();
  try {
    final b = buildVideoLetter(
      i420: Uint8List.fromList(i420),
      pcm16k: Uint8List.fromList(pcm),
      width: w,
      height: h,
      fps: fps,
      budget: budget,
      crfHigh: args.length > 7 ? int.parse(args[7]) : 30,
    );
    final ms = DateTime.now().difference(started).inMilliseconds;
    stdout.writeln(
      'fit ${b.wire.length} B crf ${b.crf} frames ${b.frames} '
      'audio ${b.audioPackets} packets passes ${b.passes} in $ms ms',
    );
    if (args.length > 6) File(args[6]).writeAsBytesSync(b.wire);
  } on VideoLetterTooLong catch (e) {
    stdout.writeln('REFUSED $e');
  }
}
