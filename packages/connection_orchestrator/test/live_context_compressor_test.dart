/// Live context-mixing compressor — round-trip exactness plus a
/// measured head-to-head against gzip level 9 on realistic corpora.
/// All numbers printed are measured in this run, never quoted.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/src/media_codecs/live_context_compressor.dart';
import 'package:test/test.dart';

final _gzip = GZipCodec(level: 9);

String _representativeText(int size, int seed) {
  final rng = Random(seed);
  final words = [
    'transfer',
    'voice',
    'channel',
    'document',
    'budget',
    'silence',
    'datagram',
    'parity',
    'receiver',
    'network',
    'قرارداد',
    'سند',
    'صوت',
    'انتقال',
    'شبکه',
  ];
  final sb = StringBuffer();
  while (sb.length < size) {
    sb.write(words[rng.nextInt(words.length)]);
    sb.write(rng.nextInt(12) == 0 ? '.\n' : ' ');
  }
  return sb.toString().substring(0, size);
}

void main() {
  const c = LiveContextCompressor();

  test('round-trip is byte-exact: text, Persian, binary, random, edges', () {
    final rng = Random(9);
    final cases = <Uint8List>[
      Uint8List(0),
      Uint8List.fromList([0]),
      Uint8List.fromList([255]),
      Uint8List.fromList(utf8.encode(_representativeText(5000, 1))),
      Uint8List.fromList(utf8.encode('سلام دنیا؛ متن فارسی کامل. ' * 80)),
      Uint8List.fromList(List.generate(4096, (_) => rng.nextInt(256))),
      Uint8List.fromList(List.generate(3000, (i) => (i * 7) & 0xFF)),
    ];
    for (final data in cases) {
      expect(
        c.decompress(c.compress(data)),
        equals(data),
        reason: 'len ${data.length}',
      );
    }
  });

  test('random (incompressible) data expands by less than 1%', () {
    final rng = Random(4);
    final data = Uint8List.fromList(
      List.generate(16384, (_) => rng.nextInt(256)),
    );
    final out = c.compress(data);
    expect(out.length, lessThan(data.length * 1.01 + 16));
  });

  test('measured head-to-head vs gzip level 9 (must win on every corpus)', () {
    final corpora = <String, Uint8List>{
      '10KB representative doc': Uint8List.fromList(
        utf8.encode(_representativeText(10240, 42)),
      ),
      '10KB Persian prose': Uint8List.fromList(
        utf8.encode(
          ('در سکوت، داده‌ها منتقل می‌شوند و صدا همیشه مقدم است؛ '
                      'سند و عکس در پس‌زمینه، ذره‌ذره، بدون بازخورد. ')
                  .padRight(1, ' ') *
              120,
        ),
      ),
      '16KB dart source': Uint8List.fromList(
        utf8.encode(
          File('lib/src/rateless_stream.dart').readAsStringSync() +
              File('lib/src/media_queue.dart').readAsStringSync() +
              File('lib/src/micro_datagram_lane.dart').readAsStringSync(),
        ),
      ),
    };
    corpora.forEach((name, data) {
      final ours = c.compress(data);
      final gz = _gzip.encode(data);
      final gain = 100 * (1 - ours.length / gz.length);
      // ignore: avoid_print
      print(
        'live-cm vs gzip9 — $name: ${data.length} B -> '
        'ours ${ours.length} B, gzip ${gz.length} B '
        '(${gain.toStringAsFixed(1)}% smaller than gzip)',
      );
      expect(c.decompress(ours), equals(data));
      expect(
        ours.length,
        lessThan(gz.length),
        reason: '$name: must beat gzip level 9',
      );
    });
  });
}
