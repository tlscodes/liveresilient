/// 2-state Gilbert-Elliott packet-loss chain, the standard model for
/// clustered (burst) loss: real networks fail in contiguous runs of
/// dropped packets, not uniformly at random. Used by the burst-loss and
/// full-system integration tests; deterministic under a seeded RNG.
library;

import 'dart:math';

/// Two states with independent loss rates. Good: low loss. Bad/Burst:
/// near-total loss. Per packet, Good->Bad with probability [p] and
/// Bad->Good with probability [r]; mean burst length = 1/r packets
/// (geometrically distributed).
class GilbertElliottLossSimulator {
  GilbertElliottLossSimulator({
    required this.p,
    required this.r,
    this.goodLossRate = 0.05,
    this.badLossRate = 0.95,
    int seed = 42,
  }) : assert(p > 0 && p < 1),
       assert(r > 0 && r < 1),
       assert(goodLossRate >= 0 && goodLossRate <= 0.05),
       assert(badLossRate >= 0.90 && badLossRate <= 1.0),
       _rng = Random(seed);

  /// Per-packet probability of entering a burst (Good -> Bad).
  final double p;

  /// Per-packet probability of leaving a burst (Bad -> Good);
  /// mean burst length = 1/r packets.
  final double r;

  /// Loss rate while in the Good state.
  final double goodLossRate;

  /// Loss rate while in the Bad (burst) state.
  final double badLossRate;

  final Random _rng;

  bool _inBurst = false;

  /// Diagnostics: completed bursts and their packet lengths.
  final List<int> burstLengths = [];
  int _currentBurstLen = 0;

  /// True if this packet is dropped. Advances the chain one packet.
  bool shouldDrop() {
    if (_inBurst) {
      _currentBurstLen++;
      if (_rng.nextDouble() < r) {
        _inBurst = false;
        burstLengths.add(_currentBurstLen);
        _currentBurstLen = 0;
      }
    } else if (_rng.nextDouble() < p) {
      _inBurst = true;
    }
    final rate = _inBurst ? badLossRate : goodLossRate;
    return _rng.nextDouble() < rate;
  }
}
