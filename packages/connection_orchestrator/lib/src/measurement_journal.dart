/// The honesty substrate: an append-only ring of measurements with stable
/// citation ids.
///
/// Every sentence the stack narrates about itself must cite one of these
/// ids ("connect took 480ms [m17]"), so a claim can always be traced back
/// to the measurement that produced it. Ids are monotonically increasing
/// and are NEVER reused, even after ring eviction or a restart — an id
/// cited in an old narration must keep pointing at that one measurement
/// (or at nothing), never silently at a different one. Time is injected;
/// no wall-clock reads.
library;

/// One recorded measurement.
class MeasurementRecord {
  const MeasurementRecord({
    required this.id,
    required this.tsMs,
    required this.kind,
    required this.value,
    required this.unit,
    this.context,
  });

  /// Citation id: 'm1', 'm2', ... — stable forever, never reused.
  final String id;

  /// Timestamp from the injected clock at the moment of recording.
  final int tsMs;

  /// What was measured (e.g. 'connectMs', 'lossFraction').
  final String kind;

  final double value;

  /// Unit of [value] (e.g. 'ms', 'fraction').
  final String unit;

  /// Optional free-form origin note (e.g. a lane id or condition cell).
  final String? context;

  Map<String, Object?> toJson() => {
    'id': id,
    'tsMs': tsMs,
    'kind': kind,
    'value': value,
    'unit': unit,
    if (context != null) 'context': context,
  };
}

/// Lightweight handle returned by [MeasurementJournal.add]; narration
/// embeds its [id] as the citation.
class MeasurementRef {
  const MeasurementRef(this.id);

  final String id;

  @override
  String toString() => id;
}

/// Bounded, persistable ring of measurements with a never-resetting id
/// counter.
class MeasurementJournal {
  MeasurementJournal({
    // 500: bounded memory (~tens of KB) yet far more than one call's
    // narration ever cites — sized like the package's other ring caps.
    this.capacity = 500,
    required this.nowMs,
  });

  /// Oldest records are evicted beyond this bound; ids are not.
  final int capacity;

  /// Injected clock — library code never reads the wall clock itself.
  final int Function() nowMs;

  // Insertion-ordered, so the first key is always the oldest record.
  final Map<String, MeasurementRecord> _records = {};

  // High-water mark of issued ids. NEVER reset — not by eviction, not by
  // restore — because an id cited in an old narration must never be
  // silently reused for a different measurement.
  int _counter = 0;

  /// Records a measurement and returns its citation handle.
  MeasurementRef add({
    required String kind,
    required double value,
    required String unit,
    String? context,
  }) {
    _counter += 1;
    final id = 'm$_counter';
    _records[id] = MeasurementRecord(
      id: id,
      tsMs: nowMs(),
      kind: kind,
      value: value,
      unit: unit,
      context: context,
    );
    if (_records.length > capacity) {
      // Ring eviction: the oldest record leaves; its id stays retired.
      _records.remove(_records.keys.first);
    }
    return MeasurementRef(id);
  }

  /// The record behind a citation id, or null when it was never issued or
  /// has been evicted.
  MeasurementRecord? byId(String id) => _records[id];

  /// The last [n] records, newest first.
  List<MeasurementRecord> recent([int n = 20]) {
    // 20: a narration turn cites a handful of measurements; twenty gives
    // margin without dumping the whole ring.
    final all = _records.values.toList();
    final start = all.length > n ? all.length - n : 0;
    return all.sublist(start).reversed.toList();
  }

  Map<String, Object?> toJson() => {
    'counter': _counter,
    'records': [for (final r in _records.values) r.toJson()],
  };

  /// Restores a serialized journal. Corrupt records are skipped; the id
  /// counter is restored to the high-water mark (the stored counter or
  /// the highest id seen among restored records, whichever is larger) so
  /// ids stay unique even if the counter field itself was damaged.
  factory MeasurementJournal.fromJson(
    Map<String, Object?> json, {
    int capacity = 500,
    required int Function() nowMs,
  }) {
    final journal = MeasurementJournal(capacity: capacity, nowMs: nowMs);
    final counter = json['counter'];
    if (counter is int && counter > 0) journal._counter = counter;
    final records = json['records'];
    if (records is List) {
      for (final raw in records) {
        if (raw is! Map) continue;
        final id = raw['id'];
        final tsMs = raw['tsMs'];
        final kind = raw['kind'];
        final value = raw['value'];
        final unit = raw['unit'];
        final context = raw['context'];
        if (id is! String || !id.startsWith('m')) continue;
        final idNum = int.tryParse(id.substring(1));
        if (idNum == null || idNum <= 0) continue;
        if (tsMs is! int || kind is! String || unit is! String) continue;
        if (value is! num || !value.toDouble().isFinite) continue;
        if (context is! String?) continue;
        journal._records[id] = MeasurementRecord(
          id: id,
          tsMs: tsMs,
          kind: kind,
          value: value.toDouble(),
          unit: unit,
          context: context,
        );
        if (journal._records.length > journal.capacity) {
          journal._records.remove(journal._records.keys.first);
        }
        if (idNum > journal._counter) journal._counter = idNum;
      }
    }
    return journal;
  }
}
