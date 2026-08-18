/// Simulated-channel harness for cliff-free coding (spec gate C13 shape).
///
/// Sweeps loss 0..0.9 across several seeds with the REAL units end to end:
/// RlncEncoder -> LayeredRedundancyAllocator (estimator-driven) -> lossy
/// channel -> CliffFreeReassembler. Reports, per (loss, seed): delivered
/// bytes to first decodable L0, layers decoded, and the area under the
/// layers-vs-bytes curve; compares against a same-bytes in-order baseline.
/// Worst case across seeds is what is asserted — never the mean.
@TestOn('vm')
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/src/blind_channel_estimator.dart';
import 'package:connection_orchestrator/src/cliff_free_reassembler.dart';
import 'package:connection_orchestrator/src/gf256_rlnc_stream.dart';
import 'package:connection_orchestrator/src/layered_redundancy_allocator.dart';
import 'package:test/test.dart';

const _bs = LayeredRedundancyAllocator.mandatedBlockSize; // 55

List<Uint8List> _layers() => [
  Uint8List.fromList(List.generate(3 * 1024, (i) => (i * 7) & 0xFF)), // L0
  Uint8List.fromList(List.generate(12 * 1024, (i) => (i * 11) & 0xFF)),
  Uint8List.fromList(List.generate(48 * 1024, (i) => (i * 13) & 0xFF)),
  Uint8List.fromList(List.generate(192 * 1024, (i) => (i * 17) & 0xFF)),
];

GilbertElliottEstimate _memoryless(double loss) =>
    GilbertElliottEstimate(0.5, 0.5, loss, loss);

class _RunResult {
  int bytesSent = 0;
  int bytesDelivered = 0;
  int bytesToFirstL0 = -1; // delivered bytes when L0 decoded; -1 = never
  int usableLayers = 0;
  double auc = 0; // area under usable/layerCount vs delivered-bytes, in [0,1]
}

/// Sends per the allocation, L0 first (design intent), datagrams within a
/// layer shuffled (order carries no meaning), each dropped independently
/// with probability [loss].
_RunResult _runLayered(
  List<Uint8List> layers,
  AllocationResult plan,
  double loss,
  Random rng,
) {
  final r = _RunResult();
  final reasm = CliffFreeReassembler(layerCount: layers.length);
  final encs = [for (final l in layers) RlncEncoder(l, blockSize: _bs)];
  // Total bytes that WILL be delivered is unknown up front; normalize the
  // AUC by bytes sent (the spend), so wasted redundancy costs area.
  var qualityArea = 0.0;
  var lastQuality = 0.0;
  var lastAt = 0;
  for (var li = 0; li < layers.length; li++) {
    final send = plan.layers[li].sendCount;
    final order = [for (var i = 0; i < send; i++) i]..shuffle(rng);
    for (final esi in order) {
      final d = encs[li].datagramAt(esi);
      r.bytesSent += d.length;
      if (rng.nextDouble() < loss) continue;
      r.bytesDelivered += d.length;
      reasm.addDatagram(li, d);
      final q = reasm.usableLayerCount / layers.length;
      if (q != lastQuality) {
        qualityArea += lastQuality * (r.bytesDelivered - lastAt);
        lastQuality = q;
        lastAt = r.bytesDelivered;
        if (reasm.usableLayerCount >= 1 && r.bytesToFirstL0 < 0) {
          r.bytesToFirstL0 = r.bytesDelivered;
        }
      }
    }
  }
  qualityArea += lastQuality * (r.bytesDelivered - lastAt);
  r.usableLayers = reasm.usableLayerCount;
  r.auc = r.bytesDelivered == 0 ? 0 : qualityArea / r.bytesDelivered;
  // Exactness: every usable layer is byte-identical to its source.
  for (var li = 0; li < r.usableLayers; li++) {
    if (!_eq(reasm.layerData(li), layers[li])) {
      throw StateError('decoded layer $li differs from source');
    }
  }
  return r;
}

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Baseline: the same object flat, in order, no repair symbols, resent in
/// cyclic rounds until the SAME byte budget is spent. Quality is 0 until
/// every block has arrived at least once (the cliff), then 1.
_RunResult _runInOrderBaseline(
  List<Uint8List> layers,
  int byteBudget,
  double loss,
  Random rng,
) {
  final r = _RunResult();
  final flat = Uint8List.fromList([for (final l in layers) ...l]);
  final blocks = (flat.length / _bs).ceil();
  const datagram = 4 + _bs + 1;
  final have = List<bool>.filled(blocks, false);
  var got = 0;
  var i = 0;
  var completeAt = -1;
  while (r.bytesSent + datagram <= byteBudget) {
    r.bytesSent += datagram;
    final blk = i % blocks;
    i++;
    if (rng.nextDouble() < loss) continue;
    r.bytesDelivered += datagram;
    if (!have[blk]) {
      have[blk] = true;
      got++;
      if (got == blocks && completeAt < 0) completeAt = r.bytesDelivered;
    }
  }
  if (completeAt >= 0) {
    r.usableLayers = layers.length;
    r.bytesToFirstL0 = completeAt; // first usable ANYTHING is completion
    r.auc = r.bytesDelivered == 0
        ? 0
        : (r.bytesDelivered - completeAt) / r.bytesDelivered;
  }
  return r;
}

