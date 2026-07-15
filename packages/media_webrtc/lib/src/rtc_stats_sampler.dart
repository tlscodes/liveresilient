/// Periodic WebRTC stats sampling.
///
/// Polls a `getStats()`-style source at a fixed interval, converts the
/// cumulative counters of the standard `RTCStatsReport` into per-interval
/// deltas, applies EWMA smoothing, and emits compact [RtcStatsSample]
/// values consumed by `AdaptiveMediaPolicy` and diagnostics UI.
///
/// Only aggregate quality metrics are extracted; remote addresses and
/// identifiers from candidate-pair stats are deliberately not surfaced
/// (privacy-by-design).
///
/// Designed from the v2 blueprint role (no v1 equivalent).
library;

import 'dart:async';

import 'package:clock/clock.dart';

/// Raw cumulative counters read from the platform WebRTC stats report.
///
/// The app layer maps its WebRTC binding's `RTCStatsReport` (e.g. from
/// `flutter_webrtc`) into this structure: `inbound-rtp`, `outbound-rtp`,
/// `remote-inbound-rtp`, and the selected `candidate-pair` entries.
class RawRtcCounters {
  /// Cumulative packets received across inbound RTP streams.
  final int packetsReceived;

  /// Cumulative packets lost as reported by inbound RTP stats.
  final int packetsLost;

  /// Cumulative packets sent across outbound RTP streams.
  final int packetsSent;

  /// Cumulative bytes received (media payload).
  final int bytesReceived;

  /// Cumulative bytes sent (media payload).
  final int bytesSent;

  /// Latest jitter reported for inbound audio/video, in seconds
  /// (as in the stats API).
  final double jitterSeconds;

  /// Latest RTT from the selected candidate pair, in seconds; null when the
  /// pair has no valid measurement yet.
  final double? currentRoundTripTimeSeconds;

  /// Estimated available outgoing bitrate from the selected candidate pair,
  /// in bits per second; null when unavailable.
  final double? availableOutgoingBitrateBps;

  const RawRtcCounters({
    required this.packetsReceived,
    required this.packetsLost,
    required this.packetsSent,
    required this.bytesReceived,
    required this.bytesSent,
    required this.jitterSeconds,
    this.currentRoundTripTimeSeconds,
    this.availableOutgoingBitrateBps,
  });
}

/// Reads the current cumulative counters. Returns null when the peer
/// connection is not yet producing stats.
typedef RtcCountersReader = Future<RawRtcCounters?> Function();

/// One smoothed, per-interval sample.
class RtcStatsSample {
  /// Fraction of packets lost during the interval, in [0, 1].
  final double packetLossFraction;

  /// EWMA-smoothed round-trip time in milliseconds.
  final int rttMs;

  /// EWMA-smoothed jitter in milliseconds.
  final int jitterMs;

  /// Receive throughput during the interval, bits per second.
  final int incomingBitrateBps;

  /// Send throughput during the interval, bits per second.
  final int outgoingBitrateBps;

  /// Congestion-controller estimate of available send bandwidth, bits per
  /// second (0 when the platform did not report one).
  final int availableOutgoingBitrateBps;

  /// Monotonic timestamp of the sample in milliseconds.
  final int timestampMs;

  const RtcStatsSample({
    required this.packetLossFraction,
    required this.rttMs,
    required this.jitterMs,
    required this.incomingBitrateBps,
    required this.outgoingBitrateBps,
    required this.availableOutgoingBitrateBps,
    required this.timestampMs,
  });

  @override
  String toString() =>
      'RtcStatsSample(loss: ${(packetLossFraction * 100).toStringAsFixed(1)}%, '
      'rtt: ${rttMs}ms, jitter: ${jitterMs}ms, '
      'in: ${incomingBitrateBps ~/ 1000}kbps, '
      'out: ${outgoingBitrateBps ~/ 1000}kbps)';
}

class RtcStatsSampler {
  final RtcCountersReader _read;
  final Duration interval;

