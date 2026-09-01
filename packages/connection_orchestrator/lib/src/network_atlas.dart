/// On-device memory of each network's measured physics — predictive
/// («هوشمندی v4» pillar 4: hour-of-week refinement + network-transition
/// model on top of the v3 hour-of-day atlas).
///
/// Where [MicroLearner] keeps a single exponentially-weighted quality
/// score per (place, network) pair, the atlas keeps the raw physics —
/// loss fraction, round-trip time, delivery rate — as running
/// mean/variance cells, so the planner can ask "what does this network
/// usually do at 9pm?" before sending a byte. v4 adds two predictive
/// layers, both optional and both backward-compatible:
///
/// - Hour-of-week cells (0..167): "Sunday 9pm" can differ from "Monday
///   9pm". A week cell speaks only once it has 3 samples; below that the
///   forecast falls back to exactly the v3 chain (exact hour-of-day cell
///   with 3+ samples, else the identity's all-hours aggregate), so a
///   caller that never supplies hourOfWeek gets bit-identical v3
///   behavior — verified against the replay benchmark.
/// - Network-transition counts: "after this Wi-Fi, which network usually
///   comes next?" ([recordTransition] / [likelyNextNetwork]) so a lane
///   can be pre-warmed BEFORE the current network is gone.
///
/// Privacy contract (test-pinned): the raw network label is NEVER stored
/// or serialized. Every label is reduced to [NetworkAtlas.identityHash]
/// at the record boundary and only the hash appears in memory and in
/// JSON — for physics cells AND for transitions.
library;

import 'dart:convert' show utf8;
import 'dart:math' show sqrt;

/// What the atlas predicts for one network at one hour.
///
/// A metric is present (non-null, with its stddev) only when at least
/// one sample of that metric was recorded for the chosen cell.
class NetworkPhysicsForecast {
  const NetworkPhysicsForecast({
    this.expectedLossFraction,
    this.lossFractionStddev,
    this.expectedRttMs,
    this.rttMsStddev,
    this.expectedDeliveryRate,
    this.deliveryRateStddev,
    required this.sampleCount,
  });

  /// Mean observed loss fraction (0..1), null if never measured.
  final double? expectedLossFraction;

  /// Population standard deviation of the loss-fraction samples.
  final double? lossFractionStddev;

  /// Mean observed round-trip time in milliseconds, null if never measured.
  final double? expectedRttMs;

  /// Population standard deviation of the round-trip samples.
  final double? rttMsStddev;

  /// Mean observed delivery rate (0..1), null if never measured.
  final double? expectedDeliveryRate;

  /// Population standard deviation of the delivery-rate samples.
  final double? deliveryRateStddev;

  /// Number of [NetworkAtlas.record] calls behind this forecast (from
  /// the chosen cell: week cell, hour cell, or all-hours aggregate).
  final int sampleCount;
}

/// Where the network usually goes next, by measured transition counts.
class NetworkTransitionForecast {
  const NetworkTransitionForecast({
    required this.toIdentityHash,
    required this.probability,
    required this.transitionCount,
    required this.totalTransitions,
  });

  /// Identity hash of the most likely next network (never a raw label).
  final String toIdentityHash;

  /// transitionCount / totalTransitions for the from-network.
  final double probability;

  /// How many times this exact from->to hop was recorded.
  final int transitionCount;

  /// All recorded hops leaving the from-network.
  final int totalTransitions;
}

/// Welford running mean/variance for one metric.
///
/// Numerically stable online update; population variance (divide by
/// count), so a single sample has variance 0, never NaN.
class _RunningStat {
  int count = 0;
  double mean = 0;

  /// Sum of squared deviations from the running mean (Welford's M2).
  double m2 = 0;

  void add(double value) {
    count += 1;
    final delta = value - mean;
    mean += delta / count;
    m2 += delta * (value - mean);
  }

  double get stddev {
    if (count == 0) return 0;
    final variance = m2 / count;
    // Guard tiny negative values from floating-point cancellation.
    return variance <= 0 ? 0 : sqrt(variance);
  }

