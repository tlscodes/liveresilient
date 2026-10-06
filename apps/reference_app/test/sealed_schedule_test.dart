// When the sealed-letter service looks, and what "on" means. The real
// service on a clock its own sleep moves forward, so hours of schedule run
// in an instant; the shelf writes down every look and every put with the
// time it was made. Lab only: nothing here is a device result.
//
// Plain `test`, never `testWidgets`: the widget binding replaces HttpClient.
import 'dart:io' show pid;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/sealed/pair_shelf.dart';
import 'package:reference_app/src/sealed/sealed_box.dart';
import 'package:reference_app/src/sealed/sealed_content.dart';
import 'package:reference_app/src/sealed/sealed_letter_service.dart';

import 'support/loopback_relay.dart';

/// A shelf that keeps what it is asked and when.
class _RecordingShelf implements LetterShelf {
  _RecordingShelf(this._now);

  final DateTime Function() _now;
  final List<({DateTime at, ShelfLook look})> looks = [];
  final List<DateTime> puts = [];
  bool down = false;

  /// Handed over at the next look.
  final List<Uint8List> arriving = [];

  @override
  final Map<String, int> cursors = <String, int>{};

  @override
  Future<bool> put(String peerInstall, Uint8List box) async {
    puts.add(_now());
    return !down;
  }

  @override
  Future<List<Uint8List>?> collect(
    String peerInstall, {
    ShelfLook look = ShelfLook.all,
  }) async {
    looks.add((at: _now(), look: look));
    if (down) return null;
    final boxes = List<Uint8List>.of(arriving);
    arriving.clear();
    return boxes;
  }
}

