#!/usr/bin/env python3
"""Phase 5 proof: layered delivery gives a preview long before completion.

Measures, on the same hostile channel as the integration test, how many
seconds pass before the receiver holds something it can show. Sending the
photo as one object cannot beat its own completion time; sending it as
layers should surface the coarse level far earlier.
"""
import pathlib
import sys

TEST = pathlib.Path(
    "/Users/behnam/Downloads/voice_call_kit_v3/packages/connection_orchestrator"
    "/test/resilient_media_transport_test.dart"
)

CASE = '''
  test('layered photo: a viewable preview lands long before the full '
      'pyramid completes, on the same hostile channel', () {
    const imgC = LowRateImageCompressor();
    const w = 640, h = 480, ch = 4;
    final px = Uint8List(w * h * ch);
    for (var i = 0; i < px.length; i++) {
      // A gradient with a soft disc, so the pyramid has real structure.
      final p = i ~/ ch;
      final x = p % w, y = p ~/ w;
      final dx = x - w ~/ 2, dy = y - h ~/ 2;
      final disc = (dx * dx + dy * dy) < 90000 ? 90 : 0;
      px[i] = ((x + y) ~/ 4 + disc) & 0xFF;
    }
    final levels = imgC.encodeProgressive(px, w, h, ch);
    final layers = levels.map((l) => l.bytes).toList();

    int runToCompletion({required bool layered}) {
      final rng = Random(5);
      final ge = GilbertElliottLossSimulator(p: 0.04, r: 0.1, seed: 8);
      final transport = ResilientMediaTransport(
          queue: MediaTransferQueue(spareBudgetBytesPerSecond: 500));
      if (layered) {
        transport.sendLayered(layers, MediaType.photo);
      } else {
        final joined = BytesBuilder();
        for (final l in layers) {
          joined.add(l);
        }
        transport.send(joined.toBytes(), MediaType.photo);
      }
      final decoders = <int, RatelessDecoder>{};
      var firstUsableMs = -1;
      _voiceTicks(120000, (nowMs, speaking) {
        if (firstUsableMs >= 0) return;
        for (final d in transport.queue
            .tick(nowMs: nowMs, voiceIsSpeaking: speaking)) {
          if (rng.nextDouble() < 0.60 || ge.shouldDrop()) continue;
          final dec =
              decoders.putIfAbsent(d.transferId, RatelessDecoder.new);
          dec.addDatagram(d.bytes);
          if (dec.isComplete && firstUsableMs < 0) {
            final media = ResilientMediaTransport.receive(dec);
            // Layered: the coarse layer alone is renderable. Monolithic:
            // nothing is renderable until the single transfer finishes.
            if (!media.isLayer || media.isFirstLayer) {
              firstUsableMs = nowMs;
            }
          }
        }
      });
      return firstUsableMs;
    }

    final monolithic = runToCompletion(layered: false);
    final layeredMs = runToCompletion(layered: true);

    expect(monolithic, greaterThan(0), reason: 'baseline never completed');
    expect(layeredMs, greaterThan(0), reason: 'no layer ever decoded');
    expect(layeredMs, lessThan(monolithic),
        reason: 'layering must surface a preview earlier than the '
            'monolithic transfer completes');
    // ignore: avoid_print
    print('layered photo: first viewable at ${(layeredMs / 1000)
        .toStringAsFixed(1)}s vs ${(monolithic / 1000).toStringAsFixed(1)}s '
        'monolithic (${layers.length} layers, '
        '${layers.map((l) => l.length).join('+')} B)');
  });
}'''

text = TEST.read_text(encoding="utf-8").rstrip()
if not text.endswith("}"):
    sys.exit("unexpected tail")
TEST.write_text(text[: text.rfind("}")] + CASE.lstrip("\n") + "\n",
                encoding="utf-8")
print(f"patched {TEST.name}")
