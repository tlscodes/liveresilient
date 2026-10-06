// ignore_for_file: avoid_print
// What an idle install costs the relay: the real service, the real pair
// shelf and the real counted transport, against a relay on loopback, with
// eight hours of schedule run on a clock that the service's own sleep moves
// forward. One pinned peer, nobody writing, the app open the whole time.
//
// The line is 400 requests a day, taken as three times what eight hours
// cost: 133 in eight hours. The count depends on what the reader knows
// about its peer's shelves, so each state it can be in is run.
// Lab only: nothing here is a device result.
//
// Plain `test`, never `testWidgets`: the widget binding replaces HttpClient.
import 'package:flutter_test/flutter_test.dart';

import 'support/loopback_relay.dart';

const int _lineInEightHours = 133;

void main() {
  late LoopbackRelay relay;
  late TestInstall mac;
  late TestInstall phone;

  setUp(() async {
    relay = await LoopbackRelay.start();
    mac = TestInstall();
    phone = TestInstall();
    await mac.ready();
    await phone.ready();
    await mac.pin(phone);
    await phone.pin(mac);
  });

  tearDown(() => relay.stop());

  /// The phone writes one text at [at]; the Mac app is opened, reads it,
  /// and is closed again.
  Future<void> phoneWroteAndMacReadIt(DateTime at) async {
    phone.now = at;
    final writing = phone.service(relay);
    await writing.send(toInstall: mac.id, body: utf8Of('earlier'));
    await writing.flush();
    await writing.dispose();
    mac.now = at.add(const Duration(minutes: 1));
    final reading = mac.service(relay);
    expect(await reading.look(), isTrue);
    expect(reading.inbox.value.single.text, 'earlier');
    await reading.dispose();
  }

  /// Opens the Mac app at [start] and leaves it open and idle for [length].
  Future<({int requests, int fast, int slow, Duration longest})> idle(
    DateTime start, {
    Duration length = const Duration(hours: 8),
  }) async {
    final sim = SimClock(start)..until = start.add(length);
    mac.now = start;
    final budget = mac.budget();
    final before = relay.requests.length;
    final service = mac.service(
      relay,
      budget: budget,
      sleep: (wait) async {
        await sim.sleep(wait);
        mac.now = sim.now;
      },
    );
    service.start();
    await sim.reached;
    final count = budget.now;
    final asked = relay.requests.sublist(before);
    await service.dispose();
    // Idle means looking and nothing else: every request asked one shelf
    // whether it has anything at the next number.
    expect(asked.every((r) => r.startsWith('GET /a/')), isTrue);
    expect(asked.length, count.sinceStart);
    expect(mac.of('warm'), isEmpty, reason: 'nothing warmed it after start');
    final vitals = mac.of('stop').last;
    print(
      'idle ${length.inHours} h from ${start.toIso8601String()}: '
      '${count.sinceStart} requests '
      '(${vitals['looks_fast']} fast looks, ${vitals['looks_slow']} slow), '
      'x3 = ${count.sinceStart * 3} a day',
    );
    return (
      requests: count.sinceStart,
      fast: vitals['looks_fast']! as int,
      slow: vitals['looks_slow']! as int,
      longest: count.longestOpen,
    );
  }

  group('eight idle hours, one pinned peer', () {
    test('the looks: 40 warm, then doubling, then every fifteen minutes; '
        'the other days every half hour', () async {
      final cost = await idle(DateTime.utc(2026, 10, 6, 12));
      // 0..117 s every 3 s (40), then 120, 126, 138, 162, 210, 306, 498,
      // 882 and 1650 s (9), then every 900 s up to eight hours (30).
      expect(cost.fast, 79);
      // The first look covers every day; then one each half hour (16).
      expect(cost.slow, 17);
    });

    test('a peer who has never written: the most it can cost', () async {
      final cost = await idle(DateTime.utc(2026, 10, 6, 12));
      // First look: four day shelves. Then today's shelf alone at every
      // fast look (78) — yesterday's rests — and the three others at every
      // slow look (16 x 3).
      expect(cost.requests, 4 + 78 + 16 * 3);
      expect(cost.requests, lessThanOrEqualTo(_lineInEightHours));
      expect(cost.longest, lessThan(const Duration(seconds: 2)));
    });

    test('a peer who last wrote yesterday', () async {
      await phoneWroteAndMacReadIt(DateTime.utc(2026, 10, 5, 11));
      final cost = await idle(DateTime.utc(2026, 10, 6, 12));
      // Two days back is closed: its writer has been seen on a later day.
      expect(cost.requests, 4 + 78 + 16 * 2);
      expect(cost.requests, lessThanOrEqualTo(_lineInEightHours));
    });

    test('a peer who wrote today', () async {
      await phoneWroteAndMacReadIt(DateTime.utc(2026, 10, 6, 11));
      final cost = await idle(DateTime.utc(2026, 10, 6, 12));
      // Yesterday and the day before are closed; only tomorrow's shelf is
      // left for the slow look.
      expect(cost.requests, 4 + 78 + 16);
      expect(cost.requests, lessThanOrEqualTo(_lineInEightHours));
    });

    test(
      'a peer who wrote today, and midnight passes while it idles',
      () async {
        await phoneWroteAndMacReadIt(DateTime.utc(2026, 10, 6, 17));
        final cost = await idle(DateTime.utc(2026, 10, 6, 17, 30));
        expect(cost.requests, lessThanOrEqualTo(_lineInEightHours));
        expect(cost.requests, 102);
      },
    );

    test('a peer who has never written, and midnight passes', () async {
      final cost = await idle(DateTime.utc(2026, 10, 6, 17, 30));
      expect(cost.requests, lessThanOrEqualTo(_lineInEightHours));
    });
  });

  group('a whole day open and idle', () {
    test('costs less than the line without the three-times rule', () async {
      final cost = await idle(
        DateTime.utc(2026, 10, 6, 12),
        length: const Duration(hours: 24),
      );
      expect(cost.requests, lessThanOrEqualTo(400));
    });
  });
}