  /// Chan's parallel merge: combines another accumulator into this one
  /// with the exact pooled mean and M2.
  void merge(_RunningStat other) {
    if (other.count == 0) return;
    if (count == 0) {
      count = other.count;
      mean = other.mean;
      m2 = other.m2;
      return;
    }
    final total = count + other.count;
    final delta = other.mean - mean;
    final pooledM2 =
        m2 + other.m2 + delta * delta * count * other.count / total;
    mean = mean + delta * other.count / total;
    m2 = pooledM2;
    count = total;
  }

  Map<String, Object?> toJson() => {'n': count, 'mean': mean, 'm2': m2};

  /// Null on any malformed field: wrong type, NaN/infinite, negative
  /// count, negative m2.
  static _RunningStat? fromJson(Object? json) {
    if (json is! Map) return null;
    final n = json['n'];
    final mean = json['mean'];
    final m2 = json['m2'];
    if (n is! int || n < 0) return null;
    if (mean is! num || m2 is! num) return null;
    // Doubles in JSON may arrive as int, hence num + toDouble.
    final meanD = mean.toDouble();
    final m2D = m2.toDouble();
    if (!meanD.isFinite || !m2D.isFinite || m2D < 0) return null;
    return _RunningStat()
      ..count = n
      ..mean = meanD
      ..m2 = m2D;
  }
}

/// One accumulation cell: three metric accumulators plus how many record
/// calls landed here and when the newest one happened. Used for both
/// hour-of-day and hour-of-week buckets.
class _HourCell {
  int recordCount = 0;
  int lastRecordMs = 0;
  final _RunningStat loss = _RunningStat();
  final _RunningStat rtt = _RunningStat();
  final _RunningStat rate = _RunningStat();

  Map<String, Object?> toJson() => {
    'n': recordCount,
    'last': lastRecordMs,
    'loss': loss.toJson(),
    'rtt': rtt.toJson(),
    'rate': rate.toJson(),
  };

  /// Null on any malformed field — the caller drops the cell silently
  /// so a corrupt file restores to a fresh atlas, never a crash.
  static _HourCell? fromJson(Object? json) {
    if (json is! Map) return null;
    final n = json['n'];
    final last = json['last'];
    if (n is! int || n < 0) return null;
    if (last is! int) return null;
    final loss = _RunningStat.fromJson(json['loss']);
    final rtt = _RunningStat.fromJson(json['rtt']);
    final rate = _RunningStat.fromJson(json['rate']);
    if (loss == null || rtt == null || rate == null) return null;
    final cell = _HourCell()
      ..recordCount = n
      ..lastRecordMs = last;
    cell.loss.merge(loss);
    cell.rtt.merge(rtt);
    cell.rate.merge(rate);
    return cell;
  }
}

/// On-device memory of each network's measured physics, bucketed by hour
/// of day (always) and hour of week (when supplied), keyed by
/// [identityHash] of the network label.
class NetworkAtlas {
  // 24 = hours per day; one bucket per hour is the finest granularity
  // the injected hourOfDay (0..23) supports.
  NetworkAtlas({this.hourBuckets = 24, this.maxIdentities = 64})
    : assert(hourBuckets > 0, 'hourBuckets must be positive'),
      assert(maxIdentities > 0, 'maxIdentities must be positive');

  /// Number of hour-of-day buckets per network identity.
  final int hourBuckets;

  /// Cap on distinct network identities kept (64: a device that has seen
  /// more than 64 networks is roaming past any personal pattern worth
  /// keeping; DeliveryLedger's bounded-collection precedent). When full,
  /// the identity with the oldest lastRecordMs is evicted. The same cap
  /// bounds the transition table's from-identities.
  final int maxIdentities;

  /// 168 = 7 * 24 hour-of-week buckets (0 = Monday 00, per
  /// DateTime.weekday's Monday=1 convention minus one, times 24).
  static const int weekBuckets = 168;

  /// 8: successors kept per from-identity in the transition table —
  /// a personal device hops between a handful of networks; beyond 8 the
  /// lowest-count successor is evicted.
  static const int maxSuccessors = 8;

  /// identityHash -> hourBucket -> cell. Raw labels never enter this map.
  /// Insertion-ordered; eviction scans lastRecordMs, not insertion order.
  final Map<String, Map<int, _HourCell>> _byIdentity = {};

  /// identityHash -> weekHourBucket (0..167) -> cell. Trained only when
  /// record() receives hourOfWeek; absent for v3 callers and v1 files.
  final Map<String, Map<int, _HourCell>> _weekByIdentity = {};

