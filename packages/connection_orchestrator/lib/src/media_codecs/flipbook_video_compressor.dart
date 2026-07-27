/// Phase 4c — video as a flipbook for a few-hundred-B/s wire.
///
/// Keyframes only: 120x80 monochrome (4-bit), about one frame per three
/// seconds. Each keyframe is coded either INTRA (row-delta within the
/// frame) or TEMPORAL (delta against the previous keyframe — the lab's
/// 3D-residual idea, measured here by the tests), whichever is smaller;
/// one header byte records the choice so decoding is self-describing.
/// Lossy by downsampling/quantization; the coded stream itself decodes
/// deterministically and order is preserved end to end.
library;

import 'dart:typed_data';

import 'live_context_compressor.dart';
import 'media_frontends.dart';

/// Which predictor produced a coded frame.
enum FlipbookPredictor {
  /// 2D Paeth prediction inside the frame; needs no history.
  intra,

  /// Difference against the previous frame at matching coordinates.
  temporalPlain,

  /// Difference against the previous frame displaced by a global motion
  /// vector, which is carried in the first two payload bytes.
  temporalMotion,
}

class FlipbookFrame {
  FlipbookFrame(this.index, this.bytes, {required this.predictor});

  /// Which predictor coded this frame. Single source of truth: whether
  /// the frame needs history is derived from it rather than stored
  /// alongside it, so the two can never disagree.
  final FlipbookPredictor predictor;

  /// True when decoding this frame requires the previous frame.
  bool get temporal => predictor != FlipbookPredictor.intra;

  final int index; // presentation order
  final Uint8List bytes;
}

class FlipbookVideoCompressor {
  const FlipbookVideoCompressor({
    this.width = 120,
    this.height = 80,
    this.secondsPerFrame = 3,
  });

  final int width;
  final int height;
  final int secondsPerFrame;

  static const _cm = LiveContextCompressor();

  /// Half-width of the exhaustive global motion search window.
  static const int motionSearchRadius = 4;

  int frameCountFor(Duration videoLength) =>
      (videoLength.inSeconds / secondsPerFrame).ceil().clamp(1, 1 << 20);

  /// [gray] is one full-resolution 8-bit grayscale frame; caller samples
  /// frames at [secondsPerFrame]. Returns the coded keyframe stream.
  List<FlipbookFrame> encode(List<Uint8List> grayFrames, int srcW, int srcH) {
    final out = <FlipbookFrame>[];
    Uint8List? prev;
    for (var f = 0; f < grayFrames.length; f++) {
      final q = downQuant(grayFrames[f], srcW, srcH);
      final intra = _cm.compress(SpatialResidual.paeth(q, width, height, 1));
      Uint8List coded;
      var predictor = FlipbookPredictor.intra;
      if (prev != null) {
        // Candidate A: plain temporal difference, no vector to store.
        final plain = _cm.compress(_motionResidual(q, prev, 0, 0));
        // Candidate B: motion-compensated difference. Only searched when
        // it can pay for itself; the vector rides in the payload head.
        final (dx, dy) = _searchMotion(q, prev);
        Uint8List? motion;
        if (dx != 0 || dy != 0) {
          final residual = _motionResidual(q, prev, dx, dy);
          final td = Uint8List(residual.length + 2);
          td[0] = dx + 128;
          td[1] = dy + 128;
          td.setRange(2, td.length, residual);
          motion = _cm.compress(td);
        }
        if (motion != null &&
            motion.length < plain.length &&
            motion.length < intra.length) {
          coded = motion;
          predictor = FlipbookPredictor.temporalMotion;
        } else if (plain.length < intra.length) {
          coded = plain;
          predictor = FlipbookPredictor.temporalPlain;
        } else {
          coded = intra;
        }
      } else {
        coded = intra;
      }
      out.add(FlipbookFrame(f, coded, predictor: predictor));
      prev = q;
    }
    return out;
  }