  /// EWMA smoothing factor for RTT/jitter, matching the transport layer's
  /// reactive-but-stable behavior.
  final double alpha;

  /// Monotonic clock in milliseconds (injectable for tests).
  final int Function() _nowMs;

  final _samplesController = StreamController<RtcStatsSample>.broadcast();

  Timer? _timer;
  bool _tickInFlight = false;
  RawRtcCounters? _previous;
  int? _previousAtMs;
  double _rttMsEwma = 0;
  double _jitterMsEwma = 0;
  bool _hasEwma = false;

  RtcStatsSampler({
    required RtcCountersReader reader,
    this.interval = const Duration(seconds: 2),
    this.alpha = 0.3,
    int Function()? nowMs,
  }) : _read = reader,
       _nowMs = nowMs ?? (() => clock.now().millisecondsSinceEpoch) {
    if (alpha <= 0 || alpha > 1) {
      throw RangeError.range(alpha, 0, 1, 'alpha');
    }
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval');
    }
  }

  Stream<RtcStatsSample> get samples => _samplesController.stream;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _previous = null;
    _previousAtMs = null;
    _hasEwma = false;
  }

  Future<void> _tick() async {
    // Single-flight: Timer.periodic does not await async callbacks, so a slow
    // poll must not overlap the next one (would corrupt _previous deltas).
    if (_tickInFlight) return;
    _tickInFlight = true;
    try {
      await _tickInner();
    } finally {
      _tickInFlight = false;
    }
  }

  Future<void> _tickInner() async {
    final RawRtcCounters? current;
    try {
      current = await _read();
    } catch (_) {
      return; // A failed poll never breaks the sampling loop.
    }
    if (current == null) return;

    final nowMs = _nowMs();
    final previous = _previous;
    final previousAtMs = _previousAtMs;
    _previous = current;
    _previousAtMs = nowMs;

    // Need two polls to compute interval deltas.
    if (previous == null || previousAtMs == null) return;
    final elapsedMs = nowMs - previousAtMs;
    if (elapsedMs <= 0) return;

    final deltaReceived = current.packetsReceived - previous.packetsReceived;
    final deltaLost = current.packetsLost - previous.packetsLost;
    final deltaExpected = deltaReceived + deltaLost;
    // Counter resets (renegotiation) produce negative deltas: skip sample.
    if (deltaReceived < 0 || deltaLost < 0) return;

    final loss = deltaExpected <= 0
        ? 0.0
        : (deltaLost / deltaExpected).clamp(0.0, 1.0);

    final rttSampleMs = (current.currentRoundTripTimeSeconds ?? 0) * 1000.0;
    final jitterSampleMs = current.jitterSeconds * 1000.0;

    if (!_hasEwma) {
      _rttMsEwma = rttSampleMs;
      _jitterMsEwma = jitterSampleMs;
      _hasEwma = true;
    } else {
      if (current.currentRoundTripTimeSeconds != null) {
        _rttMsEwma = (1 - alpha) * _rttMsEwma + alpha * rttSampleMs;
      }
      _jitterMsEwma = (1 - alpha) * _jitterMsEwma + alpha * jitterSampleMs;
    }

    int bitrate(int deltaBytes) =>
        deltaBytes <= 0 ? 0 : (deltaBytes * 8 * 1000 / elapsedMs).round();

    final sample = RtcStatsSample(
      packetLossFraction: loss,
      rttMs: _rttMsEwma.round(),
      jitterMs: _jitterMsEwma.round(),
      incomingBitrateBps: bitrate(
        current.bytesReceived - previous.bytesReceived,
      ),
      outgoingBitrateBps: bitrate(current.bytesSent - previous.bytesSent),
      availableOutgoingBitrateBps: (current.availableOutgoingBitrateBps ?? 0)
          .round(),
      timestampMs: nowMs,
    );

    if (!_samplesController.isClosed) {
      _samplesController.add(sample);
    }
  }

  Future<void> dispose() async {
    stop();
    await _samplesController.close();
  }
}
