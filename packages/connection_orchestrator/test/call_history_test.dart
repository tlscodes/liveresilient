/// Pins the CallHistoryStore contract: FIFO eviction at capacity, full
/// JSON round-trip fidelity (including the quality timeline), and
/// corrupt-JSON safety at both the store and record level.
import 'dart:convert';

import 'package:connection_orchestrator/src/call_history.dart';
import 'package:test/test.dart';

CallHistoryRecord record(int startedUtcMs) => CallHistoryRecord(
  startedUtcMs: startedUtcMs,
  connectMs: 480,
  recoveries: 1,
  dropsToFloor: 0,
  networkIdentityHash: 'abc123',
  endReason: 'hangup',
  qualityTimeline: const [
    QualitySample(tMs: 0, score: 0.9),
    QualitySample(tMs: 1000, score: 0.4),
  ],
);

void main() {
  group('FIFO eviction', () {
    test('oldest record leaves when capacity is exceeded', () {
      final store = CallHistoryStore(capacity: 3);
      for (var i = 1; i <= 5; i++) {
        store.add(record(i));
      }
      expect(store.records.length, 3);
      expect([for (final r in store.records) r.startedUtcMs], [3, 4, 5]);
    });

    test('records view is read-only', () {
      final store = CallHistoryStore()..add(record(1));
      expect(() => store.records.add(record(2)), throwsUnsupportedError);
    });
  });

  group('JSON round-trip', () {
    test('every field survives encode/decode, timeline included', () {
      final store = CallHistoryStore()
        ..add(record(1000))
        ..add(
          const CallHistoryRecord(
            startedUtcMs: 2000,
            connectMs: 120,
            recoveries: 0,
            dropsToFloor: 2,
            networkIdentityHash: 'def456',
            endReason: 'network-lost',
          ),
        );
      final decoded = jsonDecode(jsonEncode(store.toJson()));
      final restored = CallHistoryStore.fromJson(decoded);
      expect(restored.records.length, 2);
      final first = restored.records[0];
      expect(first.startedUtcMs, 1000);
      expect(first.connectMs, 480);
      expect(first.recoveries, 1);
      expect(first.dropsToFloor, 0);
      expect(first.networkIdentityHash, 'abc123');
      expect(first.endReason, 'hangup');
      expect(first.qualityTimeline.length, 2);
      expect(first.qualityTimeline[0].tMs, 0);
      expect(first.qualityTimeline[0].score, 0.9);
      expect(first.qualityTimeline[1].tMs, 1000);
      expect(first.qualityTimeline[1].score, 0.4);
      final second = restored.records[1];
      expect(second.startedUtcMs, 2000);
      expect(second.endReason, 'network-lost');
      expect(second.qualityTimeline, isEmpty);
    });
  });

  group('corrupt safety', () {
    test('non-list JSON degrades to an empty store', () {
      expect(CallHistoryStore.fromJson('garbage').records, isEmpty);
      expect(CallHistoryStore.fromJson(null).records, isEmpty);
      expect(CallHistoryStore.fromJson(42).records, isEmpty);
    });

    test('corrupt entries are skipped, valid ones survive', () {
      final restored = CallHistoryStore.fromJson([
        record(1).toJson(),
        42,
        {'startedUtcMs': 'bad'},
        record(2).toJson(),
      ]);
      expect(restored.records.length, 2);
      expect([for (final r in restored.records) r.startedUtcMs], [1, 2]);
    });

    test('corrupt timeline samples are dropped without sinking the record', () {
      final raw = record(1).toJson();
      raw['qualityTimeline'] = [
        {'tMs': 0, 'score': 0.9},
        {'tMs': 'bad', 'score': 0.5},
        {'tMs': 100, 'score': 'bad'},
        7,
      ];
      final restored = CallHistoryStore.fromJson([raw]);
      expect(restored.records.length, 1);
      expect(restored.records[0].qualityTimeline.length, 1);
      expect(restored.records[0].qualityTimeline[0].score, 0.9);
    });

    test('restore applies the FIFO cap', () {
      final restored = CallHistoryStore.fromJson([
        for (var i = 1; i <= 5; i++) record(i).toJson(),
      ], capacity: 2);
      expect([for (final r in restored.records) r.startedUtcMs], [4, 5]);
    });
  });
}
