/// Measures what motion compensation buys on panning footage by coding
/// the same clip with the plain temporal predictor and with the full
/// three-way choice.
import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/src/media_codecs/flipbook_video_compressor.dart';
import 'package:connection_orchestrator/src/media_codecs/live_context_compressor.dart';

const srcW = 240, srcH = 160, frames = 6, panX = 3, panY = 2;

void main() {
  final rng = Random(11);
  final field = Uint8List(srcW * srcH);
  for (var i = 0; i < field.length; i++) {
    field[i] = rng.nextInt(256);
  }
  Uint8List frameAt(int f) {
    final out = Uint8List(srcW * srcH);
    for (var y = 0; y < srcH; y++) {
      for (var x = 0; x < srcW; x++) {
        out[y * srcW + x] =
            field[((y + f * panY) % srcH) * srcW + (x + f * panX) % srcW];
      }
    }
    return out;
  }

  final grays = List.generate(frames, frameAt);
  const codec = FlipbookVideoCompressor();
  final coded = codec.encode(grays, srcW, srcH);
  final withMotion = coded.fold<int>(0, (a, f) => a + f.bytes.length);
  final motionCount = coded
      .where((f) => f.predictor == FlipbookPredictor.temporalMotion)
      .length;

  // Plain-temporal-only reference: same downsample and quantization, same
  // entropy coder, but no motion search.
  const cm = LiveContextCompressor();
  var plainTotal = 0;
  Uint8List? prev;
  for (final g in grays) {
    final q = codec.downQuant(g, srcW, srcH);
    if (prev == null) {
      plainTotal += coded.first.bytes.length; // identical intra frame
    } else {
      final d = Uint8List(q.length);
      for (var i = 0; i < q.length; i++) {
        d[i] = (q[i] - prev[i]) & 0xFF;
      }
      plainTotal += cm.compress(d).length;
    }
    prev = q;
  }

  final saved = (1 - withMotion / plainTotal) * 100;
  print('pan clip, $frames frames of ${srcW}x$srcH panning ($panX,$panY)/frame');
  print('  plain temporal only : $plainTotal B');
  print('  three-way w/ motion : $withMotion B  '
      '($motionCount/${coded.length} motion-coded)');
  print('  saving              : ${saved.toStringAsFixed(1)}%');
}