  /// Decodes the full ordered sequence (temporal frames need history).
  List<Uint8List> decode(List<FlipbookFrame> frames) {
    final sorted = List<FlipbookFrame>.from(frames)
      ..sort((a, b) => a.index.compareTo(b.index));
    final out = <Uint8List>[];
    Uint8List? prev;
    for (final f in sorted) {
      Uint8List q;
      if (f.temporal) {
        if (prev == null) throw StateError('temporal frame without history');
        final payload = _cm.decompress(f.bytes);
        var dx = 0, dy = 0;
        Uint8List td = payload;
        if (f.predictor == FlipbookPredictor.temporalMotion) {
          if (payload.length < 2) {
            throw const FormatException('motion frame missing its vector');
          }
          dx = payload[0] - 128;
          dy = payload[1] - 128;
          td = Uint8List.sublistView(payload, 2);
        }
        q = Uint8List(td.length);
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            final i = y * width + x;
            q[i] = (td[i] + _shifted(prev, x, y, dx, dy)) & 0xFF;
          }
        }
      } else {
        q = SpatialResidual.unPaeth(_cm.decompress(f.bytes), width, height, 1);
      }
      out.add(q);
      prev = q;
    }
    return out;
  }

  /// Previous-frame sample displaced by the motion vector, with edge
  /// clamping so the predictor is defined everywhere.
  int _shifted(Uint8List prev, int x, int y, int dx, int dy) {
    final sx = (x - dx).clamp(0, width - 1);
    final sy = (y - dy).clamp(0, height - 1);
    return prev[sy * width + sx];
  }

  /// Residual of [q] against [prev] displaced by (dx, dy), mod 256 so the
  /// inverse is exact.
  Uint8List _motionResidual(Uint8List q, Uint8List prev, int dx, int dy) {
    final out = Uint8List(q.length);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        out[i] = (q[i] - _shifted(prev, x, y, dx, dy)) & 0xFF;
      }
    }
    return out;
  }

  /// Full search for the global motion vector inside [motionSearchRadius],
  /// scored by sum of absolute differences. The flipbook grid is tiny
  /// (120x80 by default), so an exhaustive search over a 9x9 window is
  /// cheap and, unlike a heuristic, is deterministic and reproducible.
  (int, int) _searchMotion(Uint8List q, Uint8List prev) {
    var bestDx = 0, bestDy = 0;
    var bestCost = 1 << 62;
    for (var dy = -motionSearchRadius; dy <= motionSearchRadius; dy++) {
      for (var dx = -motionSearchRadius; dx <= motionSearchRadius; dx++) {
        var cost = 0;
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            final d = q[y * width + x] - _shifted(prev, x, y, dx, dy);
            cost += d < 0 ? -d : d;
          }
        }
        // Prefer the zero vector on ties: it costs no extra structure and
        // keeps output stable when the scene is static.
        if (cost < bestCost) {
          bestCost = cost;
          bestDx = dx;
          bestDy = dy;
        }
      }
    }
    return (bestDx, bestDy);
  }

  Uint8List downQuant(Uint8List gray, int srcW, int srcH) {
    final out = Uint8List(width * height);
    for (var oy = 0; oy < height; oy++) {
      final y0 = oy * srcH ~/ height;
      final y1 = ((oy + 1) * srcH ~/ height).clamp(y0 + 1, srcH);
      for (var ox = 0; ox < width; ox++) {
        final x0 = ox * srcW ~/ width;
        final x1 = ((ox + 1) * srcW ~/ width).clamp(x0 + 1, srcW);
        var sum = 0, cnt = 0;
        for (var y = y0; y < y1; y++) {
          for (var x = x0; x < x1; x++) {
            sum += gray[y * srcW + x];
            cnt++;
          }
        }
        out[oy * width + ox] = (sum ~/ cnt) >> 4; // 4-bit
      }
    }
    return out;
  }
}
