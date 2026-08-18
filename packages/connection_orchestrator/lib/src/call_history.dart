/// Personal call history: one compact record per finished call, feeding
/// the budget calibrator and the narration layer with what this device
/// has actually lived through. Bounded, persistable, corrupt-safe. No
/// wall-clock reads: all timestamps are supplied by the caller.
library;

/// One point on a call's quality timeline.
class QualitySample {
  const QualitySample({required this.tMs, required this.score});

  /// Milliseconds since the call started.
  final int tMs;

  /// Quality score at that moment (0..1, as produced by the quality gate).
  final double score;

  Map<String, Object?> toJson() => {'tMs': tMs, 'score': score};
}

/// The durable summary of one finished call.
class CallHistoryRecord {
  const CallHistoryRecord({
    required this.startedUtcMs,
    required this.connectMs,
    required this.recoveries,
    required this.dropsToFloor,
    required this.networkIdentityHash,
    required this.endReason,
    this.qualityTimeline = const [],
  });

  /// Call start, UTC wall-clock ms as supplied by the caller.
  final int startedUtcMs;

  /// How long the connect phase took, ms.
  final int connectMs;

  /// How many mid-call recoveries were performed.
  final int recoveries;

  /// How many times quality dropped to the floor tier.
  final int dropsToFloor;

  /// Hashed network identity (never the raw label — the NetworkAtlas
  /// hash-only persistence rule applies here too).
  final String networkIdentityHash;

  /// Why the call ended (e.g. 'hangup', 'network-lost').
  final String endReason;

  final List<QualitySample> qualityTimeline;

  Map<String, Object?> toJson() => {
    'startedUtcMs': startedUtcMs,
    'connectMs': connectMs,
    'recoveries': recoveries,
    'dropsToFloor': dropsToFloor,
    'networkIdentityHash': networkIdentityHash,
    'endReason': endReason,
    'qualityTimeline': [for (final s in qualityTimeline) s.toJson()],
  };

  /// Parses one serialized record; returns null when the shape is corrupt
  /// (the store then skips it). Corrupt timeline samples are dropped
  /// individually — a damaged sample never sinks the whole record.
  static CallHistoryRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final startedUtcMs = raw['startedUtcMs'];
    final connectMs = raw['connectMs'];
    final recoveries = raw['recoveries'];
    final dropsToFloor = raw['dropsToFloor'];
    final networkIdentityHash = raw['networkIdentityHash'];
    final endReason = raw['endReason'];
    if (startedUtcMs is! int ||
        connectMs is! int ||
        recoveries is! int ||
        dropsToFloor is! int ||
        networkIdentityHash is! String ||
        endReason is! String) {
      return null;
    }
    final timeline = <QualitySample>[];
    final rawTimeline = raw['qualityTimeline'];
    if (rawTimeline is List) {
      for (final s in rawTimeline) {
        if (s is! Map) continue;
        final tMs = s['tMs'];
        final score = s['score'];
        if (tMs is! int || score is! num || !score.toDouble().isFinite) {
          continue;
        }
        timeline.add(QualitySample(tMs: tMs, score: score.toDouble()));
      }
    }
    return CallHistoryRecord(
      startedUtcMs: startedUtcMs,
      connectMs: connectMs,
      recoveries: recoveries,
      dropsToFloor: dropsToFloor,
      networkIdentityHash: networkIdentityHash,
      endReason: endReason,
      qualityTimeline: timeline,
    );
  }
}

/// Bounded FIFO store of finished-call records.
class CallHistoryStore {
  CallHistoryStore({
    // 200: DeliveryLedger's 5000-cap precedent scaled to record size —
    // 200 calls x a small record ≈ tens of KB on disk.
    this.capacity = 200,
  });

  /// Oldest calls are evicted beyond this bound.
  final int capacity;

  final List<CallHistoryRecord> _records = [];

  /// Appends one finished call, evicting the oldest beyond [capacity].
  void add(CallHistoryRecord record) {
    _records.add(record);
    if (_records.length > capacity) {
      _records.removeAt(0);
    }
  }

  /// Oldest-first, read-only view.
  List<CallHistoryRecord> get records => List.unmodifiable(_records);

  List<Object?> toJson() => [for (final r in _records) r.toJson()];

  /// Restores a serialized store. Corrupt entries are skipped: a damaged
  /// history file degrades to fewer remembered calls, never a crash.
  factory CallHistoryStore.fromJson(Object? json, {int capacity = 200}) {
    final store = CallHistoryStore(capacity: capacity);
    if (json is List) {
      for (final raw in json) {
        final record = CallHistoryRecord.fromJson(raw);
        if (record != null) store.add(record);
      }
    }
    return store;
  }
}
