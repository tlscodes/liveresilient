/// Multi-region TURN relay pool with health scoring, hysteresis, and
/// failover.
///
/// Phase 6 pure-Dart scope: [RelayPool] models a set of TURN relay
/// *regions* (e.g. `eu-central`, `us-east`), tracks per-region health with
/// the same EWMA philosophy as `ChannelHealth`, wraps each region in a
/// [CircuitBreaker], and selects the best region with hysteresis so
/// marginal score wobbles never flap the selection. Actual coturn
/// deployment/cloud wiring is out of scope; callers feed observations in
/// via [reportSuccess] / [reportFailure] (from probes or live calls).
///
/// Region identity comes from the signed [EndpointManifest]
/// (`relayRegions`, schema v2) via [RelayPool.fromManifest], keeping
/// `signed_config` the single source of truth for which regions exist.
/// Credential pairing composes the pool with `security`'s
/// [TurnCredentialsIssuer]: [issueRelay] returns the selected region's
/// URIs together with a short-lived TURN username/credential as a ready
/// [IceServerEntry].
library;

import 'package:security/security.dart'
    show TurnCredentials, TurnCredentialsIssuer;
import 'package:signed_config/signed_config.dart'
    show EndpointManifest, IceServerEntry;

import 'circuit_breaker.dart';

/// A single TURN relay region.
class RelayRegion {
  /// Region identifier, matching the manifest `relayRegions` format
  /// (`^[a-z0-9-]{1,32}$`), e.g. `eu-central`.
  final String id;

  /// TURN URIs for this region (`turn:` / `turns:` — udp/tcp/tls variants
  /// are expressed via the standard `?transport=` query, RFC 7065). At
  /// least one is required; STUN URIs are rejected because a relay pool
  /// hands out *relay* servers that always need credentials.
  final List<Uri> uris;

  /// Optional static preference used only to break exact score ties
  /// (higher wins). Defaults to 0; it never overrides measured health.
  final int priority;

  static final _idPattern = RegExp(r'^[a-z0-9-]{1,32}$');
  static const _allowedSchemes = {'turn', 'turns'};

  RelayRegion({required this.id, required List<Uri> uris, this.priority = 0})
    : uris = List.unmodifiable(uris) {
    if (!_idPattern.hasMatch(id)) {
      throw FormatException(
        'Relay region id must match ^[a-z0-9-]{1,32}\$, got: "$id"',
      );
    }
    if (uris.isEmpty) {
      throw FormatException('Relay region "$id" requires at least one URI.');
    }
    for (final uri in uris) {
      if (!_allowedSchemes.contains(uri.scheme)) {
        throw FormatException(
          'Relay region URIs must use turn/turns, got: $uri',
        );
      }
    }
  }

  @override
  String toString() => 'RelayRegion($id, uris: $uris, priority: $priority)';
}

/// Focused per-region health model.
///
/// Modeled on `ChannelHealth` (EWMA availability + EWMA RTT with the same
/// starting priors and score shape) but without the per-channel
/// `reliabilityPrior`/`bandwidth` axes, which have no meaning for a TURN
/// region. `ChannelHealth` itself is intentionally left untouched.
class RegionHealth {
  /// EWMA of recent probe/call success (1.0 = all succeeding).
  double availability;

  /// EWMA-smoothed round-trip time in milliseconds. Starts pessimistic
  /// (like `ChannelHealth`) so an unmeasured region never outranks a
  /// region with proven low RTT.
  int rttMs;

  RegionHealth({this.availability = 1.0, this.rttMs = 9999});

  /// Composite score in [0, 1]: `availability × rttFactor`, mirroring the
  /// `ChannelHealth.score()` RTT shaping.
  double score() {
    if (availability <= 0) return 0.0;
    final rttFactor = 1.0 / (1.0 + rttMs / 1000.0);
    return availability * rttFactor;
  }

  /// Records a successful observation with an optional RTT sample.
  void observeSuccess({int? rttSampleMs, double alpha = 0.3}) {
    _checkAlpha(alpha);
    availability = (1 - alpha) * availability + alpha;
    if (rttSampleMs != null) {
      rttMs = ((1 - alpha) * rttMs + alpha * rttSampleMs).round();
    }
  }

  /// Records a failed observation (no RTT: a failure teaches nothing
  /// useful about latency).
  void observeFailure({double alpha = 0.3}) {
    _checkAlpha(alpha);
    availability = (1 - alpha) * availability;
  }

  static void _checkAlpha(double alpha) {
    if (alpha <= 0.0 || alpha > 1.0) {
      throw RangeError.range(alpha, 0, 1, 'alpha');
    }
  }

  @override
  String toString() =>
      'RegionHealth(availability: ${availability.toStringAsFixed(3)}, '
      'rtt: ${rttMs}ms)';
}

/// Tuning knobs for [RelayPool].
class RelayPoolConfig {
  /// EWMA smoothing factor for [RegionHealth] updates, in (0, 1].
  final double ewmaAlpha;

