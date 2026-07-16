/// Network-quality policy layer: maps observed connectivity signals to a
/// high-level [NetworkQualityProfile] with hysteresis, and exposes the
/// per-profile operating knobs (retry limit, operation timeout, media
/// rung, relay preference, telemetry sampling rate, battery budget hint).
///
/// Relationship to [NetworkConditionProfile]: that enum (path_selector)
/// drives *routing redundancy* and stays untouched; this policy is the
/// higher-level operating mode that maps ONTO it via
/// [NetworkQualityPolicy.toConditionProfile], so PathSelector integration
/// is one call ([toConditionPolicy] → `PathSelector.applyPolicy`).
///
/// Pure decision object: no timers, no platform reads. Time enters only
/// through the caller-supplied `nowMs` (monotonic milliseconds), and the
/// battery budget is a *hint knob* handed to platform layers — pure Dart
/// cannot measure a real battery.
library;

import 'path_selector.dart';

/// High-level operating profile derived from observed network quality.
///
/// Declaration order is severity order (used by the hysteresis logic):
/// [healthy] < [constrained] < [degraded] < [locallyConnected].
enum NetworkQualityProfile {
  /// Gateway reachable, low loss and RTT: full functionality.
  healthy,

  /// Gateway reachable but elevated loss or RTT: trim bandwidth and
  /// battery spend, prefer relayed media for stability.
  constrained,

  /// Gateway reachable only barely (heavy loss / high RTT), or fully
  /// offline with no local peers: audio-first survival mode.
  degraded,

  /// Gateway unreachable AND local peers reachable: consent-gated
  /// local-only continuity mode. Requires BOTH conditions — absence of a
  /// gateway alone is not enough to enable local-only operation.
  locallyConnected,
}

/// Observed end-to-end packet-loss bucket (bucketing is the caller's
/// measurement concern; the policy consumes classes, not raw percentages).
enum PacketLossBucket {
  /// Loss low enough not to affect media quality.
  low,

  /// Noticeable loss: media adaptation and extra retries pay off.
  elevated,

  /// Heavy loss / partial outage territory.
  heavy,
}

/// Observed round-trip-time bucket.
enum RttBucket {
  /// Interactive-grade latency.
  low,

  /// Elevated latency: still usable, but tighten expectations.
  elevated,

  /// Latency high enough to break interactive media.
  high,
}

/// One observation of the network as seen by the caller's probes.
class QualitySignals {
  final PacketLossBucket loss;
  final RttBucket rtt;

  /// Whether the signaling gateway / internet infrastructure is reachable.
  final bool gatewayReachable;

  /// Whether consent-gated local peers are currently reachable.
  final bool localPeersReachable;

  const QualitySignals({
    required this.loss,
    required this.rtt,
    required this.gatewayReachable,
    required this.localPeersReachable,
  });

  @override
  String toString() =>
      'QualitySignals(loss: ${loss.name}, rtt: ${rtt.name}, '
      'gateway: $gatewayReachable, localPeers: $localPeersReachable)';
}

/// Media operating rung for the current profile.
///
/// Mirrors the `MediaProfile` semantics of the media adaptation layer
/// (high → audioOnly rungs) without importing that package: the media
/// layer treats this as a *ceiling* on its own ladder.
enum MediaModeRung {
  /// Full audio+video (media layer may pick any of its rungs).
  fullVideo,

  /// Video capped to a reduced rung; audio protected.
  reducedVideo,

  /// Video disabled; the whole budget protects audio.
  audioOnly,
}

/// Relay preference for call path establishment.
enum RelayPreference {
  /// Try direct paths first; relay is the fallback.
  preferDirect,

  /// Go through a relay first: on lossy/slow links a relay path is
  /// usually more stable than repeated direct-path renegotiation.
  preferRelay,

  /// No infrastructure available: only consent-gated local peer links.
  localOnly,
}

/// The full knob row a [NetworkQualityProfile] maps to.
class NetworkQualityKnobs {
  /// Maximum retry attempts for signaling/data operations. Kept aligned
  /// with [NetworkConditionPolicy.redundancy]'s `maxFailover` so the two
  /// layers never disagree on persistence.
  final int retryLimit;

