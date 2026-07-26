#!/usr/bin/env python3
"""Phase 4c final: three predictors compete per frame, smallest wins.

Motion compensation is a large win on panning footage and pure overhead
on a static scene, so making it unconditional trades one case for the
other. Instead all three candidates are coded and the smallest is kept:

  intra            2D Paeth within the frame
  temporalPlain    difference against the previous frame, no vector
  temporalMotion   difference against the previous frame displaced by a
                   searched global vector (vector stored in the frame)

The chosen predictor is recorded on the frame, so the decoder never has
to guess, and the output can never exceed what the previous two-way
implementation produced.
"""
import pathlib
import sys

TARGET = pathlib.Path(
    "/Users/behnam/Downloads/voice_call_kit_v3/packages/connection_orchestrator"
    "/lib/src/media_codecs/flipbook_video_compressor.dart"
)

OLD_CLASS = '''class FlipbookFrame {
  FlipbookFrame(this.index, this.bytes, {required this.temporal});'''

NEW_CLASS = '''/// Which predictor produced a coded frame.
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
  FlipbookFrame(this.index, this.bytes,
      {required this.temporal,
      this.predictor =
          FlipbookPredictor.intra})
      : assert(temporal == (predictor != FlipbookPredictor.intra));

  /// Which predictor coded this frame.
  final FlipbookPredictor predictor;'''

OLD_ENC = '''        final (dx, dy) = _searchMotion(q, prev);
        final residual = _motionResidual(q, prev, dx, dy);
        // The vector rides at the head of the payload and goes through
        // the entropy coder with everything else: on static or steadily
        // panning footage it is the same two bytes every frame, so the
        // model reduces it to a few bits instead of a flat 2-byte tax.
        final td = Uint8List(residual.length + 2);
        td[0] = dx + 128;
        td[1] = dy + 128;
        td.setRange(2, td.length, residual);
        final tdc = _cm.compress(td);
        if (tdc.length < intra.length) {
          coded = tdc;
          temporal = true;
        } else {
          coded = intra;
        }
      } else {
        coded = intra;
      }'''

NEW_ENC = '''        // Candidate A: plain temporal difference, no vector to store.
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
          temporal = true;
          predictor = FlipbookPredictor.temporalMotion;
        } else if (plain.length < intra.length) {
          coded = plain;
          temporal = true;
          predictor = FlipbookPredictor.temporalPlain;
        } else {
          coded = intra;
        }
      } else {
        coded = intra;
      }'''

OLD_MODEVAR = '''      Uint8List coded;
      var temporal = false;'''
NEW_MODEVAR = '''      Uint8List coded;
      var temporal = false;
      var predictor = FlipbookPredictor.intra;'''

OLD_ADD = '''      out.add(FlipbookFrame(f, coded, temporal: temporal));'''
NEW_ADD = '''      out.add(FlipbookFrame(f, coded,
          temporal: temporal, predictor: predictor));'''

OLD_DEC = '''      if (f.temporal) {
        if (prev == null) throw StateError('temporal frame without history');
        final payload = _cm.decompress(f.bytes);
        if (payload.length < 2) {
          throw const FormatException('temporal frame missing motion header');
        }
        final dx = payload[0] - 128;
        final dy = payload[1] - 128;
        final td = Uint8List.sublistView(payload, 2);
        q = Uint8List(td.length);
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            final i = y * width + x;
            q[i] = (td[i] + _shifted(prev, x, y, dx, dy)) & 0xFF;
          }
        }
      } else {'''

NEW_DEC = '''      if (f.temporal) {
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
      } else {'''

text = TARGET.read_text(encoding="utf-8")
for old, new in (
    (OLD_CLASS, NEW_CLASS),
    (OLD_MODEVAR, NEW_MODEVAR),
    (OLD_ENC, NEW_ENC),
    (OLD_ADD, NEW_ADD),
    (OLD_DEC, NEW_DEC),
):
    if old not in text:
        sys.exit(f"anchor not found:\n{old[:70]}")
    text = text.replace(old, new, 1)
TARGET.write_text(text, encoding="utf-8")
print(f"patched {TARGET.name}")