  /// Relative hysteresis margin: a challenger replaces the current region
  /// only when `challengerScore > currentScore * (1 + hysteresisMargin)`.
  /// 0 disables hysteresis (pure best-score selection).
  final double hysteresisMargin;

  /// How stale a region's last observation may get before
  /// [RelayPool.regionsDueForProbe] lists it again. The pool does not
  /// schedule probes itself (no timers in pure-Dart scope); the owner
  /// polls this and feeds results back via report methods.
  final Duration probeInterval;

  /// Per-region circuit breaker settings ([CircuitBreakerConfig
  /// .failureThreshold] consecutive failures open the region's circuit).
  final CircuitBreakerConfig breaker;

  const RelayPoolConfig({
    this.ewmaAlpha = 0.3,
    this.hysteresisMargin = 0.15,
    this.probeInterval = const Duration(seconds: 30),
    this.breaker = const CircuitBreakerConfig(),
  });

  void _validate() {
    if (ewmaAlpha <= 0.0 || ewmaAlpha > 1.0) {
      throw RangeError.range(ewmaAlpha, 0, 1, 'ewmaAlpha');
    }
    if (hysteresisMargin < 0.0) {
      throw RangeError.range(hysteresisMargin, 0, null, 'hysteresisMargin');
    }
    if (probeInterval <= Duration.zero) {
      throw ArgumentError.value(probeInterval, 'probeInterval');
    }
  }
}

/// Thrown by [RelayPool.selectRegion] when no region is currently usable
/// (every circuit is open and/or every score is 0). Explicit by design:
/// silently returning a dead region would hide a total relay outage from
/// the call setup path.
class NoHealthyRelayException implements Exception {
  final String reason;
  NoHealthyRelayException(this.reason);

  @override
  String toString() => 'NoHealthyRelayException: $reason';
}

/// A selected relay region paired with freshly minted short-lived TURN
/// credentials, ready to drop into WebRTC configuration.
class RelayGrant {
  final RelayRegion region;

  /// The raw short-lived credentials (carries [TurnCredentials.expiresAt]
  /// and the region URIs as strings).
  final TurnCredentials credentials;

  /// `RTCIceServer`-shaped entry: region URIs + username/credential.
  final IceServerEntry iceServer;

  RelayGrant({
    required this.region,
    required this.credentials,
    required this.iceServer,
  });
}

/// Multi-region TURN relay selector with health scoring, hysteresis, and
/// circuit-breaker failover.
class RelayPool {
  final RelayPoolConfig config;
  final Clock _clock;
  final List<RelayRegion> _regions;
  final Map<String, RegionHealth> _health = {};
  final Map<String, CircuitBreaker> _breakers = {};
  final Map<String, DateTime> _lastObservedAt = {};

  String? _currentId;

  /// Builds a pool over [regions].
  ///
  /// Throws [ArgumentError] when [regions] is empty (an empty pool can
  /// never satisfy a selection, so it fails at construction rather than
  /// at first call setup) and on duplicate region ids.
  RelayPool({
    required List<RelayRegion> regions,
    this.config = const RelayPoolConfig(),
    Clock? clock,
  }) : _clock = clock ?? DateTime.now,
       _regions = List.unmodifiable(regions) {
    config._validate();
    if (_regions.isEmpty) {
      throw ArgumentError.value(regions, 'regions', 'must not be empty');
    }
    for (final region in _regions) {
      if (_health.containsKey(region.id)) {
        throw ArgumentError.value(
          regions,
          'regions',
          'duplicate region id: ${region.id}',
        );
      }
      _health[region.id] = RegionHealth();
      _breakers[region.id] = CircuitBreaker(
        config: config.breaker,
        clock: _clock,
      );
    }
  }

  /// Builds a pool from a verified [EndpointManifest]: one region per
  /// `relayRegions` entry, with URIs produced by [regionUriBuilder] (the
  /// manifest carries region *ids*; the URI layout per region is a
  /// deployment concern the caller injects).
  ///
  /// Throws [ArgumentError] when the manifest advertises no relay regions
  /// (same empty-pool contract as the default constructor).
  factory RelayPool.fromManifest(
    EndpointManifest manifest, {
    required List<Uri> Function(String regionId) regionUriBuilder,
    RelayPoolConfig config = const RelayPoolConfig(),
    Clock? clock,
    int Function(String regionId)? priorityOf,
  }) {
    if (manifest.relayRegions.isEmpty) {
      throw ArgumentError.value(
        manifest,
        'manifest',
        'manifest advertises no relayRegions; cannot build a relay pool',
      );
    }
    return RelayPool(
      regions: [
        for (final id in manifest.relayRegions)
          RelayRegion(
            id: id,
            uris: regionUriBuilder(id),
            priority: priorityOf?.call(id) ?? 0,
          ),
      ],
      config: config,
      clock: clock,
    );
  }

  /// All regions in declaration order (unmodifiable).
  List<RelayRegion> get regions => _regions;

