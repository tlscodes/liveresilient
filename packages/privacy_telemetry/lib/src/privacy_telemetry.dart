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
}

/// Histogram metrics with fixed, privacy-reviewed bucket boundaries.
enum TelemetryMetric { callSetupTimeMs, callDurationSeconds, reconnectTimeMs }

const Map<TelemetryMetric, List<int>> _bucketBoundaries = {
  TelemetryMetric.callSetupTimeMs: [500, 1000, 2000, 5000, 10000, 30000],
  TelemetryMetric.callDurationSeconds: [10, 60, 300, 900, 3600],
  TelemetryMetric.reconnectTimeMs: [1000, 3000, 10000, 30000, 60000],
};

/// Immutable aggregate snapshot handed to the exporter.
class TelemetrySnapshot {
  /// Schema version of this snapshot format.
  final int schemaVersion;

  /// App version string (coarse, e.g. '2.1.0') — the only metadata allowed.
  final String appVersion;

  /// Event name -> occurrence count in the window.
  final Map<String, int> counters;

  /// Metric name -> bucket-upper-bound -> count. The special key 'inf'
  /// holds the overflow bucket.
  final Map<String, Map<String, int>> histograms;

  TelemetrySnapshot({
    this.schemaVersion = 1,
    required this.appVersion,
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
    'counters': counters,
    'histograms': histograms,
  };

  bool get isEmpty => counters.isEmpty && histograms.isEmpty;
}

class PrivacyTelemetry {
  final TelemetryConsent _consent;
  final TelemetryExporter _exporter;
  final String appVersion;

  /// Export cadence; long enough that batches never reveal individual
  /// action timing.
  final Duration exportInterval;

  final Map<TelemetryEvent, int> _counters = {};
  final Map<TelemetryMetric, Map<String, int>> _histograms = {};

  Timer? _exportTimer;
  bool _disposed = false;

  PrivacyTelemetry({
    required TelemetryConsent consent,
    required TelemetryExporter exporter,
    required this.appVersion,
    this.exportInterval = const Duration(hours: 6),
  }) : _consent = consent,
       _exporter = exporter {
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

  /// Builds a snapshot of current aggregates without clearing them.
  TelemetrySnapshot snapshot() {
    return TelemetrySnapshot(
      appVersion: appVersion,
      counters: {
        for (final entry in _counters.entries) entry.key.name: entry.value,
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
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _exportTimer?.cancel();
  }
}