  /// fromIdentityHash -> toIdentityHash -> hop count.
  final Map<String, Map<String, int>> _transitions = {};

  /// FNV-1a 64-bit hash of the label, as 16 lowercase hex chars.
  ///
  /// Non-cryptographic, adequate because the value never leaves the
  /// device and only guards against casual disk inspection.
  static String identityHash(String networkLabel) {
    // FNV-1a 64-bit offset basis and prime, from the FNV reference
    // (Fowler/Noll/Vo): basis 0xcbf29ce484222325, prime 0x100000001b3.
    var hash = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    for (final byte in utf8.encode(networkLabel)) {
      hash ^= byte;
      // Native-VM Dart ints wrap at 64 bits, which is what FNV needs.
      // Under dart2js this multiply loses precision — acceptable here:
      // the package targets mobile-native builds and the hash is a
      // privacy shield, not a portable wire format.
      hash *= prime;
    }
    // 64 bits = 16 hex digits; >>> keeps the high half unsigned.
    final hi = (hash >>> 32).toRadixString(16).padLeft(8, '0');
    final lo = (hash & 0xffffffff).toRadixString(16).padLeft(8, '0');
    return '$hi$lo';
  }

  /// Records one observation of a network's physics.
  ///
  /// [hourOfDay] outside 0..hourBuckets-1 is clamped, never thrown on.
  /// [hourOfWeek] (0..167, Monday 00 = 0) additionally trains the week
  /// cell when supplied; null keeps exactly the v3 behavior. Non-finite
  /// metric values are ignored (that sample of that metric is dropped;
  /// the record call still counts). [nowMs] is injected by the caller —
  /// this library never reads a wall clock.
  void record({
    required String networkLabel,
    required int nowMs,
    required int hourOfDay,
    int? hourOfWeek,
    double? lossFraction,
    double? rttMs,
    double? deliveryRate,
  }) {
    final id = identityHash(networkLabel);
    if (!_byIdentity.containsKey(id) && _byIdentity.length >= maxIdentities) {
      _evictOldestIdentity();
    }
    final cell = _byIdentity
        .putIfAbsent(id, () => {})
        .putIfAbsent(_clampHour(hourOfDay), _HourCell.new);
    _feed(cell, nowMs, lossFraction, rttMs, deliveryRate);
    if (hourOfWeek != null) {
      final weekCell = _weekByIdentity
          .putIfAbsent(id, () => {})
          .putIfAbsent(_clampWeekHour(hourOfWeek), _HourCell.new);
      _feed(weekCell, nowMs, lossFraction, rttMs, deliveryRate);
    }
  }

  static void _feed(
    _HourCell cell,
    int nowMs,
    double? lossFraction,
    double? rttMs,
    double? deliveryRate,
  ) {
    cell.recordCount += 1;
    cell.lastRecordMs = nowMs;
    if (lossFraction != null && lossFraction.isFinite) {
      cell.loss.add(lossFraction);
    }
    if (rttMs != null && rttMs.isFinite) {
      cell.rtt.add(rttMs);
    }
    if (deliveryRate != null && deliveryRate.isFinite) {
      cell.rate.add(deliveryRate);
    }
  }

  /// Records one observed network hop (the device left [fromLabel] and
  /// landed on [toLabel]). Same-label hops are ignored. Only hashes are
  /// stored. The from-side is bounded by [maxIdentities]; successors per
  /// from-identity are bounded by [maxSuccessors] (lowest count evicted).
  void recordTransition({required String fromLabel, required String toLabel}) {
    if (fromLabel == toLabel) return;
    final from = identityHash(fromLabel);
    final to = identityHash(toLabel);
    if (!_transitions.containsKey(from) &&
        _transitions.length >= maxIdentities) {
      // Evict the from-identity with the fewest total hops: the least
      // established pattern makes room for the new one.
      String? weakest;
      var weakestTotal = 1 << 62;
      for (final e in _transitions.entries) {
        var total = 0;
        for (final c in e.value.values) {
          total += c;
        }
        if (total < weakestTotal) {
          weakestTotal = total;
          weakest = e.key;
        }
      }
      if (weakest != null) _transitions.remove(weakest);
    }
    final successors = _transitions.putIfAbsent(from, () => {});
    successors[to] = (successors[to] ?? 0) + 1;
    if (successors.length > maxSuccessors) {
      String? weakest;
      var weakestCount = 1 << 62;
      for (final e in successors.entries) {
        if (e.value < weakestCount) {
          weakestCount = e.value;
          weakest = e.key;
        }
      }
      if (weakest != null) successors.remove(weakest);
    }
  }

