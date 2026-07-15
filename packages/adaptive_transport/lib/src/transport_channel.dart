/// Resilient multi-path transport abstraction.
///
/// Provides a unified contract for independent standards-based transport
/// paths (HTTPS/WSS signaling links, cloud push wake-up, authenticated local
/// peers). The [PathSelector] continuously evaluates path health using
/// EWMA-smoothed metrics and directs traffic with failover and optional
/// redundancy (fanout).
///
/// Ported from v1 `transport_channel.dart`. The EWMA availability model,
/// jitter smoothing, and composite scoring are preserved unchanged. All
/// custom traffic-shaping concepts from v1 were removed: every concrete channel in
/// v2 is a plain, honestly-labelled standard protocol connection.
library;

/// Final status after attempting to deliver a payload chunk.
enum SendStatus {
  /// The path confirmed delivery of this chunk.
  ok,

  /// The receiving side reports it already has this chunk (idempotent
  /// delivery). Distinct from [ok] so callers can track redundancy overlap
  /// produced by fanout, but it still counts as successful delivery.
  duplicate,

  /// A retryable failure (timeout, congestion, 5xx-class condition).
  transient,

  /// The path is down or rejected the request in a non-retryable way.
  unavailable,
}

/// Result of a single delivery attempt on one path.
class SendResult {
  final SendStatus status;

  /// Round-trip time of the attempt in milliseconds, when measurable.
  final int? rttMs;

  /// Underlying error for [SendStatus.transient] / [SendStatus.unavailable].
  final Object? error;

  const SendResult(this.status, {this.rttMs, this.error});

  /// Whether the payload is known to have reached the receiver.
  bool get delivered =>
      status == SendStatus.ok || status == SendStatus.duplicate;

  /// Kept as the v1 spelling; equivalent to [delivered].
  bool get ok => delivered;

  @override
  String toString() =>
      'SendResult(${status.name}${rttMs != null ? ', rtt: ${rttMs}ms' : ''})';
}

/// Real-time health and performance metrics of a transport path.
///
/// All normalized scores are in the range [0, 1] except the raw [rttMs] and
/// [jitterMs] values.
class ChannelHealth {
  /// Exponentially weighted moving average (EWMA) of the recent delivery
  /// success rate. Updated reactively by [observe] after every attempt.
  double availability;

  /// Static prior for the path type's typical end-to-end delivery
  /// reliability, set once per channel implementation. Example: a cloud push
  /// gateway is highly reliable for tiny payloads (high prior) but a local
  /// peer link over a lossy radio deserves a lower prior. This replaces the
  /// v1 field that mixed reliability with traffic-shape concerns; v2 scores
  /// reliability only.
  final double reliabilityPrior;

  /// Relative bandwidth estimate normalized to [0, 1].
  final double bandwidth;

  /// Whether the path is currently considered degraded or unavailable due to
  /// severe loss, congestion, or an explicit failure signal.
  bool pathDegraded;

  /// EWMA-smoothed round-trip time in milliseconds.
  int rttMs;

  /// EWMA-smoothed RTT variation in milliseconds, consumed by the media
  /// adaptation layer.
  int jitterMs;

  ChannelHealth({
    this.availability = 1.0,
    required this.reliabilityPrior,
    required this.bandwidth,
    this.pathDegraded = false,
    this.rttMs = 9999,
    this.jitterMs = 50,
  }) {
    if (reliabilityPrior < 0.0 || reliabilityPrior > 1.0) {
      throw RangeError.range(
        reliabilityPrior,
        0,
        1,
        'reliabilityPrior',
      );
    }
    if (bandwidth < 0.0 || bandwidth > 1.0) {
      throw RangeError.range(bandwidth, 0, 1, 'bandwidth');
    }
  }

  /// Composite live score used by the router for ranking and selection.
  ///
  /// Formula (unchanged from v1):
  /// `availability × reliabilityPrior × bandwidthFactor × rttFactor`
  double score() {
    if (pathDegraded || availability <= 0) return 0.0;
    final rttFactor = 1.0 / (1.0 + rttMs / 1000.0);
    final bwFactor = 0.2 + 0.8 * bandwidth;
    return availability * reliabilityPrior * bwFactor * rttFactor;
  }

  /// Updates health metrics after each send attempt using reactive EWMA.
  ///
  /// This is one of the core strengths of the v1 design and is preserved
  /// verbatim: it stays stable under high jitter while preventing
  /// unnecessary path flapping.
  void observe(SendResult r, {double alpha = 0.3}) {
    if (alpha <= 0.0 || alpha > 1.0) {
      throw RangeError.range(alpha, 0, 1, 'alpha');
    }

    final success = r.delivered ? 1.0 : 0.0;
    availability = (1 - alpha) * availability + alpha * success;

    if (r.status == SendStatus.unavailable) {
      pathDegraded = true;
    } else if (r.delivered) {
      pathDegraded = false;
    }

    final sampleRtt = r.rttMs;
    if (sampleRtt != null) {
      // Jitter smoothing (core strength preserved from v1).
      final newJitter = (sampleRtt - rttMs).abs();
      rttMs = ((1 - alpha) * rttMs + alpha * sampleRtt).round();
      jitterMs = ((1 - alpha) * jitterMs + alpha * newJitter).round();
    }
  }
}

/// Abstract transport path contract.
///
/// Every concrete channel (WSS signaling link, push wake-up channel,
/// authenticated local peer link, ...) implements this interface so the
/// router can treat them uniformly.
abstract class TransportChannel {
  /// Stable, human-readable path name used in telemetry and logs.
  String get name;

  /// Live health metrics for this path.
  ChannelHealth get health;

  /// Probes current reachability / liveness of the path.
  Future<bool> probe();

  /// Sends a payload chunk. Returns a [SendResult] with status and optional
  /// measured round-trip time.
  Future<SendResult> send(List<int> payload);

  /// Releases resources held by the path.
  Future<void> dispose();
}