void main() {
  group('cliff-free simulated channel sweep', () {
    test('loss sweep 0..0.9, 5 seeds: table, worst case, baseline compare',
        () {
      final layers = _layers();
      final alloc = LayeredRedundancyAllocator();
      final encs = [for (final l in layers) RlncEncoder(l, blockSize: _bs)];
      final blockCounts = [for (final e in encs) e.blockCount];
      final rawBytes = layers.fold<int>(0, (a, l) => a + l.length);

      // ignore: avoid_print
      print('loss | worstL0bytes | worstLayers | worstAUC | baseLayers | '
          'baseAUC | sent/raw');
      for (var loss10 = 0; loss10 <= 9; loss10++) {
        final loss = loss10 / 10;
        final plan = alloc.allocate(
          blockCounts: blockCounts,
          budgetBytes: 1 << 31,
          estimate: _memoryless(loss),
          plannerTrials: 100,
        );
        var worstL0 = -1;
        var worstLayers = 999;
        var worstAuc = 2.0;
        var worstBaseLayers = 999;
        var worstBaseAuc = 2.0;
        var sent = 0;
        for (var seed = 0; seed < 5; seed++) {
          final r =
              _runLayered(layers, plan, loss, Random(7000 + seed));
          final b = _runInOrderBaseline(
              layers, r.bytesSent, loss, Random(7000 + seed));
          sent = r.bytesSent;
          if (r.bytesToFirstL0 > worstL0) worstL0 = r.bytesToFirstL0;
          if (r.usableLayers < worstLayers) worstLayers = r.usableLayers;
          if (r.auc < worstAuc) worstAuc = r.auc;
          if (b.usableLayers < worstBaseLayers) {
            worstBaseLayers = b.usableLayers;
          }
          if (b.auc < worstBaseAuc) worstBaseAuc = b.auc;
        }
        // ignore: avoid_print
        print('${(loss * 100).round().toString().padLeft(3)}% | '
            '${worstL0.toString().padLeft(11)} | '
            '${worstLayers.toString().padLeft(11)} | '
            '${worstAuc.toStringAsFixed(3).padLeft(8)} | '
            '${worstBaseLayers.toString().padLeft(10)} | '
            '${worstBaseAuc.toStringAsFixed(3).padLeft(7)} | '
            '${(sent / rawBytes).toStringAsFixed(2)}x');

        // C13 core: estimator-driven allocation decodes L0 at EVERY loss
        // point, worst seed — the cliff does not relocate.
        expect(worstL0, greaterThan(0),
            reason: 'L0 must decode at ${loss * 100}% loss on every seed');
        expect(worstLayers, greaterThanOrEqualTo(1));
        // The target schedule is 0.999/0.99/0.95/0.90 — refinement layers
        // are ALLOWED to miss occasionally by design, so the worst-seed
        // assertion is on the protected prefix, not on all four layers.
        if (loss <= 0.5) {
          expect(worstLayers, greaterThanOrEqualTo(2),
              reason: 'L0 (0.999) and L1 (0.99) must both survive up to '
                  '50% loss on every seed');
        }
        // The layered path beats the same-bytes in-order baseline on AUC
        // whenever the channel is lossy at all.
        if (loss >= 0.2) {
          expect(worstAuc, greaterThan(worstBaseAuc),
              reason: 'same spend, lossy channel: layered must dominate '
                  'in-order on area under the quality curve');
        }
      }
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('red-line exhibit: fixed 1.6x still collapses at 50% loss', () {
      // Kept deliberately (spec C13): if this ever PASSES the sweep, the
      // sweep got too easy. Fixed factor, 50% loss -> L0 dead.
      final layers = _layers();
      final encs = [for (final l in layers) RlncEncoder(l, blockSize: _bs)];
      var l0Failures = 0;
      for (var seed = 0; seed < 5; seed++) {
        final rng = Random(9000 + seed);
        final reasm = CliffFreeReassembler(layerCount: layers.length);
        for (var li = 0; li < layers.length; li++) {
          final send = (encs[li].blockCount * 1.6).ceil();
          for (var i = 0; i < send; i++) {
            if (rng.nextDouble() < 0.5) continue;
            reasm.addDatagram(li, encs[li].datagramAt(i));
          }
        }
        if (reasm.usableLayerCount == 0) l0Failures++;
      }
      expect(l0Failures, greaterThan(0),
          reason: 'a fixed factor must fail somewhere in the sweep — that '
              'failure is the finding the allocator exists to fix');
    });

    test('stale-estimate drill: 20 pp low estimate, L0 margin still holds',
        () {
      // Spec C13 second clause: estimate deliberately 20 percentage points
      // below true loss; the 1.25x L0 margin must keep L0 alive in >= 70%
      // of trials.
      final l0 = _layers().first;
      final enc = RlncEncoder(l0, blockSize: _bs);
      final alloc = LayeredRedundancyAllocator();
      const trueLoss = 0.5;
      final plan = alloc.allocate(
        blockCounts: [enc.blockCount],
        budgetBytes: 1 << 30,
        estimate: _memoryless(trueLoss - 0.20),
      );
      var ok = 0;
      const trials = 20;
      for (var t = 0; t < trials; t++) {
        final rng = Random(4000 + t);
        final dec = RlncDecoder();
        for (var i = 0; i < plan.layers[0].sendCount; i++) {
          if (rng.nextDouble() < trueLoss) continue;
          dec.addDatagram(enc.datagramAt(i));
          if (dec.isComplete) break;
        }
        if (dec.isComplete) ok++;
      }
      // ignore: avoid_print
      print('stale-estimate drill: L0 decoded $ok/$trials '
          '(sendCount ${plan.layers[0].sendCount}, '
          'blocks ${enc.blockCount})');
      expect(ok / trials, greaterThanOrEqualTo(0.70));
    });
  });
}
