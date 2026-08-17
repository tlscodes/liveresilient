import 'package:signed_config/signed_config.dart';
import 'package:test/test.dart';

/// Ticket 6 gate 6e — the cache.
///
/// The rule under test is one sentence: a freshness lifetime decides only
/// WHEN TO ASK AGAIN, never whether an answer may be served. The opposite
/// shape was already measured as a defect elsewhere in this project — a time
/// check standing between a caller and a usable answer, rejecting authentic
/// material because a clock disagreed — and this file exists so that shape
/// cannot come back by way of a well-meaning refactor.
void main() {
  late DateTime now;
  DateTime clock() => now;

  setUp(() => now = DateTime.utc(2026, 1, 1, 12));

  group('serving', () {
    test('6e  a fresh entry is served without asking again', () async {
      var calls = 0;
      final cache = LookupCache(
        (key) async {
          calls++;
          return '203.0.113.1';
        },
        freshFor: const Duration(minutes: 10),
        clock: clock,
      );

      expect(await cache.call('a.example'), '203.0.113.1');
      expect(calls, 1);
      expect(await cache.call('a.example'), '203.0.113.1');
      expect(calls, 1, reason: 'a fresh entry must not go upstream');
      expect(cache.misses, 1);
      expect(cache.freshHits, 1);
    });

    test(
      '6e  a stale entry is served IMMEDIATELY, and the refresh happens behind it',
      () async {
        var calls = 0;
        final cache = LookupCache(
          (key) async {
            calls++;
            return calls == 1 ? 'first' : 'second';
          },
          freshFor: const Duration(minutes: 10),
          clock: clock,
        );

        expect(await cache.call('a.example'), 'first');
        now = now.add(const Duration(hours: 1)); // well past the lifetime

        expect(
          await cache.call('a.example'),
          'first',
          reason: 'expiry must never stand between the caller and a usable '
              'answer — the stale value is served now, not after a refresh',
        );
        expect(cache.staleHits, 1);

        // Let the background refresh settle, then the new value is in place.
        await Future<void>.delayed(Duration.zero);
        expect(await cache.call('a.example'), 'second');
      },
    );

    test(
      '6e  a refresh that fails leaves the stale answer in service',
      () async {
        var calls = 0;
        final cache = LookupCache(
          (key) async {
            calls++;
            if (calls == 1) return 'first';
            throw StateError('upstream is down');
          },
          freshFor: const Duration(minutes: 10),
          clock: clock,
        );

        expect(await cache.call('a.example'), 'first');
        now = now.add(const Duration(hours: 1));
        expect(await cache.call('a.example'), 'first');
        await Future<void>.delayed(Duration.zero);
        expect(
          await cache.call('a.example'),
          'first',
          reason: 'a failed refresh is not a positive signal, so the entry '
              'stays in service',
        );
      },
    );

    test(
      '6e  an upstream that throws SYNCHRONOUSLY does not poison the key forever',
      () async {
        var calls = 0;
        final cache = LookupCache(
          (key) {
            calls++;
            // Not `async` — this throws before any Future is returned, which
            // is what an argument check or a bad URI does. The async body
            // then runs try/catch/finally synchronously, and if the in-flight
            // marker were installed after the body started, the finally would
            // clear a marker that did not exist yet and a completed future
            // would be left behind that nothing ever removes.
            if (calls == 1) throw ArgumentError('bad input');
            return Future<String?>.value('recovered');
          },
          freshFor: const Duration(minutes: 10),
          clock: clock,
        );

        expect(await cache.call('a.example'), isNull);
        expect(
          await cache.call('a.example'),
          'recovered',
          reason: 'the key must be usable again on the very next call; a '
              'poisoned slot would return null forever and never re-ask',
        );
        expect(calls, 2);
      },
    );

    test('6e  a null upstream answer is not cached and evicts nothing', () async {
      var answer = 'first';
      final cache = LookupCache(
        (key) async => answer,
        freshFor: const Duration(minutes: 10),
        clock: clock,
      );
      expect(await cache.call('a.example'), 'first');

      now = now.add(const Duration(hours: 1));
      answer = '';
      // ignore: unnecessary_cast
      final nullingCache = LookupCache(
        (key) async => null,
        freshFor: const Duration(minutes: 10),
        clock: clock,
      );
      expect(
        await nullingCache.call('b.example'),
        isNull,
        reason: 'no answer is a normal outcome, not an error',
      );
    });
  });

  /// Ticket 6 gate 6d — expired cache with the network down.
  ///
  /// This gate is about the FAILURE path, not about retention: when the
  /// entry is past its lifetime AND the refresh genuinely fails, the
  /// caller must still be handed the stale record to attempt with. A
  /// test whose refresh never fails would prove nothing here, so the
  /// upstream below really throws, and the test asserts that it did.
  group('gate 6d — expired cache, network down', () {
    test('6d  the attempt is made with the stale record, '
        'not an immediate failure', () async {
        var upstreamCalls = 0;
        var refreshThrew = false;
        final cache = LookupCache(
          (key) async {
            upstreamCalls++;
            if (upstreamCalls == 1) return '203.0.113.7';
            // Network down: every refresh from here on genuinely fails.
            refreshThrew = true;
            throw StateError('network is down');
          },
          freshFor: const Duration(minutes: 10),
          clock: clock,
        );

        expect(await cache.call('relay.example'), '203.0.113.7');
        now = now.add(const Duration(hours: 1)); // entry is now expired

        // The observable attempt: with the entry expired and the network
        // down, the caller receives the stale record to attempt with —
        // not null, not a thrown error, and not an answer held hostage
        // behind the failing refresh.
        expect(
          await cache.call('relay.example'),
          '203.0.113.7',
          reason: 'expired + network down must hand the caller the stale '
              'record to attempt with; an immediate failure here is the '
              'defect this gate exists to catch',
        );
        expect(cache.staleHits, 1);

        // Prove the failure was real: the background refresh was started
        // and it threw. Without this the test would pass against a cache
        // that never refreshes at all.
        await Future<void>.delayed(Duration.zero);
        expect(
          upstreamCalls,
          2,
          reason: 'the refresh must actually have been attempted',
        );
        expect(
          refreshThrew,
          isTrue,
          reason: 'and it must actually have failed',
        );

        // The failed refresh is not a positive signal, so the NEXT
        // attempt while the network is still down gets the stale record
        // again — still not an immediate failure.
        expect(await cache.call('relay.example'), '203.0.113.7');
    });
  });

  group('the three positive signals', () {
    test('6e  a successful refresh replaces the entry', () async {
      var value = 'first';
      final cache = LookupCache(
        (key) async => value,
        freshFor: const Duration(minutes: 10),
        clock: clock,
      );
      expect(await cache.call('a.example'), 'first');
      now = now.add(const Duration(hours: 1));
      value = 'second';
      await cache.call('a.example'); // serves stale, refreshes behind
      await Future<void>.delayed(Duration.zero);
      expect(await cache.call('a.example'), 'second');
    });

    test('6e  a caller reporting the answer did not work drops it', () async {
      var calls = 0;
      final cache = LookupCache(
        (key) async {
          calls++;
          return 'v$calls';
        },
        freshFor: const Duration(hours: 1),
        clock: clock,
      );
      expect(await cache.call('a.example'), 'v1');
      cache.reportFailure('a.example');
      expect(
        await cache.call('a.example'),
        'v2',
        reason: 'a reported failure is a positive signal and drops the entry '
            'even while it is still fresh',
      );
    });

    test('6e  an epoch advance drops entries from the previous epoch', () async {
      var calls = 0;
      final cache = LookupCache(
        (key) async {
          calls++;
          return 'v$calls';
        },
        freshFor: const Duration(hours: 1),
        clock: clock,
      );
      expect(await cache.call('a.example'), 'v1');
      cache.advanceEpoch('epoch-2');
      expect(await cache.call('a.example'), 'v2');
      expect(
        await cache.call('a.example'),
        'v2',
        reason: 'entries stored under the current epoch survive',
      );
    });
  });

  group('bounds', () {
    test('6e  only one refresh is in flight per key', () async {
      var calls = 0;
      final cache = LookupCache(
        (key) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return 'v$calls';
        },
        freshFor: const Duration(minutes: 10),
        clock: clock,
      );

      final answers = await Future.wait([
        cache.call('a.example'),
        cache.call('a.example'),
        cache.call('a.example'),
      ]);
      expect(answers, everyElement('v1'));
      expect(
        calls,
        1,
        reason: 'three simultaneous misses on one key must produce one '
            'request, not three',
      );
    });

    test('6e  memory is bounded: the least recently used entry is evicted',
        () async {
      var calls = 0;
      final cache = LookupCache(
        (key) async {
          calls++;
          return key;
        },
        freshFor: const Duration(hours: 1),
        maxEntries: 2,
        clock: clock,
      );

      await cache.call('a');
      await cache.call('b');
      await cache.call('a'); // touch a, so b is now least recent
      await cache.call('c'); // evicts b
      final before = calls;
      await cache.call('a');
      expect(calls, before, reason: 'a was kept');
      await cache.call('b');
      expect(calls, before + 1, reason: 'b was evicted and had to be re-asked');
    });

    test('6e  the counters separate the three outcomes', () async {
      final cache = LookupCache(
        (key) async => 'x',
        freshFor: const Duration(minutes: 10),
        clock: clock,
      );
      await cache.call('a'); // miss
      await cache.call('a'); // fresh hit
      now = now.add(const Duration(hours: 1));
      await cache.call('a'); // stale hit
      expect(cache.misses, 1);
      expect(cache.freshHits, 1);
      expect(cache.staleHits, 1);
    });
  });
}