  /// Budget for a single network operation (send / negotiate / probe).
  final Duration operationTimeout;

  /// Media ceiling for the media adaptation layer.
  final MediaModeRung mediaMode;

  final RelayPreference relayPreference;

  /// Fraction of telemetry events to sample, in (0, 1].
  final double telemetrySamplingRate;

  /// Duty-cycle hint in (0, 1] for battery-sensitive background work
  /// (keepalives, probes, presence ticks). A *hint knob* for platform
  /// layers — pure Dart cannot read the real battery.
  final double batteryBudgetHint;

  const NetworkQualityKnobs({
    required this.retryLimit,
    required this.operationTimeout,
    required this.mediaMode,
    required this.relayPreference,
    required this.telemetrySamplingRate,
    required this.batteryBudgetHint,
  });

  @override
  String toString() =>
      'NetworkQualityKnobs(retry: $retryLimit, '
      'timeout: ${operationTimeout.inMilliseconds}ms, '
      'media: ${mediaMode.name}, relay: ${relayPreference.name}, '
      'telemetry: $telemetrySamplingRate, battery: $batteryBudgetHint)';
}

/// Hysteresis tuning for [NetworkQualityPolicy].
///
/// [RelayPool] applies a relative *score* margin because its inputs are
/// continuous; profiles are categorical, so the equivalent anti-flapping
/// margin here is a *dwell time*: a candidate profile must persist for a
/// hold window before it replaces the current one. Escalation (toward a
/// worse profile) is allowed to react faster than recovery, mirroring the
/// "easy to enter safety, slow to leave it" stance of the media layer.
class NetworkQualityPolicyConfig {
  /// How long a *worse* candidate profile must persist before adoption.
  final Duration escalateHold;

  /// How long a *better* candidate profile must persist before adoption.
  final Duration recoverHold;

  const NetworkQualityPolicyConfig({
    this.escalateHold = const Duration(seconds: 2),
    this.recoverHold = const Duration(seconds: 5),
  });

  void _validate() {
    if (escalateHold.isNegative) {
      throw ArgumentError.value(escalateHold, 'escalateHold');
    }
    if (recoverHold.isNegative) {
      throw ArgumentError.value(recoverHold, 'recoverHold');
    }
  }
}

/// Single source of truth mapping observed signals → profile → knobs.
///
/// Feed observations via [observe] with a caller-supplied monotonic
/// `nowMs`; read the hysteresis-stable [profile] and its [knobs]; bridge
/// to the routing layer with [toConditionPolicy].
class NetworkQualityPolicy {
  final NetworkQualityPolicyConfig config;

  NetworkQualityProfile _current;
  NetworkQualityProfile? _candidate;
  int _candidateSinceMs = 0;
  int _lastNowMs;

  NetworkQualityPolicy({
    this.config = const NetworkQualityPolicyConfig(),
    NetworkQualityProfile initialProfile = NetworkQualityProfile.healthy,
  }) : _current = initialProfile,
       _lastNowMs = -1 << 62 {
    config._validate();
  }

  /// Current hysteresis-stable profile.
  NetworkQualityProfile get profile => _current;

  /// Knob row for the current profile.
  NetworkQualityKnobs get knobs => knobsFor(_current);

  /// Raw (hysteresis-free) classification of one observation.
  ///
  /// The `locallyConnected` gate requires BOTH `gatewayReachable == false`
  /// AND `localPeersReachable == true`; offline with no local peers is
  /// [NetworkQualityProfile.degraded].
  static NetworkQualityProfile classify(QualitySignals s) {
    if (!s.gatewayReachable) {
      return s.localPeersReachable
          ? NetworkQualityProfile.locallyConnected
          : NetworkQualityProfile.degraded;
    }
    if (s.loss == PacketLossBucket.heavy || s.rtt == RttBucket.high) {
      return NetworkQualityProfile.degraded;
    }
    if (s.loss == PacketLossBucket.elevated || s.rtt == RttBucket.elevated) {
      return NetworkQualityProfile.constrained;
    }
    return NetworkQualityProfile.healthy;
  }

