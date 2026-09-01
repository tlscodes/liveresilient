/// Per-layer redundancy allocation under a byte budget — the unit that makes
/// "the cliff is gone" true instead of relocated.
///
/// Measured basis (cliff_free_probe_test.dart, 2026-08-02): a FIXED redundancy
/// factor of 1.6x decoded zero layers at 50% loss. Continuity only exists when
/// the send factor is a function of the estimated loss. This allocator turns a
/// loss estimate (from [BlindChannelEstimator] / [RedundancyPlanner]) plus a
/// byte budget into per-layer send counts, protecting L0 first and refining
/// with what remains.
///
/// blockSize decision (spec F-1): the framing floor is 5/blockSize, so only
/// blockSize = 55 (9.12%) can meet a 10% clean-channel gate; 48 costs 10.50%.
/// The cliff-free path therefore pins 55 here. The legacy encoder default of
/// 48 (the 53-byte wire contract used by `MediaTransferQueue` and
/// `rateless_stream.dart`) is left untouched — existing lanes depend on it.
library;

import 'dart:math' as math;

import 'blind_channel_estimator.dart';
import 'gf256_rlnc_stream.dart' show generationSize;

/// The plan for one layer: how many RLNC datagrams to send.
class LayerAllocation {
  const LayerAllocation({
    required this.layerIndex,
    required this.blockCount,
    required this.sendCount,
    required this.fullyProtected,
  });

  final int layerIndex;

  /// Source blocks of the layer's generation (what the decoder must rank).
  final int blockCount;

  /// Datagrams the sender should emit. 0 = layer dropped for budget.
  final int sendCount;

  /// True when [sendCount] met the layer's target-success desire; false when
  /// the budget truncated it (best-effort) or dropped it.
  final bool fullyProtected;

  double get factor => blockCount == 0 ? 0 : sendCount / blockCount;
}

class AllocationResult {
  const AllocationResult(this.layers, this.datagramBytes);

  final List<LayerAllocation> layers;
  final int datagramBytes;

  int get totalDatagrams => layers.fold(0, (a, l) => a + l.sendCount);
  int get totalWireBytes => totalDatagrams * datagramBytes;
  int get fullyProtectedLayers =>
      layers.takeWhile((l) => l.fullyProtected).length;
}

/// Allocates send counts per layer, L0 first, under a byte budget.
class LayeredRedundancyAllocator {
  LayeredRedundancyAllocator({this.blockSize = mandatedBlockSize}) {
    if (blockSize < 31 || blockSize > 55) {
      throw ArgumentError.value(blockSize, 'blockSize', 'must be 31..55');
    }
  }

  /// Spec F-1: 55 is the only block size whose framing floor (9.12%) fits
  /// under a 10% clean-channel gate. Datagram = 60 B, exactly the
  /// `SlidingWindowPacker(maxDatagramBytes: 60)` budget.
  static const int mandatedBlockSize = 55;

  final int blockSize;

  /// 4-byte header + payload + 1-byte CRC, matching `RlncEncoder.datagramAt`.
  int get datagramBytes => 4 + blockSize + 1;

  /// Target decode success per layer index (floor applies beyond the list).
  static const List<double> targetSchedule = [0.999, 0.99, 0.95];
  static const double targetFloor = 0.90;

  double targetFor(int layerIndex) => layerIndex < targetSchedule.length
      ? targetSchedule[layerIndex]
      : targetFloor;

  /// Cold-start redundancy law, measured F-3 anchors:
  /// 20% -> 1.5, 50% -> 2.5 (3.0 = 20/20 on L0), 70% -> 4.0, 90% -> 12.0.
  /// factor(p) = 1.2 / (1 - p), L0 gets a 1.25x safety margin.
  static double coldFactor(double lossEstimate, {required bool isL0}) {
    final p = lossEstimate.clamp(0.0, 0.95);
    final base = 1.2 / (1 - p);
    return isL0 ? base * 1.25 : base;
  }

