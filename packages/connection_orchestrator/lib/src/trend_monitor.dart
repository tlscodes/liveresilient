/// Proactive trend watch: predicts where a lane's health is HEADING, not
/// just where it is, so the fabric can act before the failure instead of
/// after it.
///
/// Keeps short sliding windows of (time, value) samples per lane — the
/// health score always, plus optional loss / rtt / delivery-rate channels —
/// and fits a least-squares slope per channel. Deterministic, a few
/// multiplications, no randomness. A lane that still scores 0.6 but has
/// been sliding steeply for the last few samples gets flagged while the
/// call is still alive; a lane whose loss and rtt are both climbing gets
/// flagged even when the score has not caught up yet.
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

/// Sliding-window least-squares slope over (timeMs, value) samples for one
/// measurement channel. The single regression implementation shared by the
/// score, loss, rtt and delivery-rate channels.
class _SlopeTracker {
  _SlopeTracker(this.window);

  /// Samples kept before the oldest is dropped.
  final int window;

  final List<int> _times = [];
  final List<double> _values = [];

  void add(int nowMs, double value) {
    _times.add(nowMs);
    _values.add(value);
    if (_times.length > window) {
      _times.removeAt(0);
      _values.removeAt(0);
    }
  }

  int get sampleCount => _times.length;

  /// Time span covered by the held samples; 0 with fewer than 2 samples.
  int get spanMs => _times.length < 2 ? 0 : _times.last - _times.first;

  double? get lastValue => _values.isEmpty ? null : _values.last;

  /// Least-squares slope in value units per second; null before 3 samples.
  double? get slopePerSec {
    final n = _times.length;
    if (n < 3) return null;
    final t0 = _times.first;
    var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0;
    for (var i = 0; i < n; i++) {
      final x = (_times[i] - t0) / 1000.0;
      final y = _values[i];
      sumX += x;
      sumY += y;
      sumXY += x * y;
      sumXX += x * x;
    }
    final denom = n * sumXX - sumX * sumX;
    if (denom == 0) return 0;
    return (n * sumXY - sumX * sumY) / denom;
  }
}

/// The per-channel trackers for one lane.
class _LaneTrend {
  _LaneTrend(int window)
    : score = _SlopeTracker(window),
      loss = _SlopeTracker(window),
      rtt = _SlopeTracker(window),
      deliveryRate = _SlopeTracker(window);

  final _SlopeTracker score;
  final _SlopeTracker loss;
  final _SlopeTracker rtt;
  final _SlopeTracker deliveryRate;
}

/// The measured numbers behind a lane's verdict. Every field is a plain
/// number; a channel's slope is null while that channel has fewer than 3
/// samples.
class TrendEvidence {
  const TrendEvidence({
    required this.scoreSlopePerSec,
    required this.projectedScore,
    required this.lossSlopePerSec,
    required this.rttInflationPerSec,
    required this.deliveryRateSlopePerSec,
    required this.sampleCount,
    required this.windowMs,
  });

  /// Score units gained per second; null before 3 score samples.
  final double? scoreSlopePerSec;

  /// Score projected horizonMs ahead of the newest sample; null before 3
  /// score samples.
  final double? projectedScore;

  /// Loss fraction gained per second; null before 3 loss samples.
  final double? lossSlopePerSec;

  /// Milliseconds of rtt gained per second; null before 3 rtt samples.
  final double? rttInflationPerSec;

  /// Delivery rate gained per second; null before 3 delivery-rate samples.
  final double? deliveryRateSlopePerSec;

  /// Score samples currently held for the lane.
  final int sampleCount;

  /// Time span covered by the held score samples (newest minus oldest);
  /// 0 with fewer than 2 samples.
  final int windowMs;
}

/// A verdict together with the literal reason it was reached and the
/// numbers it was reached from.
class TrendVerdictDetail {
  const TrendVerdictDetail({
    required this.verdict,
    required this.grounds,
    required this.evidence,
  });

  /// The verdict the fabric acts on.
  final TrendVerdict verdict;

  /// Literal statement of the deciding comparison, numbers included,
  /// e.g. 'projectedScore 0.14 <= floor 0.2'.
  final String grounds;

  /// The measured numbers the verdict was reached from.
  final TrendEvidence evidence;
}

/// Per-lane linear trend estimator over sliding sample windows.
class TrendMonitor {
  TrendMonitor({
    this.window = 8,
    this.horizonMs = 10000,
    this.floor = 0.2,
    this.slipSlopePerSec = -0.01,
    this.lossSlopeFailingPerSec = 0.02,
    this.rttInflationFailingMsPerSec = 50.0,
  }) : assert(window >= 3, 'need at least 3 samples for a trend');

  /// Samples kept per lane per channel.
  final int window;

  /// How far ahead the projection looks.
  final int horizonMs;

  /// Score below which a lane counts as failed.
  final double floor;

  /// Slope (score units per second) below which a lane is "slipping".
  final double slipSlopePerSec;

  /// Loss-fraction slope at or above which the joint loss+rtt trigger
  /// counts the loss channel as failing. 0.02/s: loss climbing 2 points
  /// per second sustained across the 10s default horizon adds 20 loss
  /// points, carrying an already-degraded link into blackout-class loss —
  /// the unconditional 50% floor precedent in
  /// apps/reference_app/lib/src/path_health_monitor.dart:101-129 — within
  /// the horizon.
  final double lossSlopeFailingPerSec;

  /// Rtt slope (ms of rtt gained per second) at or above which the joint
  /// loss+rtt trigger counts the rtt channel as failing. 50ms/s: rtt
  /// inflating 50ms per second across the 10s default horizon adds 500ms,
  /// doubling a 500ms link inside the horizon.
  final double rttInflationFailingMsPerSec;

