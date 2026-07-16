/// Privacy-preserving telemetry.
///
/// Design constraints (enforced at runtime, see `docs/PRIVACY.md`):
/// - **opt-in only**: nothing is recorded, aggregated, or exported unless
///   the user's explicit telemetry consent is currently granted;
/// - **allowlisted events**: only pre-declared event names with numeric
///   values are accepted; arbitrary keys/strings are rejected so PII cannot
///   leak through this API even by accident;
/// - **aggregates only**: the exporter receives counters and histogram
///   buckets, never raw events, timestamps of individual actions, or
///   identifiers;
/// - **local-first**: aggregation happens on-device; export is batched and
///   any failure simply retains local aggregates.
///
/// Designed from the v2 blueprint role (no v1 equivalent).
library;

import 'dart:async';

/// Live user consent for telemetry, owned by the settings layer.
abstract interface class TelemetryConsent {
  bool get granted;
}

/// Receives aggregate snapshots (e.g. an HTTPS POST to the operator's
/// endpoint). Implementations must not attach user identifiers.
abstract interface class TelemetryExporter {
  Future<void> exportAggregates(TelemetrySnapshot snapshot);
}

/// The full set of events this app may ever record. Adding an event is a
/// code change, reviewed like one — there is no dynamic event creation.
enum TelemetryEvent {
  callAttempted,
  callConnected,
  callFailed,
  callReconnected,
  reconnectExhausted,
  transportFailover,
  manifestRefreshFailed,
  localPeerActivated,

  // Blueprint phase 10, "ICE candidate type": the selected candidate pair's
  // local candidate type. Modeled as three distinct counter events (not a
  // histogram) because the domain is categorical with exactly three fixed
  // values — counters are the honest aggregate; a histogram would impose a
  // numeric ordering that does not exist.
  iceSelectedHost,
  iceSelectedSrflx,
  iceSelectedRelay,

  // Blueprint phase 10, "failure category": closed enum values only. A
  // free-form reason string is deliberately impossible through this API.
  failureSignaling,
  failureIce,
  failureMedia,
  failureAuth,
}

/// Histogram metrics with fixed, privacy-reviewed bucket boundaries.
enum TelemetryMetric {
  callSetupTimeMs,
  callDurationSeconds,
  reconnectTimeMs,

  // Blueprint phase 10: RTT / jitter / packet loss / bitrate, bucketed.
  rttMsBucket,
  jitterMsBucket,
  packetLossPctBucket,
  bitrateKbpsBucket,
}

/// The closed set of codec identifiers this app may ever report
/// (blueprint phase 10, "codec"). A codec outside this list is a code
/// change, reviewed like one — never a free-form string.
enum TelemetryCodec { opus, pcmu, pcma, g722, vp8, vp9, h264, av1 }

const Map<TelemetryMetric, List<int>> _bucketBoundaries = {
  TelemetryMetric.callSetupTimeMs: [500, 1000, 2000, 5000, 10000, 30000],
  TelemetryMetric.callDurationSeconds: [10, 60, 300, 900, 3600],
  TelemetryMetric.reconnectTimeMs: [1000, 3000, 10000, 30000, 60000],
  TelemetryMetric.rttMsBucket: [50, 100, 200, 400, 800, 1600],
  TelemetryMetric.jitterMsBucket: [10, 20, 50, 100, 250],
  TelemetryMetric.packetLossPctBucket: [1, 2, 5, 10, 25],
  TelemetryMetric.bitrateKbpsBucket: [16, 32, 64, 128, 256, 512],
};

/// Coarse version strings (app/OS) must stay shaped like versions: short,
/// no `@`, no `:`; long enough for '2.1.0' or 'ios-17.4' but structurally
/// unable to carry a token, an SDP line, or an email address.
final RegExp _coarseVersionFormat = RegExp(
  r'^[A-Za-z0-9][A-Za-z0-9. _+-]{0,31}$',
);

/// Region-bucket id format, identical to the manifest `relayRegions`
/// format (e.g. 'eu-central'). Format alone is NOT sufficient — recorded
/// regions must also be members of the reviewed [PrivacyTelemetry.new]
/// `allowedRegions` closed set, so an arbitrary digit string that happens
/// to match the pattern still cannot enter the aggregates.
final RegExp _regionIdFormat = RegExp(r'^[a-z0-9-]{1,32}$');

/// Immutable aggregate snapshot handed to the exporter.
class TelemetrySnapshot {
  /// Schema version of this snapshot format.
  final int schemaVersion;

  /// App version string (coarse, e.g. '2.1.0').
  final String appVersion;

  /// OS version string (coarse, e.g. 'ios-17.4'), or '' when not reported.
  /// Together with [appVersion] this is the only metadata allowed
  /// (blueprint phase 10, "app/OS version").
  final String osVersion;

  /// Event name -> occurrence count in the window.
  final Map<String, int> counters;

  /// Metric name -> bucket-upper-bound -> count. The special key 'inf'
  /// holds the overflow bucket.
  final Map<String, Map<String, int>> histograms;

  TelemetrySnapshot({
    this.schemaVersion = 1,
    required this.appVersion,
    this.osVersion = '',
    required Map<String, int> counters,
    required Map<String, Map<String, int>> histograms,
  }) : counters = Map.unmodifiable(counters),
       histograms = Map.unmodifiable({
         for (final entry in histograms.entries)
           entry.key: Map<String, int>.unmodifiable(entry.value),
       });

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'appVersion': appVersion,
    'osVersion': osVersion,
    'counters': counters,
    'histograms': histograms,
  };

  bool get isEmpty => counters.isEmpty && histograms.isEmpty;
}