  /// Plans send counts for layers with [blockCounts] source blocks each.
  ///
  /// [estimate] is the channel model (warm path: [RedundancyPlanner] is
  /// authoritative). When null, [lossPrior] drives the cold-start law.
  /// [budgetBytes] caps total wire bytes; L0 is funded first, refinement
  /// layers in order with what remains. A layer whose remaining budget is
  /// below its bare block count is dropped (sending fewer datagrams than
  /// blocks can never decode), and later layers are dropped with it only if
  /// they too cannot fit — each layer is judged independently against the
  /// remaining budget, but budget is spent strictly in layer order.
  AllocationResult allocate({
    required List<int> blockCounts,
    required int budgetBytes,
    GilbertElliottEstimate? estimate,
    double lossPrior = 0.0,
    int plannerTrials = 200,
  }) {
    var remaining = budgetBytes ~/ datagramBytes;
    final out = <LayerAllocation>[];
    for (var i = 0; i < blockCounts.length; i++) {
      final blocks = blockCounts[i];
      if (blocks <= 0) {
        out.add(
          LayerAllocation(
            layerIndex: i,
            blockCount: 0,
            sendCount: 0,
            fullyProtected: true,
          ),
        );
        continue;
      }
      // Cheap lower bound before paying for a Monte-Carlo plan: below the
      // bare block count nothing can decode.
      if (remaining < blocks) {
        out.add(
          LayerAllocation(
            layerIndex: i,
            blockCount: blocks,
            sendCount: 0,
            fullyProtected: false,
          ),
        );
        continue;
      }
      final desired = _desiredSendCount(
        blocks,
        layerIndex: i,
        estimate: estimate,
        lossPrior: lossPrior,
        plannerTrials: plannerTrials,
      );
      final grant = desired <= remaining ? desired : remaining;
      remaining -= grant;
      out.add(
        LayerAllocation(
          layerIndex: i,
          blockCount: blocks,
          sendCount: grant,
          fullyProtected: grant >= desired,
        ),
      );
    }
    return AllocationResult(out, datagramBytes);
  }

  static double _pow(double base, double exp) => math.pow(base, exp).toDouble();

  int _desiredSendCount(
    int blocks, {
    required int layerIndex,
    required GilbertElliottEstimate? estimate,
    required double lossPrior,
    required int plannerTrials,
  }) {
    if (estimate != null) {
      // MEASURED FINDING (channel-sim harness, 2026-08-02): the decoder is
      // GENERATIONAL — a layer of `blocks` source blocks splits into
      // ceil(blocks/generationSize) generations, coded symbols round-robin
      // across them (`generationForEsi`), and the layer only decodes when
      // EVERY generation reaches full rank. `RedundancyPlanner` counts
      // total arrivals, so on multi-generation layers it systematically
      // under-provisions: in the first harness run L2 (4 gens) and L3
      // (14 gens) missed their targets at every loss point. The plan must
      // therefore be per-generation: target^(1/gens) per generation, plan
      // the largest generation, and scale by the round-robin fan-out.
      final planner = RedundancyPlanner(estimate);
      final target = targetFor(layerIndex);
      final gens = (blocks + generationSize - 1) ~/ generationSize;
      int planned;
      if (gens == 1) {
        planned = planner.planSendCount(
          blocks,
          targetSuccess: target,
          trials: plannerTrials,
        );
      } else {
        final perGenTarget = _pow(target, 1 / gens);
        final kGen = planner.planSendCount(
          generationSize,
          targetSuccess: perGenTarget,
          trials: plannerTrials,
        );
        // Sends split as: each generation gets its own systematic blocks
        // plus 1/gens of the coded tail — so the tail must fund the
        // neediest (full-size) generation gens times over. +2 per
        // generation covers the ~0.4% GF(256) rank epsilon the planner's
        // arrival criterion does not see.
        planned = blocks + gens * ((kGen - generationSize) + 2);
      }
      // The measured L0 margin still applies on top of the planner: a stale
      // estimate must not take L0 with it (spec gate C13's 20 pp drill).
      return layerIndex == 0 ? (planned * 1.25).ceil() : planned;
    }
    final f = coldFactor(lossPrior, isL0: layerIndex == 0);
    return (blocks * f).ceil();
  }
}
