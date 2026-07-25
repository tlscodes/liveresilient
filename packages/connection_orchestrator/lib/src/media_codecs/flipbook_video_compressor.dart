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

class FlipbookFrame {
  FlipbookFrame(this.index, this.bytes, {required this.temporal});
  final int index; // presentation order
  final Uint8List bytes;
  final bool temporal;
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

  int frameCountFor(Duration videoLength) =>
      (videoLength.inSeconds / secondsPerFrame).ceil().clamp(1, 1 << 20);

  /// [gray] is one full-resolution 8-bit grayscale frame; caller samples
  /// frames at [secondsPerFrame]. Returns the coded keyframe stream.
  List<FlipbookFrame> encode(List<Uint8List> grayFrames, int srcW, int srcH) {
    final out = <FlipbookFrame>[];
    Uint8List? prev;
    for (var f = 0; f < grayFrames.length; f++) {
      final q = _downQuant(grayFrames[f], srcW, srcH);
      final intra = _cm.compress(
          SpatialResidual.rowDelta(q, width, height, 1));
      Uint8List coded;
      var temporal = false;
      if (prev != null) {
        final td = Uint8List(q.length);
        for (var i = 0; i < q.length; i++) {
          td[i] = (q[i] - prev[i]) & 0xFF;
        }
        final tdc = _cm.compress(td);
        if (tdc.length < intra.length) {
          coded = tdc;
          temporal = true;
        } else {
          coded = intra;
        }
      } else {
        coded = intra;
      }
      out.add(FlipbookFrame(f, coded, temporal: temporal));
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
        final td = _cm.decompress(f.bytes);
        q = Uint8List(td.length);
        for (var i = 0; i < td.length; i++) {
          q[i] = (td[i] + prev[i]) & 0xFF;
        }
      } else {
        q = SpatialResidual.unRowDelta(
            _cm.decompress(f.bytes), width, height, 1);
      }
      out.add(q);
      prev = q;
    }
    return out;
  }

  Uint8List _downQuant(Uint8List gray, int srcW, int srcH) {
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
