/// Path continuity for the live call: the active media path is scored with
/// `adaptive_transport`'s EWMA health model ([ChannelHealth] via
/// [PathSelector]), and when the whole candidate set goes unhealthy the
/// monitor asks the call to run its normal reconnect/ICE-restart recovery.
///
/// The media path is exposed to the selector as a [TransportChannel] whose
/// `send` is a health probe (not a data send): it reads the RTC stats
/// counters and reports packet-loss/RTT deltas as a [SendResult], so the
/// selector's ranking, failover, and per-path circuit breakers all apply
/// unchanged to the call's network path.
library;

import 'dart:async';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:media_webrtc/media_webrtc.dart';

/// Reads the latest raw RTC counters of the live peer connection; null when
/// no connection exists yet (or it has been torn down).
typedef RtcCountersReader = Future<RawRtcCounters?> Function();

/// A [TransportChannel] view of a live WebRTC media path.
class WebRtcPathChannel implements TransportChannel {
  WebRtcPathChannel({
    this.name = 'webrtc-media',
    required this._readCounters,
    this._lossDegradedFraction = 0.15,
    ChannelHealth? health,
  }) : health =
           health ??
           ChannelHealth(reliabilityPrior: 0.95, bandwidth: 0.9, rttMs: 100);

  @override
  final String name;

  @override
  final ChannelHealth health;

  final RtcCountersReader _readCounters;
  final double _lossDegradedFraction;

  int? _lastPacketsReceived;
  int? _lastPacketsLost;

  @override
  Future<bool> probe() async {
    try {
      return await _readCounters() != null;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<SendResult> send(List<int> payload) async {
    final RawRtcCounters? counters;
    try {
      counters = await _readCounters();
    } catch (error) {
      return SendResult(SendStatus.unavailable, error: error);
    }
    if (counters == null) {
      return const SendResult(SendStatus.unavailable);
    }

    final rttSeconds = counters.currentRoundTripTimeSeconds;
    final rttMs = rttSeconds == null ? null : (rttSeconds * 1000).round();

    final previousReceived = _lastPacketsReceived;
    final previousLost = _lastPacketsLost;
    _lastPacketsReceived = counters.packetsReceived;
    _lastPacketsLost = counters.packetsLost;

    if (previousReceived == null || previousLost == null) {
      // First read establishes the delta baseline; the connection exists
      // and reports stats, which is itself a successful probe.
      return SendResult(SendStatus.ok, rttMs: rttMs);
    }

    final receivedDelta = counters.packetsReceived - previousReceived;
    // Cumulative RTCP loss can regress slightly between reports.
    final lostDelta = (counters.packetsLost - previousLost).clamp(0, 1 << 31);
    final total = receivedDelta + lostDelta;
    if (total <= 0) {
      // Nothing flowed since the last probe: on a live audio call packets
      // arrive continuously, so a silent interval cannot confirm delivery.
      return const SendResult(SendStatus.transient);
    }

    final lossFraction = lostDelta / total;
    if (lossFraction >= _lossDegradedFraction) {
      return SendResult(
        SendStatus.transient,
        rttMs: rttMs,
        error: StateError(
          'packet loss ${(lossFraction * 100).toStringAsFixed(0)}%',
        ),
      );
    }
    return SendResult(SendStatus.ok, rttMs: rttMs);
  }

  @override
  Future<void> dispose() async {}
}

/// Periodically probes the candidate paths through a [PathSelector] and
/// fires [onUnhealthy] once per healthy→unhealthy transition of the whole
/// set.
///
/// A single degraded path never fires: the selector fails over to the next
/// ranked path and the call continues on it. The monitor escalates only
/// when no path delivered this cycle AND either (a) a follow-up
/// [PathSelector.refresh] probe pass still leaves the selector offline
/// (hard drop — fires immediately), or (b) delivery has failed
/// [unhealthyAfterConsecutiveFailures] cycles in a row even though probes
/// answer (sustained heavy loss — reachable but unusable). Each escalation
/// fires exactly once until a path delivers again (or [start] re-arms it).
class PathHealthMonitor {
  PathHealthMonitor({
    required PathSelector Function() createSelector,
    required this._onUnhealthy,
    this.interval = const Duration(seconds: 2),
    this.unhealthyAfterConsecutiveFailures = 3,
  }) : _createSelector = createSelector,
       _selector = createSelector();

  static const List<int> _probePayload = <int>[0x70];

  final PathSelector Function() _createSelector;
  PathSelector _selector;
  final Future<void> Function() _onUnhealthy;
  final Duration interval;

  /// Failed delivery cycles in a row that count as unhealthy even while
  /// path probes still succeed.
  final int unhealthyAfterConsecutiveFailures;

  Timer? _timer;
  bool _healthy = true;
  bool _evaluating = false;
  bool _disposed = false;
  int _consecutiveFailures = 0;

  /// Whether the periodic probe timer is currently running.
  bool get isRunning => _timer != null;

  /// Starts (or restarts) periodic probing and re-arms the unhealthy
  /// latch — callers start the monitor when the call (re)enters its
  /// connected phase, so a fresh phase gets a fresh escalation budget.
  ///
  /// When the previous run escalated (the latch is still down), the call
  /// that gets here rode a reconnect/ICE restart onto a FRESH network
  /// path — so the selector is rebuilt too. Without this, the old path's
  /// tripped circuit breaker (whose cool-down backs off up to minutes, and
  /// which ignores probe successes while open) would keep scoring the new
  /// healthy path as down and re-escalate in a recovery storm.
  void start() {
    if (_disposed) return;
    if (!_healthy) {
      unawaited(_selector.dispose());
      _selector = _createSelector();
    }
    _healthy = true;
    _consecutiveFailures = 0;
    _timer ??= Timer.periodic(interval, (_) {
      unawaited(evaluateNow());
    });
  }

  /// Stops periodic probing (keeps health/breaker state for the next
  /// [start]).
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One probe cycle; exposed so tests drive the monitor without timers.
  Future<void> evaluateNow() async {
    if (_disposed || _evaluating) return;
    _evaluating = true;
    try {
      final delivered = await _selector.sendChunk(_probePayload);
      if (delivered) {
        _healthy = true;
        _consecutiveFailures = 0;
        return;
      }
      _consecutiveFailures++;
      // No path delivered. Probe every path (this is what lets a tripped
      // breaker half-open and a recovered path return to service) before
      // declaring the whole set down.
      await _selector.refresh();
      if (_selector.online &&
          _consecutiveFailures < unhealthyAfterConsecutiveFailures) {
        return;
      }
      if (_healthy) {
        _healthy = false;
        await _onUnhealthy();
      }
    } finally {
      _evaluating = false;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    stop();
    await _selector.dispose();
  }
}

/// Production wiring: one [WebRtcPathChannel] over the live peer
/// connection's stats counters, ranked/breakered by a [PathSelector].
PathHealthMonitor buildWebRtcPathHealthMonitor({
  required RtcCountersReader readCounters,
  required Future<void> Function() onUnhealthy,
  Duration interval = const Duration(seconds: 2),
}) {
  return PathHealthMonitor(
    createSelector: () => PathSelector(<TransportChannel>[
      WebRtcPathChannel(readCounters: readCounters),
    ]),
    onUnhealthy: onUnhealthy,
    interval: interval,
  );
}
