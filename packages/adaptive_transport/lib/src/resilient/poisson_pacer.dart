import 'dart:math';

/// Pure, deterministic-with-seed interval generator that paces outgoing
/// sends via a Poisson process: successive inter-send gaps are drawn from
/// an exponential distribution whose mean is [meanIntervalMs]. This avoids
/// the fixed-cadence fingerprint of a strict periodic timer while keeping
/// the long-run average send rate exactly `1 / meanIntervalMs`.
///
/// Not tied to any transport lane or timer — callers drive their own
/// `Timer`/`Future.delayed` loop using [nextIntervalMs].
class PoissonPacer {
  PoissonPacer({
    this.meanIntervalMs = 125,
    Random? random,
  })  : assert(meanIntervalMs > 0, 'meanIntervalMs must be positive'),
        _random = random ?? Random();

  /// Mean inter-send interval, in milliseconds.
  final double meanIntervalMs;

  final Random _random;

  /// Draws the next inter-send interval from an exponential distribution
  /// with rate `1 / meanIntervalMs`, using inverse-transform sampling:
  /// `-mean * ln(1 - U)` for `U` uniform on `[0, 1)`.
  ///
  /// Always strictly positive: `_random.nextDouble()` is in `[0, 1)`, so
  /// `1 - u` is in `(0, 1]` and `ln(1 - u)` is finite and `<= 0`.
  int nextIntervalMs() {
    final u = _random.nextDouble();
    final raw = -meanIntervalMs * log(1 - u);
    // Guard the pathological U -> 0 tail (raw ~ 0) with a 1ms floor so
    // callers never receive a zero-length gap.
    final ms = raw.round();
    return ms < 1 ? 1 : ms;
  }
}
