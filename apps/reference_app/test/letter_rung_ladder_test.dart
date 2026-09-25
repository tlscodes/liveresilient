// The ladder's own memory, with no fabric and no network: a delivered
// attempt becomes the next Send's previous winner, a queued one never
// does, and history is capped so the file never grows without bound.
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/intelligence/disk_json_storage.dart';
import 'package:reference_app/src/letter_rung_ladder.dart';

class _MemoryStorage implements PersistentStorage {
  Map<String, Object?> data = {};

  @override
  Future<Map<String, Object?>> load() async => Map<String, Object?>.from(data);

  @override
  Future<void> save(Map<String, Object?> data) async {
    this.data = Map<String, Object?>.from(data);
  }
}

void main() {
  test('a confirmed rung is stored as the next previous winner', () async {
    final ladder = LetterRungLadder(_MemoryStorage());
    expect(await ladder.previousWinner('wifi:home'), isNull);

    await ladder.record(
      'wifi:home',
      const LetterRungAttempt(
        rung: 'resilient.dns-valve',
        resolver: 'udp53:8.8.8.8:53',
        latencyMs: 420,
        outcome: LetterRungOutcome.delivered,
      ),
    );

    expect(await ladder.previousWinner('wifi:home'), 'resilient.dns-valve');
  });

  test('a queued attempt is recorded but never becomes the winner', () async {
    final ladder = LetterRungLadder(_MemoryStorage());
    await ladder.record(
      'wifi:home',
      const LetterRungAttempt(
        rung: 'resilient.wss',
        outcome: LetterRungOutcome.delivered,
      ),
    );
    expect(await ladder.previousWinner('wifi:home'), 'resilient.wss');

    // Every rung dead this time: queued, not delivered — the stored
    // winner from the earlier delivery must survive untouched.
    await ladder.record(
      'wifi:home',
      const LetterRungAttempt(
        rung: 'resilient.wss',
        outcome: LetterRungOutcome.queued,
      ),
    );
    expect(await ladder.previousWinner('wifi:home'), 'resilient.wss');
  });

  test('networks are independent', () async {
    final ladder = LetterRungLadder(_MemoryStorage());
    await ladder.record(
      'wifi:home',
      const LetterRungAttempt(
        rung: 'resilient.wss',
        outcome: LetterRungOutcome.delivered,
      ),
    );
    expect(await ladder.previousWinner('cellular:mci'), isNull);
    expect(await ladder.previousWinner('wifi:home'), 'resilient.wss');
  });

  test('history is capped, newest kept', () async {
    final store = _MemoryStorage();
    final ladder = LetterRungLadder(store, maxHistoryPerNetwork: 3);
    for (var i = 0; i < 5; i++) {
      await ladder.record(
        'wifi:home',
        LetterRungAttempt(
          rung: 'resilient.wss',
          latencyMs: i,
          outcome: LetterRungOutcome.delivered,
        ),
      );
    }
    final history =
        (store.data['wifi:home'] as Map)['history'] as List<Object?>;
    expect(history, hasLength(3));
    expect(
      history.map((row) => (row as Map)['latencyMs']),
      [2, 3, 4], // oldest two (0, 1) dropped
    );
  });

  group('DoorResolverLadder.narrow — the door floor, one level under', () {
    test('a resolver with two wins comes before a resolver with zero wins, '
        'as the one competitor — the rest, no', () {
      final chosen = DoorResolverLadder.narrow<String>(
        ['prev', 'zero-wins', 'two-wins'],
        (label) => label,
        {
          'zero-wins': (wins: 0, attempts: 5),
          'two-wins': (wins: 2, attempts: 5),
        },
        'prev',
      );

      expect(chosen, ['prev', 'two-wins']); // zero-wins excluded entirely
    });

    test('empty history still means every candidate races', () {
      final chosen = DoorResolverLadder.narrow<String>(
        ['system', '8.8.8.8', '1.1.1.1'],
        (label) => label,
        const {},
        null, // no previous winner recorded yet
      );

      expect(chosen, ['system', '8.8.8.8', '1.1.1.1']);
    });

    test('a previous winner no longer among today\'s candidates falls back '
        'to the full race', () {
      final chosen = DoorResolverLadder.narrow<String>(
        ['8.8.8.8', '1.1.1.1'],
        (label) => label,
        {'8.8.8.8': (wins: 3, attempts: 3)},
        'stale-resolver-not-in-todays-list',
      );

      expect(chosen, ['8.8.8.8', '1.1.1.1']);
    });

    test('a higher win rate sorts before a lower one among the rivals', () {
      final chosen = DoorResolverLadder.narrow<String>(
        ['prev', 'low', 'high'],
        (label) => label,
        {'low': (wins: 1, attempts: 10), 'high': (wins: 8, attempts: 10)},
        'prev',
      );

      expect(chosen, ['prev', 'high']); // high (0.8) named before low (0.1)
    });

    test('two rivals with close win rates both keep racing; only the clear '
        'straggler is dropped', () {
      final chosen = DoorResolverLadder.narrow<String>(
        ['prev', 'a', 'b', 'c'],
        (label) => label,
        {
          'a': (wins: 3, attempts: 10), // 0.3
          'b': (wins: 4, attempts: 10), // 0.4 — within 0.15 of 'a'
          'c': (wins: 0, attempts: 10), // 0.0 — far below both
        },
        'prev',
      );

      expect(chosen, ['prev', 'b', 'a']); // b first (higher), a kept, c cut
    });

    test('empty history still means the full race, even with the new '
        'closeWithin parameter in play', () {
      final chosen = DoorResolverLadder.narrow<String>(
        ['system', '8.8.8.8', '1.1.1.1'],
        (label) => label,
        const {},
        null,
      );

      expect(chosen, ['system', '8.8.8.8', '1.1.1.1']);
    });
  });

  group('DoorResolverLadder.totals and lastNetwork', () {
    test('totals sums every resolver; empty history has no ratio', () {
      final t = DoorResolverLadder.totals({
        'a': (wins: 3, attempts: 4),
        'b': (wins: 5, attempts: 6),
      });
      expect(t.wins, 8);
      expect(t.attempts, 10);
      expect(t.ratio, 0.8);
      expect(DoorResolverLadder.totals(const {}).ratio, isNull);
    });

    test('lastNetwork names the most recent probe round, not a key the '
        'history can read back', () async {
      final ladder = DoorResolverLadder(_MemoryStorage());
      expect(await ladder.lastNetwork(), isNull);
      await ladder.record('wifi:home', asked: ['x'], winner: 'x');
      await ladder.record('cellular:mci', asked: ['x'], winner: null);
      expect(await ladder.lastNetwork(), 'cellular:mci');
      expect((await ladder.history('wifi:home'))['x'], (wins: 1, attempts: 1));
    });
  });

  group('DoorResolverLadder wins/attempts bookkeeping', () {
    test(
      'a probe round updates wins/attempts and the previous winner',
      () async {
        final ladder = DoorResolverLadder(_MemoryStorage());
        expect(await ladder.history('wifi:home'), isEmpty);

        await ladder.record(
          'wifi:home',
          asked: ['system', '8.8.8.8'],
          winner: '8.8.8.8',
        );
        await ladder.record(
          'wifi:home',
          asked: ['system', '8.8.8.8'],
          winner: 'system',
        );

        final history = await ladder.history('wifi:home');
        expect(history['system'], (wins: 1, attempts: 2));
        expect(history['8.8.8.8'], (wins: 1, attempts: 2));
        // The second round's winner is the one remembered, not the first.
        expect(await ladder.previousWinner('wifi:home'), 'system');
      },
    );

    test('a miss leaves the stored previous winner untouched', () async {
      final ladder = DoorResolverLadder(_MemoryStorage());
      await ladder.record('wifi:home', asked: ['8.8.8.8'], winner: '8.8.8.8');
      expect(await ladder.previousWinner('wifi:home'), '8.8.8.8');

      await ladder.record('wifi:home', asked: ['8.8.8.8'], winner: null);

      expect(await ladder.previousWinner('wifi:home'), '8.8.8.8');
      expect((await ladder.history('wifi:home'))['8.8.8.8'], (
        wins: 1,
        attempts: 2,
      ));
    });
  });

  group('InstallLetterMeasurement — once per install, with consent', () {
    test('consent withheld: nothing is written, ever', () async {
      final store = _MemoryStorage();
      final measurement = InstallLetterMeasurement(store);
      const noConsent = _FixedConsent(false);

      await measurement.recordOnce(
        consent: noConsent,
        networkLabel: 'cellular:mci',
        operatorName: 'mci',
        networkType: 'cellular',
        rung: 'resilient.dns-valve',
        resolver: 'udp53:8.8.8.8:53',
        rttMs: 300,
        delivered: true,
      );

      expect(store.data, isEmpty);
      expect(await measurement.alreadyRecorded(), isFalse);

      // A null consent object is withheld too, not a crash.
      await measurement.recordOnce(
        consent: null,
        networkLabel: 'cellular:mci',
        operatorName: 'mci',
        networkType: 'cellular',
        rung: 'resilient.dns-valve',
        rttMs: 300,
        delivered: true,
      );
      expect(store.data, isEmpty);
    });

    test(
      'granted: the seven fields land once, keyed by identityHash',
      () async {
        final store = _MemoryStorage();
        final measurement = InstallLetterMeasurement(store);
        const granted = _FixedConsent(true);

        await measurement.recordOnce(
          consent: granted,
          networkLabel: 'cellular:mci',
          operatorName: 'mci',
          networkType: 'cellular',
          rung: 'resilient.dns-valve',
          resolver: 'udp53:8.8.8.8:53',
          rttMs: 300,
          delivered: true,
        );
        expect(await measurement.alreadyRecorded(), isTrue);

        // A second Send, even with consent, never overwrites the row.
        await measurement.recordOnce(
          consent: granted,
          networkLabel: 'wifi:home',
          operatorName: '',
          networkType: 'wifi',
          rung: 'resilient.wss',
          rttMs: 10,
          delivered: true,
        );
        expect(store.data.keys.where((k) => k != 'recordedOnce'), hasLength(1));
      },
    );
  });

  group('PersistedMeasurementConsent driving InstallLetterMeasurement', () {
    Iterable<String> rowKeys(Map<String, Object?> data) =>
        data.keys.where((k) => k != 'recordedOnce');

    test('off = empty file; on = one row; on again = the same row', () async {
      final consentStore = _MemoryStorage();
      final measurementStore = _MemoryStorage();
      final consent = await PersistedMeasurementConsent.load(consentStore);
      final measurement = InstallLetterMeasurement(measurementStore);

      // Off (the default): a Send never writes anything.
      await measurement.recordOnce(
        consent: consent,
        networkLabel: 'cellular:mci',
        operatorName: 'mci',
        networkType: 'cellular',
        rung: 'resilient.dns-valve',
        rttMs: 300,
        delivered: true,
      );
      expect(measurementStore.data, isEmpty);

      // On: the next Send writes exactly one row.
      await consent.setGranted(true);
      await measurement.recordOnce(
        consent: consent,
        networkLabel: 'cellular:mci',
        operatorName: 'mci',
        networkType: 'cellular',
        rung: 'resilient.dns-valve',
        resolver: 'udp53:8.8.8.8:53',
        rttMs: 300,
        delivered: true,
      );
      expect(rowKeys(measurementStore.data), hasLength(1));
      final firstRow = Map<String, Object?>.from(
        measurementStore.data[rowKeys(measurementStore.data).single] as Map,
      );

      // On again, on a different Send/network: the same row survives —
      // once per install lifetime means once, not once per network.
      await measurement.recordOnce(
        consent: consent,
        networkLabel: 'wifi:home',
        operatorName: '',
        networkType: 'wifi',
        rung: 'resilient.wss',
        rttMs: 5,
        delivered: true,
      );
      expect(rowKeys(measurementStore.data), hasLength(1));
      expect(
        measurementStore.data[rowKeys(measurementStore.data).single],
        firstRow,
      );
    });

    test('the toggle survives a reload from the same storage', () async {
      final store = _MemoryStorage();
      final firstBoot = await PersistedMeasurementConsent.load(store);
      expect(firstBoot.granted, isFalse);

      await firstBoot.setGranted(true);
      final secondBoot = await PersistedMeasurementConsent.load(store);
      expect(secondBoot.granted, isTrue);
    });
  });
}

class _FixedConsent implements LetterMeasurementConsent {
  const _FixedConsent(this.granted);
  @override
  final bool granted;
}
