/// PathSelector — adaptive multi-path routing engine for data, voice, and
/// video delivery under unstable and degraded network conditions.
///
/// Core responsibilities (ported from v1, algorithm preserved):
/// - continuous ranking of available paths by live health score;
/// - failover with a configurable attempt budget;
/// - optional fanout redundancy for high-packet-loss environments;
/// - a real-time telemetry stream for UI / monitoring integration.
///
/// Network-condition-driven redundancy recommendations (the v1
/// `region_policy` redundancy table) are folded in here as
/// [NetworkConditionPolicy] so the router package is self-contained.
library;

import 'dart:async';

import 'package:clock/clock.dart' hide Clock;

import 'circuit_breaker.dart';
import 'transport_channel.dart';

/// Observed network condition classes used to tune redundancy.
enum NetworkConditionProfile {
  /// Normal connectivity: conserve battery and bandwidth.
  stable,

  /// Elevated loss/latency: allow one extra failover attempt.
  congested,

  /// Heavy loss or partial outage: add fanout redundancy.
  degraded,

  /// Infrastructure unreachable: rely on every remaining path, including
  /// consent-gated local peer links.
  isolated,
}

/// Maps an observed [NetworkConditionProfile] to recommended redundancy
/// levels for the [PathSelector]. Ported from v1 `region_policy.dart`
/// (`redundancy()` table preserved verbatim); the v1 location-based scoring
/// was dropped because v2 policies react only to measured conditions.
class NetworkConditionPolicy {
  final NetworkConditionProfile profile;

  const NetworkConditionPolicy(this.profile);

  /// Recommended redundancy settings under the current condition profile.
  ({int maxFailover, int fanout}) redundancy() {
    switch (profile) {
      case NetworkConditionProfile.stable:
        return (maxFailover: 2, fanout: 1);
      case NetworkConditionProfile.congested:
        return (maxFailover: 3, fanout: 1);
      case NetworkConditionProfile.degraded:
        return (maxFailover: 4, fanout: 2);
      case NetworkConditionProfile.isolated:
        return (maxFailover: 6, fanout: 3);
    }
  }

  /// Convenience: a [RouterConfig] carrying this profile's redundancy.
  RouterConfig toRouterConfig() {
    final r = redundancy();
    return RouterConfig(maxFailover: r.maxFailover, fanout: r.fanout);
  }
}

/// Router tuning parameters.
class RouterConfig {
  /// Maximum number of delivery attempts across ranked paths before the
  /// router gives up on a chunk.
  final int maxFailover;

  /// Number of top-ranked paths that transmit the same chunk concurrently.
  /// `fanout > 1` markedly increases delivery probability in >30% packet
  /// loss scenarios at the cost of extra bandwidth.
  final int fanout;

  const RouterConfig({this.maxFailover = 4, this.fanout = 1});

  void _validate() {
    if (maxFailover < 1) {
      throw RangeError.range(maxFailover, 1, null, 'maxFailover');
    }
    if (fanout < 1) {
      throw RangeError.range(fanout, 1, null, 'fanout');
    }
  }
}

/// A single telemetry event emitted by the router.
///
/// Values are already privacy-safe: they contain path names and numeric
/// health metrics, never payload bytes or remote addresses.
typedef RouterTelemetryEvent = Map<String, Object?>;

class PathSelector {
  final List<TransportChannel> _channels;

  /// Per-channel circuit breakers. A path whose breaker is open is skipped
  /// during ranking until its cool-down elapses (half-open probe).
  final Map<TransportChannel, CircuitBreaker> _breakers;

  RouterConfig config;

  final _telemetryController =
      StreamController<RouterTelemetryEvent>.broadcast();

  Stream<RouterTelemetryEvent> get telemetryStream =>
      _telemetryController.stream;

  PathSelector(
    List<TransportChannel> channels, {
    this.config = const RouterConfig(),
    CircuitBreakerConfig breakerConfig = const CircuitBreakerConfig(),
  }) : _channels = List.unmodifiable(channels),
       _breakers = {
         for (final c in channels) c: CircuitBreaker(config: breakerConfig),
       } {
    config._validate();
  }

  /// Applies a redundancy recommendation, e.g. when the app detects that
  /// conditions moved from `stable` to `degraded`.
  void applyPolicy(NetworkConditionPolicy policy) {
    final next = policy.toRouterConfig();
    next._validate();
    config = next;
  }

