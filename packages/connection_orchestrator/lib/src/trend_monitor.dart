/// Proactive trend watch: predicts where a lane's health is HEADING, not
/// just where it is, so the fabric can act before the failure instead of
/// after it.
///
/// Keeps a short sliding window of (time, score) samples per lane and fits
/// a least-squares slope — deterministic, a few multiplications, no
/// randomness. A lane that still scores 0.6 but has been sliding steeply
/// for the last few samples gets flagged while the call is still alive.
library;

/// Verdict for one lane's trajectory.
enum TrendVerdict {
  /// Not enough samples yet to judge.
  unknown,

  /// Flat or improving.
  steady,

  /// Falling, but the projection stays above the floor for now.
  slipping,

  /// Projected to cross the failure floor within the horizon.
  failingSoon,
}

class _Series {
  final List<int> times = [];
  final List<double> scores = [];
}

/// Per-lane linear trend estimator over a sliding sample window.
class TrendMonitor {
  TrendMonitor({
    this.window = 8,
    this.horizonMs = 10000,
    this.floor = 0.2,
    this.slipSlopePerSec = -0.01,
  }) : assert(window >= 3, 'need at least 3 samples for a trend');

  /// Samples kept per lane.
  final int window;

  /// How far ahead the projection looks.
  final int horizonMs;

  /// Score below which a lane counts as failed.
  final double floor;

  /// Slope (score units per second) below which a lane is "slipping".
  final double slipSlopePerSec;

  final Map<String, _Series> _series = {};

  /// Records one observed score sample for a lane.
  void observe(String laneId, double score, {required int nowMs}) {
    final s = _series.putIfAbsent(laneId, _Series.new);
    s.times.add(nowMs);
    s.scores.add(score);
    if (s.times.length > window) {
      s.times.removeAt(0);
      s.scores.removeAt(0);
    }
  }

  /// Least-squares slope in score units per second; null before 3 samples.
  double? slopePerSec(String laneId) {
    final s = _series[laneId];
    if (s == null || s.times.length < 3) return null;
    final n = s.times.length;
    final t0 = s.times.first;
    var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0;
    for (var i = 0; i < n; i++) {
      final x = (s.times[i] - t0) / 1000.0;
      final y = s.scores[i];
      sumX += x;
      sumY += y;
      sumXY += x * y;
      sumXX += x * x;
    }
    final denom = n * sumXX - sumX * sumX;
    if (denom == 0) return 0;
    return (n * sumXY - sumX * sumY) / denom;
  }

  /// Score projected [horizonMs] ahead of the newest sample.
  double? projectedScore(String laneId) {
    final s = _series[laneId];
    final slope = slopePerSec(laneId);
    if (s == null || slope == null) return null;
    return s.scores.last + slope * (horizonMs / 1000.0);
  }

  /// The verdict the fabric acts on.
  TrendVerdict verdict(String laneId) {
    final slope = slopePerSec(laneId);
    final projected = projectedScore(laneId);
    if (slope == null || projected == null) return TrendVerdict.unknown;
    if (projected <= floor) return TrendVerdict.failingSoon;
    if (slope <= slipSlopePerSec) return TrendVerdict.slipping;
    return TrendVerdict.steady;
  }

  /// Drops a lane's history (e.g. on unregister).
  void forget(String laneId) => _series.remove(laneId);
}
