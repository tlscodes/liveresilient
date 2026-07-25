import 'dart:convert';
import 'dart:typed_data';

import 'package:connection_orchestrator/src/media_codecs/live_context_compressor.dart';

void main() {
  const c = LiveContextCompressor();
  final rep = Uint8List.fromList(utf8.encode('abcdefghij' * 2000));
  final out = c.compress(rep);
  print('pure repeat 20000B -> ${out.length} B');
  final ok = c.decompress(out);
  print('roundtrip ok: ${ok.length == rep.length}');

  final persian = Uint8List.fromList(utf8.encode(
      ('در سکوت، داده‌ها منتقل می‌شوند و صدا همیشه مقدم است؛ '
              'سند و عکس در پس‌زمینه، ذره‌ذره، بدون بازخورد. ')
          .padRight(1, ' ') *
          120));
  final pOut = c.compress(persian);
  print('persian ${persian.length}B -> ${pOut.length} B');
}
