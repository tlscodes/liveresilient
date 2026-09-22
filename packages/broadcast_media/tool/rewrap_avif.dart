// Proves the AVIF writer against a file ffmpeg made: takes an .avif, pulls
// its AV1 payload out with avifMdatPayload, wraps it again with
// wrapAvif, and writes the result — ffmpeg must decode the rewrap to the
// same pixels. Usage: dart run tool/rewrap_avif.dart <in.avif> <out.avif> <w> <h>
import 'dart:io';
import 'dart:typed_data';

import 'package:broadcast_media/src/av1_decoder.dart';
import 'package:broadcast_media/src/avif_writer.dart';

void main(List<String> args) {
  final src = File(args[0]).readAsBytesSync();
  final obu = avifMdatPayload(Uint8List.fromList(src));
  final out = wrapAvif(
    obu,
    width: int.parse(args[2]),
    height: int.parse(args[3]),
  );
  File(args[1]).writeAsBytesSync(out);
  stdout.writeln(
    'payload ${obu.length} B -> ${out.length} B (source ${src.length} B), '
    'isAvif=${isAvif(out)}',
  );
}