  final Map<String, _LaneTrend> _lanes = {};

  /// Records one observed sample set for a lane. The score is mandatory;
  /// each optional channel feeds its own slope tracker only when supplied.
  void observe(
    String laneId,
    double score, {
    required int nowMs,
    double? lossFraction,
    double? rttMs,
    double? deliveryRate,
  }) {
    final lane = _lanes.putIfAbsent(laneId, () => _LaneTrend(window));
    lane.score.add(nowMs, score);
    if (lossFraction != null) lane.loss.add(nowMs, lossFraction);
    if (rttMs != null) lane.rtt.add(nowMs, rttMs);
    if (deliveryRate != null) lane.deliveryRate.add(nowMs, deliveryRate);
  }

  /// Least-squares score slope in score units per second; null before 3
  /// score samples.
  double? slopePerSec(String laneId) => _lanes[laneId]?.score.slopePerSec;

  /// Score projected [horizonMs] ahead of the newest sample.
  double? projectedScore(String laneId) {
    final lane = _lanes[laneId];
    if (lane == null) return null;
    final slope = lane.score.slopePerSec;
    final last = lane.score.lastValue;
    if (slope == null || last == null) return null;
    return last + slope * (horizonMs / 1000.0);
  }

  /// The measured numbers behind [verdict] for one lane.
  TrendEvidence evidence(String laneId) {
    final lane = _lanes[laneId];
    if (lane == null) {
      return const TrendEvidence(
        scoreSlopePerSec: null,
        projectedScore: null,
        lossSlopePerSec: null,
        rttInflationPerSec: null,
        deliveryRateSlopePerSec: null,
        sampleCount: 0,
        windowMs: 0,
      );
    }
    return TrendEvidence(
      scoreSlopePerSec: lane.score.slopePerSec,
      projectedScore: projectedScore(laneId),
      lossSlopePerSec: lane.loss.slopePerSec,
      rttInflationPerSec: lane.rtt.slopePerSec,
      deliveryRateSlopePerSec: lane.deliveryRate.slopePerSec,
      sampleCount: lane.score.sampleCount,
      windowMs: lane.score.spanMs,
    );
  }

  /// The verdict the fabric acts on. Delegates to [verdictDetail].
  TrendVerdict verdict(String laneId) => verdictDetail(laneId).verdict;

  /// The verdict plus the literal grounds it was reached on and the
  /// numbers behind it.
  ///
  /// Grounds, in order of precedence:
  /// 1. Score projection crossing the floor (exactly the v1 rule).
  /// 2. Joint loss+rtt trigger: loss slope and rtt slope BOTH at or above
  ///    their failing thresholds, each over at least 3 samples. One
  ///    climbing channel alone can be noise; both climbing together is a
  ///    failing link even while the score still reads healthy.
  /// 3. Fewer than 3 score samples: unknown (the v1 rule).
  /// 4. Score slope at or below the slipping threshold (the v1 rule).
  /// 5. Otherwise steady.
  TrendVerdictDetail verdictDetail(String laneId) {
    final e = evidence(laneId);
    final slope = e.scoreSlopePerSec;
    final projected = e.projectedScore;

    if (slope != null && projected != null && projected <= floor) {
      return TrendVerdictDetail(
        verdict: TrendVerdict.failingSoon,
        grounds: 'projectedScore ${_fmt(projected)} <= floor ${_fmt(floor)}',
        evidence: e,
      );
    }

    final lossSlope = e.lossSlopePerSec;
    final rttSlope = e.rttInflationPerSec;
    if (lossSlope != null &&
        rttSlope != null &&
        lossSlope >= lossSlopeFailingPerSec &&
        rttSlope >= rttInflationFailingMsPerSec) {
      return TrendVerdictDetail(
        verdict: TrendVerdict.failingSoon,
        grounds:
            'lossSlopePerSec ${_fmt(lossSlope)} >= '
            '${_fmt(lossSlopeFailingPerSec)} and '
            'rttInflationPerSec ${_fmt(rttSlope)} >= '
            '${_fmt(rttInflationFailingMsPerSec)}',
        evidence: e,
      );
    }

    if (slope == null || projected == null) {
      return TrendVerdictDetail(
        verdict: TrendVerdict.unknown,
        grounds: 'fewer than 3 score samples (${e.sampleCount})',
        evidence: e,
      );
    }

    if (slope <= slipSlopePerSec) {
      return TrendVerdictDetail(
        verdict: TrendVerdict.slipping,
        grounds:
            'scoreSlopePerSec ${_fmt(slope)} <= '
            'slipSlopePerSec ${_fmt(slipSlopePerSec)}',
        evidence: e,
      );
    }

    return TrendVerdictDetail(
      verdict: TrendVerdict.steady,
      grounds:
          'scoreSlopePerSec ${_fmt(slope)} > '
          'slipSlopePerSec ${_fmt(slipSlopePerSec)} and '
          'projectedScore ${_fmt(projected)} > floor ${_fmt(floor)}',
      evidence: e,
    );
  }

  /// Drops a lane's history (e.g. on unregister).
  void forget(String laneId) => _lanes.remove(laneId);

  /// Compact number for grounds strings: 4 decimals, then trailing zeros
  /// and a bare trailing point trimmed, so 0.1400 reads '0.14' and
  /// 60.0000 reads '60'.
  static String _fmt(double v) {
    var s = v.toStringAsFixed(4);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '');
      s = s.replaceFirst(RegExp(r'\.$'), '');
    }
    return s;
  }
}
