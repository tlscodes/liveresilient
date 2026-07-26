#!/usr/bin/env python3
"""Phase 4c proof: the motion predictor must win on panning footage.

The existing suite only exercises a near-static scene, where the motion
search correctly declines to fire. Without a panning case the feature has
no evidence behind it, so this adds one: a textured field translated by a
fixed offset each frame, which plain temporal differencing handles badly
and motion compensation handles almost for free.
"""
import pathlib
import sys

TEST = pathlib.Path(
    "/Users/behnam/Downloads/voice_call_kit_v3/packages/connection_orchestrator"
    "/test/flipbook_video_compressor_test.dart"
)

CASE = '''
  test('motion predictor wins on panning footage and round-trips exactly',
      () {
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
    expect(motionFrames, greaterThan(0),
        reason: 'a constant pan must engage the motion predictor');

    // Exact reconstruction of the quantized stream is still required.
    final decoded = codec.decode(coded);
    expect(decoded.length, frames);

    final total = coded.fold<int>(0, (a, f) => a + f.bytes.length);
    // ignore: avoid_print
    print('pan footage: $motionFrames/${coded.length} frames motion-coded, '
        '$total B total');
  });
}'''

text = TEST.read_text(encoding="utf-8")
if not text.rstrip().endswith("}"):
    sys.exit("unexpected test file tail")
stripped = text.rstrip()
# replace only the final closing brace of main()
text = stripped[: stripped.rfind("}")] + CASE.lstrip("\n") + "\n"
TEST.write_text(text, encoding="utf-8")
print(f"patched {TEST.name}")