  /// Id of the currently selected region, if a selection has been made.
  String? get currentRegionId => _currentId;

  /// Live health view for [regionId] (throws [ArgumentError] on unknown).
  RegionHealth healthOf(String regionId) =>
      _health[regionId] ?? (throw ArgumentError.value(regionId, 'regionId'));

  /// Circuit state view for [regionId] (never mutates the breaker).
  CircuitState breakerStateOf(String regionId) =>
      (_breakers[regionId] ?? (throw ArgumentError.value(regionId, 'regionId')))
          .state;

  /// Selects the best usable region.
  ///
  /// A region is a candidate when its circuit is not open (closed or
  /// half-open — a half-open region is allowed to *compete*, but after the
  /// failures that tripped it, its EWMA score is low, so it only wins once
  /// sustained successes have both closed the breaker and rebuilt its
  /// score past the hysteresis margin) and its score is > 0.
  ///
  /// Hysteresis: once a region is selected it stays selected until a
  /// challenger beats it by [RelayPoolConfig.hysteresisMargin]
  /// (relative), or until it stops being a candidate — mirroring the
  /// anti-flapping stance of the media adaptation layer.
  ///
  /// Throws [NoHealthyRelayException] when no candidate exists.
  RelayRegion selectRegion() {
    RelayRegion? best;
    var bestScore = -1.0;
    for (final region in _regions) {
      if (_breakers[region.id]!.state == CircuitState.open) continue;
      final score = _health[region.id]!.score();
      if (score <= 0) continue;
      if (score > bestScore ||
          (score == bestScore &&
              best != null &&
              region.priority > best.priority)) {
        best = region;
        bestScore = score;
      }
    }
    if (best == null) {
      throw NoHealthyRelayException(
        'all ${_regions.length} relay regions are unusable '
        '(circuit open or zero health score)',
      );
    }

    final currentId = _currentId;
    if (currentId != null && currentId != best.id) {
      final currentUsable =
          _breakers[currentId]!.state != CircuitState.open &&
          _health[currentId]!.score() > 0;
      if (currentUsable) {
        final currentScore = _health[currentId]!.score();
        if (bestScore <= currentScore * (1 + config.hysteresisMargin)) {
          // Challenger does not clear the hysteresis bar: keep current.
          return _regions.firstWhere((r) => r.id == currentId);
        }
      }
    }
    _currentId = best.id;
    return best;
  }

  /// Records a successful probe/call observation for [regionId], feeding
  /// both the EWMA health and the circuit breaker.
  void reportSuccess(String regionId, {Duration? rtt}) {
    healthOf(
      regionId,
    ).observeSuccess(rttSampleMs: rtt?.inMilliseconds, alpha: config.ewmaAlpha);
    _breakers[regionId]!.recordSuccess();
    _lastObservedAt[regionId] = _clock();
  }

  /// Records a failed probe/call observation for [regionId]. Enough
  /// consecutive failures open the region's circuit, after which
  /// [selectRegion] moves new calls to another region until the breaker's
  /// cool-down and half-open successes let this one earn its way back.
  void reportFailure(String regionId) {
    healthOf(regionId).observeFailure(alpha: config.ewmaAlpha);
    _breakers[regionId]!.recordFailure();
    _lastObservedAt[regionId] = _clock();
  }

  /// Regions whose last observation is older than
  /// [RelayPoolConfig.probeInterval] (or that were never observed) AND
  /// whose breaker currently admits a request. NOTE: for half-open
  /// regions this consumes one of the breaker's limited probe slots, so
  /// every listed region must actually be probed and the outcome reported
  /// back via [reportSuccess]/[reportFailure].
  List<RelayRegion> regionsDueForProbe() {
    final now = _clock();
    final due = <RelayRegion>[];
    for (final region in _regions) {
      final last = _lastObservedAt[region.id];
      final stale =
          last == null || now.difference(last) >= config.probeInterval;
      if (stale && _breakers[region.id]!.allowsRequest()) {
        due.add(region);
      }
    }
    return due;
  }

  /// Selects a region (honoring hysteresis/failover) — or uses [region]
  /// when given — and pairs it with short-lived TURN credentials from
  /// [issuer], returning a ready-to-use [IceServerEntry] plus the raw
  /// credentials (which carry the expiry). No new crypto: this is pure
  /// composition of the manifest-driven region list and the coturn
  /// `use-auth-secret` issuer.
  RelayGrant issueRelay({
    required TurnCredentialsIssuer issuer,
    required String userId,
    RelayRegion? region,
  }) {
    final selected = region ?? selectRegion();
    final uriStrings = [for (final u in selected.uris) u.toString()];
    final credentials = issuer.issue(userId, uris: uriStrings);
    return RelayGrant(
      region: selected,
      credentials: credentials,
      iceServer: IceServerEntry(
        urls: selected.uris,
        username: credentials.username,
        credential: credentials.credential,
      ),
    );
  }
}
