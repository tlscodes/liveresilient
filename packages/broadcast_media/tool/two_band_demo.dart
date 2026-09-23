// Builds a two-band video letter on the Mac with the phone's own code:
// a 216x384 I420 clip, s16le 16 kHz audio, and one page (648x1152 I420)
// held over output frames [start, end). Proves the receiver path end to
// end without a phone. Usage:
//   dart run tool/two_band_demo.dart <clip.i420> <audio.s16le> <page.i420> <start> <end> <budget> <out.bin>
import 'dart:io';
import 'dart:typed_data';

import 'package:broadcast_media/src/two_band_video.dart';

void main(List<String> args) {
  final clip = File(args[0]).readAsBytesSync();
  final pcm = File(args[1]).readAsBytesSync();
  final page = File(args[2]).readAsBytesSync();
  final hold = Hold(int.parse(args[3]), int.parse(args[4]));
  final b = buildTwoBandLetter(
    clip: Uint8List.fromList(clip),
    pcm16k: Uint8List.fromList(pcm),
    fps: 6,
    budget: int.parse(args[5]),
    pages: {hold: Uint8List.fromList(page)},
  );
  File(args[6]).writeAsBytesSync(b.wire);
  stdout.writeln(
    'wire ${b.wire.length} B, pages ${b.pages} (${b.pageBytes} B), '
    'moving crf ${b.movingCrf}, ${b.frames} units, ${b.passes} passes',
  );
}
