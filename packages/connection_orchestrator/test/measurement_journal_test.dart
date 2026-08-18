/// Pins the MeasurementJournal contract: monotonic never-reused ids
/// across ring eviction AND across serialize/restore, byId miss -> null,
/// newest-first recent(), the injected clock, and corrupt-JSON safety.
import 'dart:convert';

import 'package:connection_orchestrator/src/measurement_journal.dart';
import 'package:test/test.dart';

void main() {
  group('id monotonicity across eviction', () {
    test('ids keep increasing after the ring evicts old records', () {
      var t = 0;
      final journal = MeasurementJournal(capacity: 3, nowMs: () => ++t);
      final ids = [
        for (var i = 0; i < 5; i++)
          journal.add(kind: 'connectMs', value: i.toDouble(), unit: 'ms').id,
      ];
      expect(ids, ['m1', 'm2', 'm3', 'm4', 'm5']);
      // The two oldest were evicted — their ids point at nothing now, and
      // are never reissued.
      expect(journal.byId('m1'), isNull);
      expect(journal.byId('m2'), isNull);
      expect(journal.byId('m3'), isNotNull);
      expect(journal.byId('m5'), isNotNull);
      final next = journal.add(kind: 'connectMs', value: 9, unit: 'ms');
      expect(next.id, 'm6');
    });
  });

  group('id monotonicity across serialize/restore', () {
    test('the counter high-water mark survives a JSON round-trip', () {
      var t = 0;
      final journal = MeasurementJournal(capacity: 2, nowMs: () => ++t * 100);
      journal.add(kind: 'connectMs', value: 480, unit: 'ms', context: 'wifi');
      journal.add(kind: 'lossFraction', value: 0.02, unit: 'fraction');
      journal.add(kind: 'rttMs', value: 150, unit: 'ms');
      final decoded =
          jsonDecode(jsonEncode(journal.toJson())) as Map<String, Object?>;
      final restored = MeasurementJournal(capacity: 2, nowMs: () => 0);
      // (restored via factory below; this instance is just the shape)
      final fromJson = MeasurementJournal.fromJson(
        decoded,
        capacity: 2,
        nowMs: () => 0,
      );
      expect(restored.byId('m2'), isNull); // fresh journal knows nothing
      // Retained records survive with full fidelity.
      final m3 = fromJson.byId('m3');
      expect(m3, isNotNull);
      expect(m3!.kind, 'rttMs');
      expect(m3.value, 150);
      expect(m3.unit, 'ms');
      expect(m3.tsMs, 300);
      final m2 = fromJson.byId('m2');
      expect(m2!.context, isNull);
      // Evicted id stays a miss, and the counter continues past the
      // high-water mark — never back to m1.
      expect(fromJson.byId('m1'), isNull);
      expect(fromJson.add(kind: 'connectMs', value: 1, unit: 'ms').id, 'm4');
    });

    test('a corrupt counter is rebuilt from the highest restored id', () {
      final fromJson = MeasurementJournal.fromJson({
        'counter': 'garbage',
        'records': [
          {'id': 'm7', 'tsMs': 1, 'kind': 'rttMs', 'value': 9.0, 'unit': 'ms'},
        ],
      }, nowMs: () => 0);
      expect(fromJson.byId('m7'), isNotNull);
      expect(fromJson.add(kind: 'rttMs', value: 1, unit: 'ms').id, 'm8');
    });
  });

  group('lookup and recency', () {
    test('byId miss returns null', () {
      final journal = MeasurementJournal(nowMs: () => 0);
      expect(journal.byId('m1'), isNull);
      expect(journal.byId('nonsense'), isNull);
    });

    test('recent returns the last n records newest first', () {
      var t = 0;
      final journal = MeasurementJournal(nowMs: () => ++t);
      for (var i = 1; i <= 5; i++) {
        journal.add(kind: 'k', value: i.toDouble(), unit: 'u');
      }
      expect([for (final r in journal.recent(2)) r.id], ['m5', 'm4']);
      // Default n=20 caps at what exists.
      expect(
        [for (final r in journal.recent()) r.id],
        ['m5', 'm4', 'm3', 'm2', 'm1'],
      );
    });

    test('tsMs comes from the injected clock', () {
      final journal = MeasurementJournal(nowMs: () => 12345);
      final ref = journal.add(kind: 'k', value: 1, unit: 'u');
      expect(journal.byId(ref.id)!.tsMs, 12345);
    });
  });

  group('corrupt safety', () {
    test('garbage JSON degrades to a fresh journal', () {
      final fromJson = MeasurementJournal.fromJson({
        'counter': -3,
        'records': 'not-a-list',
      }, nowMs: () => 0);
      expect(fromJson.recent(), isEmpty);
      expect(fromJson.add(kind: 'k', value: 1, unit: 'u').id, 'm1');
    });

    test('corrupt records are skipped, valid ones survive', () {
      final fromJson = MeasurementJournal.fromJson({
        'counter': 4,
        'records': [
          42,
          {'id': 'x9', 'tsMs': 1, 'kind': 'k', 'value': 1.0, 'unit': 'u'},
          {'id': 'm2', 'tsMs': 'bad', 'kind': 'k', 'value': 1.0, 'unit': 'u'},
          {'id': 'm3', 'tsMs': 1, 'kind': 'k', 'value': 'bad', 'unit': 'u'},
          {'id': 'm4', 'tsMs': 7, 'kind': 'k', 'value': 2.0, 'unit': 'u'},
        ],
      }, nowMs: () => 0);
      expect(fromJson.recent().length, 1);
      expect(fromJson.byId('m4')!.value, 2.0);
      expect(fromJson.add(kind: 'k', value: 1, unit: 'u').id, 'm5');
    });
  });
}