  /// Ingests one observation at monotonic time [nowMs] and returns the
  /// (possibly updated) stable profile.
  ///
  /// A candidate profile different from the current one is adopted only
  /// after it persists for [NetworkQualityPolicyConfig.escalateHold]
  /// (worse candidate) or [NetworkQualityPolicyConfig.recoverHold]
  /// (better candidate). Any raw flip — back to the current profile or to
  /// a different candidate — restarts the dwell clock, so oscillating
  /// signals can never flap the stable profile.
  ///
  /// Throws [ArgumentError] if [nowMs] moves backwards.
  NetworkQualityProfile observe(QualitySignals signals, {required int nowMs}) {
    if (nowMs < _lastNowMs) {
      throw ArgumentError.value(
        nowMs,
        'nowMs',
        'must be monotonic (last was $_lastNowMs)',
      );
    }
    _lastNowMs = nowMs;

    final raw = classify(signals);
    if (raw == _current) {
      _candidate = null;
      return _current;
    }
    if (raw != _candidate) {
      _candidate = raw;
      _candidateSinceMs = nowMs;
    }
    final hold = raw.index > _current.index
        ? config.escalateHold
        : config.recoverHold;
    if (nowMs - _candidateSinceMs >= hold.inMilliseconds) {
      _current = raw;
      _candidate = null;
    }
    return _current;
  }

  /// Knob table — every row is asserted in tests. `retryLimit`
  /// intentionally equals the bridged [NetworkConditionPolicy]'s
  /// `maxFailover` (2/3/4/6) so policy and router agree on persistence.
  static NetworkQualityKnobs knobsFor(NetworkQualityProfile profile) {
    switch (profile) {
      case NetworkQualityProfile.healthy:
        return const NetworkQualityKnobs(
          retryLimit: 2,
          operationTimeout: Duration(seconds: 5),
          mediaMode: MediaModeRung.fullVideo,
          relayPreference: RelayPreference.preferDirect,
          telemetrySamplingRate: 1.0,
          batteryBudgetHint: 1.0,
        );
      case NetworkQualityProfile.constrained:
        return const NetworkQualityKnobs(
          retryLimit: 3,
          operationTimeout: Duration(seconds: 8),
          mediaMode: MediaModeRung.reducedVideo,
          relayPreference: RelayPreference.preferRelay,
          telemetrySamplingRate: 0.5,
          batteryBudgetHint: 0.6,
        );
      case NetworkQualityProfile.degraded:
        return const NetworkQualityKnobs(
          retryLimit: 4,
          operationTimeout: Duration(seconds: 12),
          mediaMode: MediaModeRung.audioOnly,
          relayPreference: RelayPreference.preferRelay,
          telemetrySamplingRate: 0.25,
          batteryBudgetHint: 0.35,
        );
      case NetworkQualityProfile.locallyConnected:
        return const NetworkQualityKnobs(
          retryLimit: 6,
          operationTimeout: Duration(seconds: 15),
          mediaMode: MediaModeRung.audioOnly,
          relayPreference: RelayPreference.localOnly,
          telemetrySamplingRate: 0.1,
          batteryBudgetHint: 0.2,
        );
    }
  }

  /// Bridge to the routing layer's [NetworkConditionProfile]:
  /// healthy → stable, constrained → congested, degraded → degraded,
  /// locallyConnected → isolated.
  NetworkConditionProfile toConditionProfile() => conditionProfileFor(_current);

  /// Static form of the bridge table (asserted row-by-row in tests).
  static NetworkConditionProfile conditionProfileFor(
    NetworkQualityProfile profile,
  ) {
    switch (profile) {
      case NetworkQualityProfile.healthy:
        return NetworkConditionProfile.stable;
      case NetworkQualityProfile.constrained:
        return NetworkConditionProfile.congested;
      case NetworkQualityProfile.degraded:
        return NetworkConditionProfile.degraded;
      case NetworkQualityProfile.locallyConnected:
        return NetworkConditionProfile.isolated;
    }
  }

  /// One-call PathSelector integration:
  /// `selector.applyPolicy(policy.toConditionPolicy())`.
  NetworkConditionPolicy toConditionPolicy() =>
      NetworkConditionPolicy(toConditionProfile());
}
