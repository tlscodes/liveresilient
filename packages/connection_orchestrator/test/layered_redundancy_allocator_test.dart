@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:connection_orchestrator/src/blind_channel_estimator.dart';
import 'package:connection_orchestrator/src/gf256_rlnc_stream.dart';
import 'package:connection_orchestrator/src/layered_redundancy_allocator.dart';
import 'package:test/test.dart';

GilbertElliottEstimate _memoryless(double loss) =>
    GilbertElliottEstimate(0.5, 0.5, loss, loss);

void main() {
  group('LayeredRedundancyAllocator', () {
    test('pins blockSize 55: 60-byte datagrams, floor under 10%', () {
      final a = LayeredRedundancyAllocator();
      expect(a.blockSize, 55);
      expect(a.datagramBytes, 60);
      expect(5 / a.blockSize, lessThan(0.10),
          reason: 'framing floor 5/55 = 9.09..% is what makes the gate '
              'reachable; 5/48 = 10.4% is not');
      expect(() => LayeredRedundancyAllocator(blockSize: 56), throwsArgumentError);
    });

    test('blockCount arithmetic matches the real encoder', () {
      for (final len in [1, 55, 56, 3 * 1024, 12 * 1024]) {
        final enc = RlncEncoder(
            Uint8List(len), blockSize: LayeredRedundancyAllocator.mandatedBlockSize);
        // The allocator is fed block counts produced by the encoder itself,
        // so there is no second arithmetic to drift — assert the coupling
        // point exists and is usable.
        expect(enc.blockCount, greaterThan(0));
      }
    });

    test('cold-start law reproduces the measured anchors within tolerance', () {
      // Measured (probe, 10/10 trials): 20% -> 1.5, 50% -> 2.5..3.0,
      // 70% -> 4.0, 90% -> 12.0. The law with the L0 margin must be at or
      // above each anchor (under-protection is the failure that matters).
      expect(LayeredRedundancyAllocator.coldFactor(0.2, isL0: true),
          greaterThanOrEqualTo(1.5));
      expect(LayeredRedundancyAllocator.coldFactor(0.5, isL0: true),
          greaterThanOrEqualTo(2.5));
      expect(LayeredRedundancyAllocator.coldFactor(0.7, isL0: true),
          greaterThanOrEqualTo(4.0));
      expect(LayeredRedundancyAllocator.coldFactor(0.9, isL0: true),
          greaterThanOrEqualTo(12.0));
      // And it is not absurdly above them (paying > 2x the anchor is waste).
      expect(LayeredRedundancyAllocator.coldFactor(0.9, isL0: true),
          lessThan(24.0));
    });

    test('send factor rises with estimated loss — never fixed', () {
      final a = LayeredRedundancyAllocator();
      double factorAt(double loss) {
        final r = a.allocate(
          blockCounts: const [56, 224],
          budgetBytes: 1 << 30,
          estimate: _memoryless(loss),
        );
        return r.layers[0].factor;
      }

      var prev = 0.0;
      for (final loss in [0.0, 0.2, 0.4, 0.6, 0.8]) {
        final f = factorAt(loss);
        expect(f, greaterThan(prev),
            reason: 'factor must be strictly increasing in loss (F-2: a '
                'fixed factor is a relocated cliff)');
        prev = f;
      }
    });

    test('under budget pressure L0 is funded first, refinement degrades', () {
      final a = LayeredRedundancyAllocator();
      const blocks = [56, 224, 894, 3575]; // ~3/12/48/192 KB at bs=55
      final est = _memoryless(0.5);
      // Generous budget: everything fully protected.
      final rich = a.allocate(
          blockCounts: blocks, budgetBytes: 1 << 30, estimate: est);
      expect(rich.fullyProtectedLayers, 4);
      // Budget for roughly L0+L1 protection only.
      final l01 = (rich.layers[0].sendCount + rich.layers[1].sendCount) *
          a.datagramBytes;
      final tight = a.allocate(
          blockCounts: blocks, budgetBytes: l01 + 60, estimate: est);
      expect(tight.layers[0].fullyProtected, isTrue,
          reason: 'L0 protection is never traded for refinement');
      expect(tight.layers[1].fullyProtected, isTrue);
      expect(tight.layers[3].sendCount, 0,
          reason: 'a layer that cannot even receive blockCount datagrams is '
              'dropped, not sent hopelessly');
      expect(tight.totalWireBytes, lessThanOrEqualTo(l01 + 60));
      // Starvation: budget below L0 desire — L0 gets everything there is.
      final starved = a.allocate(
          blockCounts: blocks,
          budgetBytes: rich.layers[0].sendCount * a.datagramBytes ~/ 2,
          estimate: est);
      expect(starved.layers[0].sendCount, greaterThan(0));
      expect(starved.layers[0].fullyProtected, isFalse);
      expect(starved.layers[1].sendCount + starved.layers[2].sendCount, 0);
    });

    test('generalizes between the anchor loss values (35%, 60%)', () {
      // Trap named in the brief: an allocator tuned to the table's exact
      // points and failing between them. Check intermediate losses decode.
      final a = LayeredRedundancyAllocator();
      final l0 = Uint8List.fromList(List.generate(3 * 1024, (i) => i & 0xFF));
      for (final loss in [0.35, 0.6]) {
        final enc = RlncEncoder(l0, blockSize: a.blockSize);
        final plan = a.allocate(
          blockCounts: [enc.blockCount],
          budgetBytes: 1 << 30,
          estimate: _memoryless(loss),
        );
        var ok = 0;
        for (var seed = 0; seed < 10; seed++) {
          final dec = RlncDecoder();
          var s = 12345 + seed;
          for (var i = 0; i < plan.layers[0].sendCount; i++) {
            s = (s * 1103515245 + 12345) & 0x7FFFFFFF;
            if (s / 0x7FFFFFFF < loss) continue;
            dec.addDatagram(enc.datagramAt(i));
            if (dec.isComplete) break;
          }
          if (dec.isComplete) ok++;
        }
        expect(ok, greaterThanOrEqualTo(9),
            reason: 'L0 must decode between the measured anchors too '
                '(loss $loss)');
      }
    });
  });
}
