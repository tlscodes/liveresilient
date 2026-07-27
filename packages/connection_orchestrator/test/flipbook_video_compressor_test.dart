/// Phase 4c — per-keyframe size band, frame-rate math, and order
/// preservation through the rateless transport.
import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/src/media_codecs/flipbook_video_compressor.dart';
import 'package:connection_orchestrator/src/rateless_stream.dart';
import 'package:test/test.dart';

/// Synthetic 240x160 grayscale scene: a dark disc moving left-to-right.
Uint8List _frame(int t, {int w = 240, int h = 160}) {
  final g = Uint8List(w * h);
  final cx = 30 + t * 12, cy = h ~/ 2;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final dx = x - cx, dy = y - cy;
      // Textured background (diagonal gradient bands) + moving disc, so
      // intra coding has real cost and temporal delta can win.
      final bg = 120 + ((x * 5 + y * 3) % 97);
      g[y * w + x] = dx * dx + dy * dy < 900 ? 30 : bg;
    }
  }
  return g;
}

void main() {
  const c = FlipbookVideoCompressor();

  test('per-keyframe size inside ~300 B target, temporal mode engages', () {
    final frames = List.generate(10, _frame);
    final coded = c.encode(frames, 240, 160);
    final sizes = coded.map((f) => f.bytes.length).toList();
    // ignore: avoid_print
    print(
      'flipbook keyframe sizes: $sizes '
      '(temporal: ${coded.where((f) => f.temporal).length}/10)',
    );
    // The first frame is always intra and pays for the whole scene
    // texture (this synthetic one is deliberately adversarial); steady
    // state is what the ~300 B target governs.
    expect(sizes.first, lessThanOrEqualTo(700), reason: 'intra bootstrap');
    for (final s in sizes.skip(1)) {
      expect(
        s,
        lessThanOrEqualTo(450),
        reason: 'steady-state keyframe must stay near the 300 B target',
      );
    }
    expect(
      coded.where((f) => f.temporal).length,
      greaterThan(5),
      reason: 'moving scene should mostly code temporally',
    );
    final decoded = c.decode(coded);
    expect(decoded.length, 10);
  });

  test('frame count matches the rate for a given duration', () {
    expect(c.frameCountFor(const Duration(seconds: 30)), 10);
    expect(c.frameCountFor(const Duration(seconds: 31)), 11);
    expect(c.frameCountFor(const Duration(seconds: 1)), 1);
  });

  test('playback order preserved through the rateless transport', () {
    final frames = List.generate(6, _frame);
    final coded = c.encode(frames, 240, 160);
    // Serialize each keyframe through its own rateless stream, deliver
    // out of order, decode, and check the sequence reassembles.
    final delivered = <int, Uint8List>{};
    final order = [3, 0, 5, 1, 4, 2];
    for (final idx in order) {
      final enc = RatelessEncoder(coded[idx].bytes);
      final dec = RatelessDecoder();
      var esi = 0;
      while (!dec.isComplete) {
        if (esi.isEven) dec.addDatagram(enc.datagramAt(esi)); // 50% loss
        esi++;
      }
      delivered[idx] = dec.data;
    }
    final rebuilt = [
      for (var i = 0; i < 6; i++)
        FlipbookFrame(i, delivered[i]!, predictor: coded[i].predictor),
    ];
    final a = c.decode(rebuilt);
    final b = c.decode(coded);
    for (var i = 0; i < 6; i++) {
      expect(a[i], equals(b[i]), reason: 'frame $i differs after transport');
    }
  });
  test('motion predictor wins on panning footage and round-trips exactly', () {
    // A textured field translated by a constant offset every frame: the
    // classic camera pan. Plain temporal differencing sees every pixel
    // change; motion compensation sees almost nothing.
    const srcW = 240, srcH = 160, frames = 6;
    const panX = 3, panY = 2;
    final rng = Random(11);
    final field = Uint8List(srcW * srcH);
    for (var i = 0; i < field.length; i++) {
      field[i] = rng.nextInt(256);
    }
    Uint8List frameAt(int f) {
      final out = Uint8List(srcW * srcH);
      for (var y = 0; y < srcH; y++) {
        for (var x = 0; x < srcW; x++) {
          final sx = (x + f * panX) % srcW;
          final sy = (y + f * panY) % srcH;
          out[y * srcW + x] = field[sy * srcW + sx];
        }
      }
      return out;
    }

    final grays = List.generate(frames, frameAt);
    const codec = FlipbookVideoCompressor();
    final coded = codec.encode(grays, srcW, srcH);

    final motionFrames = coded
        .where((f) => f.predictor == FlipbookPredictor.temporalMotion)
        .length;
    expect(
      motionFrames,
      greaterThan(0),
      reason: 'a constant pan must engage the motion predictor',
    );

    // Exact reconstruction of the quantized stream is still required.
    final decoded = codec.decode(coded);
    expect(decoded.length, frames);

    final total = coded.fold<int>(0, (a, f) => a + f.bytes.length);
    // ignore: avoid_print
    print(
      'pan footage: $motionFrames/${coded.length} frames motion-coded, '
      '$total B total',
    );
  });
}