class PrivacyTelemetry {
  final TelemetryConsent _consent;
  final TelemetryExporter _exporter;
  final String appVersion;

  /// Coarse OS version (e.g. 'ios-17.4'); '' means "not reported".
  final String osVersion;

  /// Closed set of region-bucket ids this install may ever report,
  /// wired from the reviewed endpoint-manifest `relayRegions` list.
  /// Empty (the default) means region reporting is off entirely.
  final Set<String> _allowedRegions;

  /// Export cadence; long enough that batches never reveal individual
  /// action timing.
  final Duration exportInterval;

  final Map<TelemetryEvent, int> _counters = {};
  final Map<TelemetryMetric, Map<String, int>> _histograms = {};
  final Map<TelemetryCodec, int> _codecCounters = {};
  final Map<String, int> _regionCounters = {};

  Timer? _exportTimer;
  bool _disposed = false;

  PrivacyTelemetry({
    required TelemetryConsent consent,
    required TelemetryExporter exporter,
    required this.appVersion,
    this.osVersion = '',
    Set<String> allowedRegions = const {},
    this.exportInterval = const Duration(hours: 6),
  }) : _consent = consent,
       _exporter = exporter,
       _allowedRegions = Set.unmodifiable(allowedRegions) {
    if (!_coarseVersionFormat.hasMatch(appVersion)) {
      throw ArgumentError.value(
        appVersion,
        'appVersion',
        'must be a coarse version string',
      );
    }
    if (osVersion.isNotEmpty && !_coarseVersionFormat.hasMatch(osVersion)) {
      throw ArgumentError.value(
        osVersion,
        'osVersion',
        'must be a coarse version string',
      );
    }
    for (final region in allowedRegions) {
      if (!_regionIdFormat.hasMatch(region)) {
        throw ArgumentError.value(
          region,
          'allowedRegions',
          r'must match ^[a-z0-9-]{1,32}$',
        );
      }
    }
    _exportTimer = Timer.periodic(exportInterval, (_) => exportNow());
  }

  /// Records one occurrence of an allowlisted event. Silently a no-op
  /// without consent — callers never need to branch on consent themselves.
  void recordEvent(TelemetryEvent event) {
    if (_disposed || !_consent.granted) return;
    _counters[event] = (_counters[event] ?? 0) + 1;
  }

  /// Records a numeric observation into fixed histogram buckets.
  void recordMetric(TelemetryMetric metric, num value) {
    if (_disposed || !_consent.granted) return;
    if (value.isNaN || value.isInfinite || value < 0) return;

    final boundaries = _bucketBoundaries[metric]!;
    String bucketKey = 'inf';
    for (final boundary in boundaries) {
      if (value <= boundary) {
        bucketKey = boundary.toString();
        break;
      }
    }
    final buckets = _histograms.putIfAbsent(metric, () => {});
    buckets[bucketKey] = (buckets[bucketKey] ?? 0) + 1;
  }

  /// Records the codec selected for a call, from the closed
  /// [TelemetryCodec] set. Aggregated as a counter per codec id.
  void recordCodec(TelemetryCodec codec) {
    if (_disposed || !_consent.granted) return;
    _codecCounters[codec] = (_codecCounters[codec] ?? 0) + 1;
  }

  /// Records one occurrence of an anonymized region bucket.
  ///
  /// [regionId] must match the manifest `relayRegions` id format AND be a
  /// member of the closed `allowedRegions` set given at construction —
  /// anything else is silently dropped. Never pass IP-derived values,
  /// coordinates, or city names; the closed set is the privacy guarantee.
  void recordRegion(String regionId) {
    if (_disposed || !_consent.granted) return;
    if (!_regionIdFormat.hasMatch(regionId)) return;
    if (!_allowedRegions.contains(regionId)) return;
    _regionCounters[regionId] = (_regionCounters[regionId] ?? 0) + 1;
  }

  /// Builds a snapshot of current aggregates without clearing them.
  TelemetrySnapshot snapshot() {
    return TelemetrySnapshot(
      appVersion: appVersion,
      osVersion: osVersion,
      counters: {
        for (final entry in _counters.entries) entry.key.name: entry.value,
        for (final entry in _codecCounters.entries)
          'codec.${entry.key.name}': entry.value,
        for (final entry in _regionCounters.entries)
          'region.${entry.key}': entry.value,
      },
      histograms: {
        for (final entry in _histograms.entries)
          entry.key.name: Map<String, int>.from(entry.value),
      },
    );
  }

  /// Exports current aggregates and clears them on success. Without
  /// consent this clears nothing and sends nothing.
  Future<void> exportNow() async {
    if (_disposed || !_consent.granted) return;
    final current = snapshot();
    if (current.isEmpty) return;
    try {
      await _exporter.exportAggregates(current);
      _counters.clear();
      _histograms.clear();
      _codecCounters.clear();
      _regionCounters.clear();
    } catch (_) {
      // Keep aggregates; the next interval retries. Telemetry must never
      // affect app behavior.
    }
  }

  /// Immediately discards all locally held aggregates. Call when the user
  /// revokes consent.
  void purgeLocalData() {
    _counters.clear();
    _histograms.clear();
    _codecCounters.clear();
    _regionCounters.clear();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _exportTimer?.cancel();
  }
}