  /// The most likely next network after [networkLabel], or null when no
  /// hop away from it was ever recorded. Ties resolve to the
  /// lexicographically smallest hash, so the answer is a pure function
  /// of the counts (deterministic, like everything else here).
  NetworkTransitionForecast? likelyNextNetwork({required String networkLabel}) {
    final successors = _transitions[identityHash(networkLabel)];
    if (successors == null || successors.isEmpty) return null;
    var total = 0;
    for (final c in successors.values) {
      total += c;
    }
    final hashes = successors.keys.toList()..sort();
    String best = hashes.first;
    for (final h in hashes) {
      if (successors[h]! > successors[best]!) best = h;
    }
    return NetworkTransitionForecast(
      toIdentityHash: best,
      probability: successors[best]! / total,
      transitionCount: successors[best]!,
      totalTransitions: total,
    );
  }

  /// Drops the identity whose most recent record is oldest, so the map
  /// stays within [maxIdentities] without ever growing unbounded.
  void _evictOldestIdentity() {
    String? oldestId;
    var oldestMs = 1 << 62;
    for (final entry in _byIdentity.entries) {
      var newest = 0;
      for (final cell in entry.value.values) {
        if (cell.lastRecordMs > newest) newest = cell.lastRecordMs;
      }
      if (newest < oldestMs) {
        oldestMs = newest;
        oldestId = entry.key;
      }
    }
    if (oldestId != null) {
      _byIdentity.remove(oldestId);
      _weekByIdentity.remove(oldestId);
    }
  }

  /// Forecast for one network at one hour.
  ///
  /// Chain, most specific first — each link needs [_minCellSamples]:
  /// 1. The exact hour-of-week cell, when [hourOfWeek] is supplied and
  ///    that cell has been trained enough ("Sunday 9pm").
  /// 2. The exact hour-of-day cell (the v3 rule — "any day, 9pm").
  /// 3. The identity's all-hours aggregate (the v3 fallback).
  /// Returns null when the identity has never been seen. A caller that
  /// omits [hourOfWeek] gets bit-identical v3 behavior.
  NetworkPhysicsForecast? forecast({
    required String networkLabel,
    required int hourOfDay,
    int? hourOfWeek,
  }) {
    final id = identityHash(networkLabel);
    if (hourOfWeek != null) {
      final weekCell = _weekByIdentity[id]?[_clampWeekHour(hourOfWeek)];
      if (weekCell != null && weekCell.recordCount >= _minCellSamples) {
        return _forecastFromCell(weekCell);
      }
    }
    final hours = _byIdentity[id];
    if (hours == null || hours.isEmpty) return null;
    final exact = hours[_clampHour(hourOfDay)];
    if (exact != null && exact.recordCount >= _minCellSamples) {
      return _forecastFromCell(exact);
    }
    // Aggregate every hour cell of this identity into one pooled cell.
    final pooled = _HourCell();
    for (final cell in hours.values) {
      pooled.recordCount += cell.recordCount;
      pooled.loss.merge(cell.loss);
      pooled.rtt.merge(cell.rtt);
      pooled.rate.merge(cell.rate);
    }
    return _forecastFromCell(pooled);
  }

  // 3 = the minimum-sample precedent set by TrendMonitor.slopePerSec
  // (trend_monitor.dart: no slope before 3 samples).
  static const int _minCellSamples = 3;

  int _clampHour(int hourOfDay) => hourOfDay < 0
      ? 0
      : (hourOfDay >= hourBuckets ? hourBuckets - 1 : hourOfDay);

  static int _clampWeekHour(int hourOfWeek) => hourOfWeek < 0
      ? 0
      : (hourOfWeek >= weekBuckets ? weekBuckets - 1 : hourOfWeek);