  List<TransportChannel> _ranked() {
    final live = _channels
        .where((c) => _breakers[c]!.allowsRequest())
        .toList(growable: true);
    live.sort((a, b) => b.health.score().compareTo(a.health.score()));
    return live;
  }

  void _emit(String kind, TransportChannel c, SendResult? r) {
    if (_telemetryController.isClosed) return;
    _telemetryController.add(<String, Object?>{
      'kind': kind,
      'channel': c.name,
      'score': c.health.score(),
      'availability': c.health.availability,
      'pathDegraded': c.health.pathDegraded,
      'breaker': _breakers[c]!.state.name,
      'rttMs': r?.rttMs ?? c.health.rttMs,
      'jitterMs': c.health.jitterMs,
      'status': r?.status.name,
      'timestamp': clock.now().toIso8601String(),
    });
  }

  /// Sends a single chunk with automatic failover and optional fanout
  /// redundancy.
  ///
  /// This method is the heart of the resilient delivery system (v1 algorithm
  /// preserved). When `fanout > 1` the chunk is sent concurrently on the
  /// top-N paths; success is declared as soon as any path in the batch
  /// confirms delivery (an idempotent [SendStatus.duplicate] response counts
  /// as delivery).
  Future<bool> sendChunk(List<int> payload) async {
    final ranked = _ranked().where((c) => c.health.score() > 0).toList();
    if (ranked.isEmpty) {
      if (_channels.isNotEmpty) _emit('exhausted', _channels.first, null);
      return false;
    }

    final fanout = config.fanout < 1 ? 1 : config.fanout;
    var attempts = 0;

    for (
      var i = 0;
      i < ranked.length && attempts < config.maxFailover;
      i += fanout
    ) {
      // Clamp the batch to the remaining attempt budget: fanout alone can
      // overshoot maxFailover on the last round (e.g. maxFailover=3,
      // fanout=2 would otherwise attempt 4). The documented contract is
      // "at most maxFailover attempts total".
      final remaining = config.maxFailover - attempts;
      final batchSize = fanout < remaining ? fanout : remaining;
      final batch = ranked.skip(i).take(batchSize).toList();
      attempts += batch.length;

      final outcomes = await Future.wait(
        batch.map((ch) async {
          SendResult res;
          try {
            res = await ch.send(payload);
          } catch (e) {
            res = SendResult(SendStatus.transient, error: e);
          }
          ch.health.observe(res);
          if (res.delivered) {
            _breakers[ch]!.recordSuccess();
          } else {
            _breakers[ch]!.recordFailure();
          }
          _emit('send', ch, res);
          return res.delivered;
        }),
      );

      if (outcomes.any((delivered) => delivered)) return true;
    }

    _emit('exhausted', ranked.first, null);
    return false;
  }

  /// Periodic health refresh: probes all paths.
  ///
  /// Used before heavy traffic or on a timer to keep routing decisions
  /// fresh. Probe outcomes nudge availability using the v1 half-life rule.
  Future<void> refresh() async {
    for (final ch in _channels) {
      try {
        final up = await ch.probe();
        if (up) {
          ch.health.pathDegraded = false;
          ch.health.availability += 0.5 * (1.0 - ch.health.availability);
          _breakers[ch]!.recordSuccess();
        } else {
          ch.health.availability *= 0.5;
          _breakers[ch]!.recordFailure();
        }
        _emit('probe', ch, null);
      } catch (_) {
        ch.health.availability *= 0.5;
        _breakers[ch]!.recordFailure();
      }
    }
  }

  /// Whether at least one path is currently usable.
  ///
  /// Side-effect free: reads each breaker's [CircuitBreaker.state] (a pure
  /// view) instead of [CircuitBreaker.allowsRequest], which consumes a
  /// half-open probe slot. A channel counts as available when its breaker
  /// is closed or half-open (not [CircuitState.open]) and its health score
  /// is positive. This can be polled arbitrarily often (e.g. from a UI
  /// health widget) without exhausting `halfOpenMaxProbes` and stranding a
  /// recovering path that real traffic would otherwise be able to probe
  /// back to closed.
  bool get online => _channels.any(
    (c) => _breakers[c]!.state != CircuitState.open && c.health.score() > 0,
  );

  bool _disposed = false;

  /// Idempotent: a second call returns immediately without re-invoking each
  /// channel's [TransportChannel.dispose].
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _telemetryController.close();
    for (final c in _channels) {
      await c.dispose();
    }
  }
}
