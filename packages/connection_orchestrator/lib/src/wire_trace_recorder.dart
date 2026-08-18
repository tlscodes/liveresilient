/// Passive wire-trace recorder: sizes, directions and inter-record timing
/// only — never payload content. Opt-in; a transport built without one does
/// no per-frame work for it.
///
/// Serialized form (frozen interface, agreed with the consuming project):
/// CSV, UTF-8, LF, one header line then one record per line:
///
///     size_bytes,direction,delta_us
///
/// `size_bytes` is the u32 payload byte count on the wire, `direction` is
/// the literal `tx` or `rx`, and `delta_us` is the u64 microsecond gap
/// since the previous record in the file — the first record is always 0.
library;

/// Direction of a traced wire event.
enum WireTraceDirection { tx, rx }

/// Accumulates (size, direction, timestamp) records in memory and
/// serializes them to the frozen CSV form.
///
/// The clock is injected so tests can supply a fake microsecond source and
/// assert the emitted file byte-for-byte. Deltas are computed at
/// serialization time from retained absolute timestamps, so dropping the
/// oldest records under [maxRecords] keeps every remaining delta correct
/// relative to the file that is actually emitted (its first record is 0).
class WireTraceRecorder {
  WireTraceRecorder({required this.nowMicros, this.maxRecords}) {
    final cap = maxRecords;
    if (cap != null && cap < 1) {
      throw ArgumentError.value(cap, 'maxRecords', 'must be >= 1');
    }
  }

  /// Injected microsecond-resolution clock.
  final int Function() nowMicros;

  /// Upper bound on retained records; oldest are dropped first. Null means
  /// unbounded.
  final int? maxRecords;

  final List<_WireTraceRecord> _records = [];

  /// Number of records currently retained.
  int get length => _records.length;

  /// Records one outbound frame of [sizeBytes] payload bytes.
  void recordTx(int sizeBytes) => _record(sizeBytes, WireTraceDirection.tx);

  /// Records one inbound datagram of [sizeBytes] payload bytes.
  void recordRx(int sizeBytes) => _record(sizeBytes, WireTraceDirection.rx);

  void _record(int sizeBytes, WireTraceDirection direction) {
    _records.add(_WireTraceRecord(sizeBytes, direction, nowMicros()));
    final cap = maxRecords;
    if (cap != null && _records.length > cap) {
      _records.removeRange(0, _records.length - cap);
    }
  }

  /// Serializes the retained records to the frozen CSV form.
  String toCsv() {
    final buffer = StringBuffer('size_bytes,direction,delta_us\n');
    int? previousMicros;
    for (final record in _records) {
      final delta = previousMicros == null
          ? 0
          : record.atMicros - previousMicros;
      previousMicros = record.atMicros;
      buffer
        ..write(record.sizeBytes)
        ..write(',')
        ..write(record.direction == WireTraceDirection.tx ? 'tx' : 'rx')
        ..write(',')
        ..write(delta)
        ..write('\n');
    }
    return buffer.toString();
  }
}

class _WireTraceRecord {
  const _WireTraceRecord(this.sizeBytes, this.direction, this.atMicros);
  final int sizeBytes;
  final WireTraceDirection direction;
  final int atMicros;
}