  static NetworkPhysicsForecast _forecastFromCell(_HourCell cell) {
    return NetworkPhysicsForecast(
      expectedLossFraction: cell.loss.count > 0 ? cell.loss.mean : null,
      lossFractionStddev: cell.loss.count > 0 ? cell.loss.stddev : null,
      expectedRttMs: cell.rtt.count > 0 ? cell.rtt.mean : null,
      rttMsStddev: cell.rtt.count > 0 ? cell.rtt.stddev : null,
      expectedDeliveryRate: cell.rate.count > 0 ? cell.rate.mean : null,
      deliveryRateStddev: cell.rate.count > 0 ? cell.rate.stddev : null,
      sampleCount: cell.recordCount,
    );
  }

  static Map<String, Object?> _hoursToJson(Map<int, _HourCell> hours) => {
    // JSON object keys must be strings, hence the hour as text.
    for (final hour in hours.entries) '${hour.key}': hour.value.toJson(),
  };

  /// Serializes the whole atlas. Only identity hashes appear — never a
  /// raw network label. The 'week' and 'transitions' sections are v4
  /// additions; a v1 file simply lacks them.
  Map<String, Object?> toJson() => {
    'hourBuckets': hourBuckets,
    'identities': {
      for (final identity in _byIdentity.entries)
        identity.key: _hoursToJson(identity.value),
    },
    if (_weekByIdentity.isNotEmpty)
      'week': {
        for (final identity in _weekByIdentity.entries)
          identity.key: _hoursToJson(identity.value),
      },
    if (_transitions.isNotEmpty)
      'transitions': {
        for (final from in _transitions.entries)
          from.key: {for (final to in from.value.entries) to.key: to.value},
      },
  };

  /// Restores a persisted atlas; malformed cells are dropped silently so
  /// a corrupt file yields a fresh (never crashing) atlas. v1 files
  /// (no 'week'/'transitions') restore with those layers empty.
  static NetworkAtlas fromJson(Map<String, Object?> json) {
    final rawBuckets = json['hourBuckets'];
    final atlas = NetworkAtlas(
      // 24 = same hours-per-day default as the constructor.
      hourBuckets: rawBuckets is int && rawBuckets > 0 ? rawBuckets : 24,
    );
    final identities = json['identities'];
    if (identities is Map) {
      for (final identity in identities.entries) {
        final key = identity.key;
        final hours = identity.value;
        if (key is! String || hours is! Map) continue;
        // Restore honors the same cap as record(): an oversized or
        // tampered file cannot grow the map past maxIdentities.
        if (!atlas._byIdentity.containsKey(key) &&
            atlas._byIdentity.length >= atlas.maxIdentities) {
          atlas._evictOldestIdentity();
        }
        for (final hourEntry in hours.entries) {
          final hourKey = hourEntry.key;
          if (hourKey is! String) continue;
          final hour = int.tryParse(hourKey);
          if (hour == null || hour < 0 || hour >= atlas.hourBuckets) continue;
          final cell = _HourCell.fromJson(hourEntry.value);
          if (cell == null) continue;
          atlas._byIdentity.putIfAbsent(key, () => {})[hour] = cell;
        }
      }
    }
    final week = json['week'];
    if (week is Map) {
      for (final identity in week.entries) {
        final key = identity.key;
        final hours = identity.value;
        if (key is! String || hours is! Map) continue;
        // Week cells only for identities the day-map admitted: the
        // day-map is the identity ledger and carries the cap.
        if (!atlas._byIdentity.containsKey(key)) continue;
        for (final hourEntry in hours.entries) {
          final hourKey = hourEntry.key;
          if (hourKey is! String) continue;
          final hour = int.tryParse(hourKey);
          if (hour == null || hour < 0 || hour >= weekBuckets) continue;
          final cell = _HourCell.fromJson(hourEntry.value);
          if (cell == null) continue;
          atlas._weekByIdentity.putIfAbsent(key, () => {})[hour] = cell;
        }
      }
    }
    final transitions = json['transitions'];
    if (transitions is Map) {
      for (final from in transitions.entries) {
        final fromKey = from.key;
        final successors = from.value;
        if (fromKey is! String || successors is! Map) continue;
        if (atlas._transitions.length >= atlas.maxIdentities) break;
        final restored = <String, int>{};
        for (final to in successors.entries) {
          final toKey = to.key;
          final count = to.value;
          if (toKey is! String || count is! int || count <= 0) continue;
          restored[toKey] = count;
          if (restored.length >= maxSuccessors) break;
        }
        if (restored.isNotEmpty) atlas._transitions[fromKey] = restored;
      }
    }
    return atlas;
  }
}