void main() {
  final start = DateTime.utc(2026, 10, 6, 12);
  late TestInstall mac;
  late TestInstall phone;
  late SimClock sim;
  late _RecordingShelf shelf;
  late SealedLetterService service;

  setUp(() async {
    mac = TestInstall();
    phone = TestInstall();
    await mac.ready();
    await phone.ready();
    await mac.pin(phone);
    await phone.pin(mac);
    sim = SimClock(start);
    shelf = _RecordingShelf(() => sim.now);
    service = SealedLetterService(
      identity: mac.identity,
      shelf: shelf,
      storage: mac.letters,
      clock: () => sim.now,
      sleep: sim.sleep,
      onEvent: (event, fields) => mac.events.add((event, fields)),
    );
  });

  tearDown(() => service.dispose());

  /// Runs the service until the clock is [length] past the start.
  Future<void> run(Duration length) async {
    sim.until = start.add(length);
    service.start();
    await sim.reached;
  }

  int offset(DateTime at) => at.difference(start).inSeconds;

  /// Seconds after the start of every look that covered today's shelf.
  List<int> fastLooks() => [
    for (final l in shelf.looks)
      if (l.look != ShelfLook.slow) offset(l.at),
  ];

  List<int> slowLooks() => [
    for (final l in shelf.looks)
      if (l.look == ShelfLook.slow) offset(l.at),
  ];

  Future<Uint8List> fromPhone(
    SealedKind kind,
    String letterId,
    Uint8List body,
  ) => SealedBoxCodec(phone.identity).seal(
    recipientInstall: mac.id,
    recipientKey: mac.key,
    kind: kind,
    letterId: letterId,
    createdAt: sim.now,
    body: body,
  );

  group('how often it looks', () {
    test('every three seconds for two minutes after the app is opened, then '
        'at twice the interval each time, down to fifteen minutes', () async {
      await run(const Duration(hours: 2));
      expect(fastLooks(), [
        for (var s = 0; s < 120; s += 3) s,
        120,
        126,
        138,
        162,
        210,
        306,
        498,
        882,
        1650,
        2550,
        3450,
        4350,
        5250,
        6150,
        7050,
      ]);
      expect(shelf.looks.first.look, ShelfLook.all);
      expect(
        shelf.looks.skip(1).every((l) => l.look != ShelfLook.all),
        isTrue,
        reason: 'only the first look covers every day',
      );
    });

    test('the other days every half hour, on a clock of their own', () async {
      await run(const Duration(hours: 2));
      expect(slowLooks(), [1800, 3600, 5400, 7200]);
    });

    test('writing warms it again: a look every three seconds for the next '
        'two minutes', () async {
      sim.plan(const Duration(hours: 1), () async {
        await service.send(toInstall: phone.id, body: utf8Of('hello'));
      });
      await run(const Duration(hours: 1, minutes: 3));
      final after = fastLooks().where((s) => s >= 3600).toList();
      expect(after.take(41), [for (var s = 3600; s <= 3720; s += 3) s]);
      expect(after.skip(41).take(3), [3726, 3738, 3762]);
      expect(mac.of('warm').single['why'], 'write');
    });

    test('opening the screen looks at once, and warms it', () async {
      sim.plan(const Duration(hours: 1), () async => service.touch());
      await run(const Duration(hours: 1, minutes: 1));
      final after = fastLooks().where((s) => s >= 3600).toList();
      expect(after.take(3), [3600, 3603, 3606]);
      expect(mac.of('warm').single['why'], 'screen');
    });

    test('a letter arriving warms it', () async {
      // Shelved between two looks: the next one is the fast look at 4350 s.
      sim.plan(const Duration(hours: 1, minutes: 5), () async {
        shelf.arriving.add(
          await fromPhone(
            SealedKind.letter,
            SealedBoxCodec(phone.identity).newLetterId(),
            const SealedContent.text('are you there').encode(),
          ),
        );
      });
      await run(const Duration(hours: 1, minutes: 20));
      // It is found by the next look on the cold schedule, at 4350 s.
      expect(service.inbox.value.single.text, 'are you there');
      final after = fastLooks().where((s) => s >= 4350).toList();
      expect(after.take(4), [4350, 4353, 4356, 4359]);
      expect(mac.of('warm').single['why'], 'letter');
    });

    test('a receipt arriving does not', () async {
      late SealedSent sent;
      sim.plan(const Duration(seconds: 10), () async {
        sent = await service.send(toInstall: phone.id, body: utf8Of('x'));
      });
      sim.plan(const Duration(hours: 1), () async {
        final body = const SealedContent.text('x').encode();
        shelf.arriving.add(
          await fromPhone(
            SealedKind.receipt,
            sent.id,
            Uint8List.fromList((await Sha256().hash(body)).bytes),
          ),
        );
      });
      await run(const Duration(hours: 1, minutes: 40));
      expect(service.outbox.value.single.delivered, isTrue);
      expect(mac.of('receipt_rx'), hasLength(1));
      expect(mac.of('warm'), isEmpty);
      // The write at 10 s kept it warm until 130 s, so the cold looks fall
      // twelve seconds later than from a quiet start: the receipt is found
      // at 4362 s and the next look is a full fifteen minutes after it.
      expect(fastLooks().where((s) => s > 3600), [4362, 5262]);
    });
  });

  group('nobody is told', () {
    test('an install that comes on and idles puts nothing on the relay: no '
        '"I am here", to anyone', () async {
      await run(const Duration(hours: 1));
      expect(shelf.puts, isEmpty);
      expect(mac.events.map((e) => e.$1).toSet(), {'start'});
    });

    test('an "I am here" from an install built before it was removed is '
        'opened and nothing follows from it', () async {
      sim.plan(const Duration(seconds: 30), () async {
        shelf.arriving.add(
          await fromPhone(
            SealedKind.here,
            SealedBoxCodec(phone.identity).newLetterId(),
            Uint8List(0),
          ),
        );
      });
      await run(const Duration(minutes: 5));
      expect(service.inbox.value, isEmpty);
      expect(shelf.puts, isEmpty, reason: 'nothing is answered');
      expect(mac.events.map((e) => e.$1).toSet(), {'start'});
    });
  });

  group('when the relay is out of reach', () {
    test('it is asked on the same schedule, and the letters behind the '
        'first wait for its next try', () async {
      shelf.down = true;
      sim.plan(const Duration(seconds: 1), () async {
        await service.send(toInstall: phone.id, body: utf8Of('one'));
        await service.flush();
        await service.send(toInstall: phone.id, body: utf8Of('two'));
        await service.send(toInstall: phone.id, body: utf8Of('three'));
        await service.flush();
      });
      sim.plan(const Duration(minutes: 1), () async => shelf.down = false);
      await run(const Duration(seconds: 59));
      // One letter is tried, with a growing pause; the others are not.
      final tried = service.outbox.value.map((s) => s.attempts).toList();
      expect(tried.first, greaterThan(1));
      expect(tried.skip(1), [0, 0]);
      expect(shelf.puts.length, tried.first);
      expect(service.relay.value, SealedRelayState.unreachable);
      expect(
        service.outbox.value.first.describe(sim.now),
        contains('relay unreachable'),
      );
      expect(
        service.outbox.value.last.describe(sim.now),
        'in queue — not on the relay yet',
      );
      // The looks did not speed up because it was down.
      expect(fastLooks().take(5), [0, 3, 6, 9, 12]);

      await service.stop();
      await run(const Duration(minutes: 3));
      expect(service.outbox.value.every((s) => s.onShelf), isTrue);
      expect(service.relay.value, SealedRelayState.reachable);
    });
  });

  group('"on" is a line in the journal', () {
    test('one at start, one every thirty seconds, one at stop — and none '
        'after it', () async {
      final relay = await LoopbackRelay.start();
      addTearDown(relay.stop);
      final live = mac.service(
        relay,
        aliveEvery: const Duration(milliseconds: 40),
      );
      addTearDown(live.dispose);
      mac.events.clear();
      live.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final begun = mac.of('start').single;
      expect(begun['pid'], pid);
      expect(begun['peers'], 1);
      expect(begun['cap'], 3000);
      expect(begun['warm_every_s'], 3);
      expect(begun['cold_every_s'], 900);
      expect(begun['slow_every_s'], 1800);
      expect(begun['alive_every_s'], 0, reason: 'this test beats in ms');
      final beats = mac.of('alive').toList();
      expect(beats.length, greaterThanOrEqualTo(4));
      final beat = beats.last;
      expect(beat['pid'], pid);
      expect(beat['req_start'], 4, reason: 'the first look: four day shelves');
      expect(beat['longest_ms'], lessThan(2000));
      expect(beat['open_now'], 0);
      expect(beat['warm'], isTrue);
      expect(beat['relay'], 'reachable');

      await live.stop();
      expect(mac.of('stop'), hasLength(1));
      final heard = mac.of('alive').length;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(mac.of('alive').length, heard, reason: 'off means no more lines');
    });
  });

  group("the day's allowance", () {
    test('looking stops at its share and the screen is told; writing still '
        'has the rest; the next day starts afresh', () async {
      final relay = await LoopbackRelay.start();
      addTearDown(relay.stop);
      final clock = SimClock(start)
        ..until = start.add(const Duration(hours: 8));
      mac.now = start;
      final budget = mac.budget(dailyCap: 60, lookShare: 0.5);
      final capped = mac.service(
        relay,
        budget: budget,
        sleep: (wait) async {
          await clock.sleep(wait);
          mac.now = clock.now;
        },
      );
      addTearDown(capped.dispose);
      capped.start();
      await clock.reached;
      expect(budget.now.usedToday, 30);
      expect(relay.requests, hasLength(30));
      expect(capped.relay.value, SealedRelayState.spent);

      // A letter can still be written: object and pointer.
      await capped.send(toInstall: phone.id, body: utf8Of('still goes'));
      await capped.flush();
      expect(capped.outbox.value.single.onShelf, isTrue);
      expect(budget.now.usedToday, 32);

      // Past midnight the count starts again and looking resumes.
      await capped.stop();
      mac.now = DateTime.utc(2026, 10, 7, 0, 30);
      expect(budget.now.usedToday, 0);
      expect(await capped.look(look: ShelfLook.fast), isTrue);
      expect(capped.relay.value, SealedRelayState.reachable);
    });
  });
}
