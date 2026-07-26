#!/usr/bin/env python3
"""Phase 4c cleanup: predictor is the single source of truth.

Carrying both a `temporal` bool and a `predictor` enum let the two
disagree -- the assertion added to catch that fired immediately from a
caller that reconstructed a frame with only the bool. Removing the
duplicate state makes the disagreement unrepresentable: `temporal` is now
derived from `predictor`.
"""
import pathlib
import sys

PKG = pathlib.Path(
    "/Users/behnam/Downloads/voice_call_kit_v3/packages/connection_orchestrator"
)
SRC = PKG / "lib/src/media_codecs/flipbook_video_compressor.dart"
TEST = PKG / "test/flipbook_video_compressor_test.dart"

OLD_CLASS = '''class FlipbookFrame {
  FlipbookFrame(this.index, this.bytes,
      {required this.temporal,
      this.predictor =
          FlipbookPredictor.intra})
      : assert(temporal == (predictor != FlipbookPredictor.intra));

  /// Which predictor coded this frame.
  final FlipbookPredictor predictor;'''

NEW_CLASS = '''class FlipbookFrame {
  FlipbookFrame(this.index, this.bytes, {required this.predictor});

  /// Which predictor coded this frame. Single source of truth: whether
  /// the frame needs history is derived from it rather than stored
  /// alongside it, so the two can never disagree.
  final FlipbookPredictor predictor;

  /// True when decoding this frame requires the previous frame.
  bool get temporal => predictor != FlipbookPredictor.intra;'''

OLD_MODEVAR = '''      Uint8List coded;
      var temporal = false;
      var predictor = FlipbookPredictor.intra;'''
NEW_MODEVAR = '''      Uint8List coded;
      var predictor = FlipbookPredictor.intra;'''

OLD_ADD = '''      out.add(FlipbookFrame(f, coded,
          temporal: temporal, predictor: predictor));'''
NEW_ADD = '''      out.add(FlipbookFrame(f, coded, predictor: predictor));'''

src = SRC.read_text(encoding="utf-8")
for old, new in ((OLD_CLASS, NEW_CLASS), (OLD_MODEVAR, NEW_MODEVAR),
                 (OLD_ADD, NEW_ADD)):
    if old not in src:
        sys.exit(f"src anchor not found:\n{old[:70]}")
    src = src.replace(old, new, 1)

# Drop the now-redundant `temporal = true;` assignments in the encoder.
src = src.replace("          coded = motion;\n          temporal = true;\n",
                  "          coded = motion;\n", 1)
src = src.replace("          coded = plain;\n          temporal = true;\n",
                  "          coded = plain;\n", 1)
if "temporal = true;" in src:
    sys.exit("stale temporal assignment left in encoder")
SRC.write_text(src, encoding="utf-8")
print(f"patched {SRC.name}")

OLD_T = "        FlipbookFrame(i, delivered[i]!, temporal: coded[i].temporal)"
NEW_T = "        FlipbookFrame(i, delivered[i]!, predictor: coded[i].predictor)"
test = TEST.read_text(encoding="utf-8")
if OLD_T not in test:
    sys.exit("test anchor not found")
TEST.write_text(test.replace(OLD_T, NEW_T, 1), encoding="utf-8")
print(f"patched {TEST.name}")
