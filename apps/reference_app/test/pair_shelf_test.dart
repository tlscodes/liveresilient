// The pair shelf, without a device: real crypto, the real service, the real
// counted transport, and a relay on loopback that keeps the border relay's
// archive contract — `/o/<hash>` must hash to its name, `/a/<author>/<seq>`
// must prove its author with the same three-link check the worker runs,
// both are write-once. Lab only: nothing here is a device result.
//
// Plain `test`, never `testWidgets`: the widget binding replaces HttpClient.
import 'dart:io';
import 'dart:typed_data';

import 'package:broadcast/broadcast.dart'
    show BroadcastHttpResponse, BroadcastHttpTransport;
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/sealed/pair_shelf.dart';
import 'package:reference_app/src/sealed/relay_requests.dart';
import 'package:reference_app/src/sealed/sealed_box.dart';
import 'package:reference_app/src/sealed/sealed_content.dart';
import 'package:reference_app/src/sealed/sealed_letter_service.dart';

import 'support/loopback_relay.dart';

/// Fails the request with this number (counted from 1), once.
class _FailsOnce implements BroadcastHttpTransport {
  _FailsOnce(this._inner, this.failAt);

  final BroadcastHttpTransport _inner;
  final int failAt;
  int calls = 0;

  @override
  Future<BroadcastHttpResponse> get(Uri url) {
    if (++calls == failAt) throw const SocketException('out of reach');
    return _inner.get(url);
  }

  @override
  Future<BroadcastHttpResponse> put(
    Uri url,
    Uint8List body, {
    Map<String, String> headers = const {},
  }) => _inner.put(url, body, headers: headers);
}

void main() {
  late LoopbackRelay relay;
  late TestInstall mac;
  late TestInstall phone;
  final services = <SealedLetterService>[];

  SealedLetterService on(TestInstall install) {
    final service = install.service(relay);
    services.add(service);
    return service;
  }

  setUp(() async {
    relay = await LoopbackRelay.start();
    mac = TestInstall();
    phone = TestInstall();
    await mac.ready();
    await phone.ready();
    await mac.pin(phone);
    await phone.pin(mac);
  });

  tearDown(() async {
    for (final service in services) {
      await service.dispose();
    }
    services.clear();
    await relay.stop();
  });

  /// What the phone seals for the Mac: a text letter's box.
  Future<Uint8List> boxFromPhone(String text) {
    final codec = SealedBoxCodec(phone.identity);
    return codec.seal(
      recipientInstall: mac.id,
      recipientKey: mac.key,
      kind: SealedKind.letter,
      letterId: codec.newLetterId(),
      createdAt: phone.now,
      body: SealedContent.text(text).encode(),
    );
  }

  /// How many requests [action] made.
  Future<int> asked(Future<Object?> Function() action) async {
    final before = relay.requests.length;
    await action();
    return relay.requests.length - before;
  }

  group('a letter waits on the shelf', () {
    test('the Mac writes and is switched off; the phone comes on later and '
        'opens it; the Mac learns of it the next time IT comes on', () async {
      final photo = Uint8List.fromList(
        List<int>.generate(130000, (i) => (i * 31 + (i >> 9)) & 0xff),
      );
      final writing = on(mac);
      await writing.send(
        toInstall: phone.id,
        body: utf8Of('while you were away'),
      );
      await writing.sendMedia(
        toInstall: phone.id,
        kind: SealedMediaKind.photo,
        contentType: 'image/jpeg',
        bytes: photo,
      );
      await writing.flush();
      final shelved = writing.outbox.value;
      expect(shelved.every((s) => s.onShelf), isTrue);
      expect(shelved.first.describe(mac.now), contains('on the relay'));
      expect(mac.of('tx').every((e) => e['via'] == 'shelf'), isTrue);
      await writing.dispose(); // The Mac app is off.

      // An hour later, on another clock, the phone is switched on.
      phone.now = phone.now.add(const Duration(hours: 1));
      final reading = on(phone);
      expect(await reading.look(), isTrue);
      final inbox = reading.inbox.value;
      expect(inbox.map((l) => l.content.kindLabel), ['text', 'photo']);
      expect(inbox.first.text, 'while you were away');
      expect(inbox.last.media, photo);
      expect(
        phone.of('receipt_tx').every((e) => e['deposited'] == true),
        isTrue,
      );
      await reading.dispose(); // And off again.

      // The Mac comes back to two receipts, with the phone off.
      mac.now = mac.now.add(const Duration(hours: 2));
      final back = on(mac);
      expect(await back.look(), isTrue);
      expect(back.outbox.value.every((s) => s.delivered), isTrue);
      expect(back.outbox.value.first.describe(mac.now), 'opened by them');
    });

    test(
      'what is on the relay is sealed boxes and pointers, nothing else',
      () async {
        final writing = on(mac);
        await writing.send(
          toInstall: phone.id,
          body: utf8Of('nobody else may read this'),
        );
        await writing.flush();
        expect(relay.objects, isNotEmpty);
        for (final entry in relay.objects.entries) {
          expect(entry.value.sublist(0, 5), sealedMagic);
          expect(containsBytes(entry.value, utf8Of('nobody else')), isFalse);
        }
        for (final entry in relay.pointers.entries) {
          expect(entry.value, hasLength(PairShelf.pointerBytes));
          expect(entry.value.first, PairShelf.pointerMarker);
          // The address names neither install.
          expect(entry.key, isNot(contains(mac.id)));
          expect(entry.key, isNot(contains(phone.id)));
        }
      },
    );

    test(
      'read twice, and after a relaunch: shown once, receipted once',
      () async {
        final writing = on(mac);
        await writing.send(toInstall: phone.id, body: utf8Of('once'));
        await writing.flush();
        final first = on(phone);
        await first.look();
        await first.look();
        expect(first.inbox.value, hasLength(1));
        expect(phone.of('rx'), hasLength(1));
        expect(phone.of('receipt_tx'), hasLength(1));
        await first.dispose();

        final again = on(phone);
        await again.look();
        expect(again.inbox.value, hasLength(1));
        expect(phone.of('rx'), hasLength(1), reason: 'the cursor was kept');
        expect(phone.of('receipt_tx'), hasLength(1));
      },
    );

    test(
      'both directions at once, each side off when the other writes',
      () async {
        final macWrites = on(mac);
        await macWrites.send(toInstall: phone.id, body: utf8Of('from the Mac'));
        await macWrites.flush();
        await macWrites.dispose();
        final phoneWrites = on(phone);
        await phoneWrites.send(
          toInstall: mac.id,
          body: utf8Of('from the phone'),
        );
        await phoneWrites.flush();
        await phoneWrites.look();
        expect(phoneWrites.inbox.value.single.text, 'from the Mac');
        await phoneWrites.dispose();

        final macBack = on(mac);
        await macBack.look();
        expect(macBack.inbox.value.single.text, 'from the phone');
        expect(macBack.outbox.value.single.delivered, isTrue);
        await macBack.dispose();

        final phoneBack = on(phone);
        await phoneBack.look();
        expect(phoneBack.outbox.value.single.delivered, isTrue);
      },
    );
  });

  group('only the two can use their shelf', () {
    test('a third install that knows both keys finds nothing and can put '
        'nothing there', () async {
      final writing = on(mac);
      await writing.send(toInstall: phone.id, body: utf8Of('for the phone'));
      await writing.flush();

      final third = TestInstall();
      await third.ready();
      await third.pin(mac);
      await third.pin(phone);
      final thirdShelf = third.shelf(relay);
      // It reads "the Mac's shelf for me": a different shelf, and empty.
      expect(await thirdShelf.collect(mac.id), isEmpty);

      // And a pointer written to the real shelf's address with its own
      // credentials is refused by the relay.
      final address = relay.pointers.keys.single.split('/').first;
      final client = HttpClient();
      final request = await client.openUrl(
        'PUT',
        relay.origin.replace(path: '/a/$address/1'),
      );
      request.headers.set('x-broadcast-auth', 'AAAA');
      request.add(Uint8List(114));
      final response = await request.close();
      await response.drain<void>();
      client.close(force: true);
      expect(response.statusCode, 403);
      expect(relay.pointers, hasLength(1));
    });

    test('a pointer cannot be replaced: the archive is write-once', () async {
      final writing = on(mac);
      await writing.send(toInstall: phone.id, body: utf8Of('first'));
      await writing.flush();
      final before = Map<String, Uint8List>.of(relay.pointers);
      // The same install, having lost its file and its count, writes again:
      // it steps over the taken number instead of overwriting it.
      mac.letters.data = {};
      final amnesiac = on(mac);
      await amnesiac.send(toInstall: phone.id, body: utf8Of('second'));
      await amnesiac.flush();
      for (final entry in before.entries) {
        expect(relay.pointers[entry.key], entry.value);
      }
      expect(relay.pointers.length, greaterThan(before.length));

      final reading = on(phone);
      await reading.look();
      expect(reading.inbox.value.map((l) => l.text), ['first', 'second']);
    });
  });

  group('which days a look asks about', () {
    test('the first look asks all four; then a fast look asks today, and a '
        'slow look the three others', () async {
      final shelf = mac.shelf(relay); // noon: midnight is long past
      expect(await asked(() => shelf.collect(phone.id)), 4);
      expect(
        await asked(() => shelf.collect(phone.id, look: ShelfLook.fast)),
        1,
      );
      expect(
        await asked(() => shelf.collect(phone.id, look: ShelfLook.slow)),
        3,
      );
    });

    test('yesterday is asked with today until ten minutes past midnight, '
        'then rests', () async {
      mac.now = DateTime.utc(2026, 10, 6, 0, 5);
      final shelf = mac.shelf(relay);
      Future<int> fast() =>
          asked(() => shelf.collect(phone.id, look: ShelfLook.fast));
      expect(await asked(() => shelf.collect(phone.id)), 4);
      expect(await fast(), 2, reason: 'today and yesterday');
      expect(
        await asked(() => shelf.collect(phone.id, look: ShelfLook.slow)),
        2,
        reason: 'two days back and tomorrow',
      );

      mac.now = DateTime.utc(2026, 10, 6, 0, 11);
      expect(await fast(), 2, reason: 'read to its end once more');
      expect(await fast(), 1, reason: 'and now it rests');
      expect(
        await asked(() => shelf.collect(phone.id, look: ShelfLook.slow)),
        3,
        reason: 'the slow look still asks about it',
      );
    });

    test('a letter put on yesterday\'s shelf after it rests is still found, '
        'by the slow look', () async {
      mac.now = DateTime.utc(2026, 10, 6, 12);
      final shelf = mac.shelf(relay);
      await shelf.collect(phone.id);
      // The phone's clock is half a day behind: it writes to "yesterday".
      phone.now = DateTime.utc(2026, 10, 5, 23, 59);
      expect(
        await phone.shelf(relay).put(mac.id, await boxFromPhone('late')),
        isTrue,
      );
      expect(await shelf.collect(phone.id, look: ShelfLook.fast), isEmpty);
      expect(await shelf.collect(phone.id, look: ShelfLook.slow), hasLength(1));
    });

    test('a day behind the one its writer was last seen on is closed for '
        'good', () async {
      phone.now = DateTime.utc(2026, 10, 5, 12);
      final writer = phone.shelf(relay);
      expect(await writer.put(mac.id, await boxFromPhone('monday')), isTrue);

      mac.now = DateTime.utc(2026, 10, 6, 12);
      final shelf = mac.shelf(relay);
      Future<int> slow() =>
          asked(() => shelf.collect(phone.id, look: ShelfLook.slow));
      expect(await shelf.collect(phone.id), hasLength(1));
      // Seen on the 5th: the 4th, read to its end again, is closed.
      expect(await slow(), 3);
      expect(await slow(), 2, reason: 'the 4th is not asked about any more');

      // Seen on the 6th: now the 5th closes too.
      phone.now = DateTime.utc(2026, 10, 6, 12);
      expect(await writer.put(mac.id, await boxFromPhone('tuesday')), isTrue);
      expect(await shelf.collect(phone.id, look: ShelfLook.fast), hasLength(1));
      expect(await slow(), 2, reason: 'the 5th is read to its end once more');
      expect(await slow(), 1, reason: 'only tomorrow is left');
    });

    test(
      'a writer never goes back a day, so a closed day cannot grow',
      () async {
        final writer = phone.shelf(relay);
        phone.now = DateTime.utc(2026, 10, 6, 0, 1);
        expect(await writer.put(mac.id, await boxFromPhone('one')), isTrue);
        // Its clock steps back across midnight.
        phone.now = DateTime.utc(2026, 10, 5, 23, 58);
        expect(await writer.put(mac.id, await boxFromPhone('two')), isTrue);
        expect(
          relay.pointers.keys.map((k) => k.split('/').first).toSet(),
          hasLength(1),
          reason: 'both are on the shelf of the 6th',
        );
        expect(relay.pointers.keys.map((k) => k.split('/').last).toSet(), {
          '0',
          '1',
        });
      },
    );

    test(
      'a day written under a clock that ran far ahead is not followed',
      () async {
        final writer = phone.shelf(relay);
        phone.now = DateTime.utc(2026, 10, 20, 12);
        expect(await writer.put(mac.id, await boxFromPhone('ahead')), isTrue);
        phone.now = DateTime.utc(2026, 10, 6, 12);
        expect(await writer.put(mac.id, await boxFromPhone('now')), isTrue);
        mac.now = DateTime.utc(2026, 10, 6, 12);
        // Two shelves were written to; the reader, whose clock is right,
        // looks at the 6th and finds the one written under the right clock.
        expect(
          relay.pointers.keys.map((k) => k.split('/').first).toSet(),
          hasLength(2),
        );
        expect(await mac.shelf(relay).collect(phone.id), hasLength(1));
      },
    );

    test('out of reach part-way: what was read is handed over, and the '
        'next look reads on from there', () async {
      final writer = phone.shelf(relay);
      expect(await writer.put(mac.id, await boxFromPhone('one')), isTrue);
      expect(await writer.put(mac.id, await boxFromPhone('two')), isTrue);
      // Requests of the first look: two older days (1, 2), today's first
      // pointer and box (3, 4), today's second pointer (5) — which fails.
      final shelf = PairShelf(
        identity: mac.identity,
        origin: relay.origin,
        transport: _FailsOnce(MeteredRelayTransport(budget: mac.budget()), 5),
        clock: () => mac.now,
      );
      expect(await shelf.collect(phone.id), hasLength(1));
      expect(await shelf.collect(phone.id), hasLength(1));
      expect(await shelf.collect(phone.id), isEmpty);
    });

    test('out of reach from the first request: nothing was read', () async {
      relay.down = true;
      expect(await mac.shelf(relay).collect(phone.id), isNull);
    });

    test(
      'the counts of days the relay no longer keeps are forgotten',
      () async {
        final shelf = mac.shelf(relay);
        mac.now = DateTime.utc(2026, 10, 1, 12);
        expect(await shelf.put(phone.id, await boxFromPhone('old')), isTrue);
        expect(shelf.cursors, hasLength(1));
        mac.now = DateTime.utc(2026, 10, 6, 12);
        await shelf.collect(phone.id);
        expect(shelf.cursors, isEmpty);
      },
    );
  });

  group('when the relay is out of reach or forgets', () {
    test('unreachable: the letter stays in the queue and says so; shelved '
        'later, it says that instead', () async {
      final writing = on(mac);
      relay.down = true;
      await writing.send(toInstall: phone.id, body: utf8Of('later'));
      await writing.flush();
      var letter = writing.outbox.value.single;
      expect(letter.state, SealedSentState.waiting);
      expect(letter.onShelf, isFalse);
      expect(letter.describe(mac.now), contains('relay unreachable'));

      relay.down = false;
      mac.now = mac.now.add(const Duration(seconds: 6));
      await writing.flush();
      letter = writing.outbox.value.single;
      expect(letter.onShelf, isTrue);
      expect(letter.describe(mac.now), contains('on the relay'));
      // On the shelf it is not put there again every few seconds.
      final attempts = letter.attempts;
      mac.now = mac.now.add(const Duration(hours: 1));
      await writing.flush();
      expect(writing.outbox.value.single.attempts, attempts);
    });

    test(
      'starting the app again does not shelve a waiting letter twice',
      () async {
        // Seen on the rig: coming on made every unopened letter due at
        // once, so letters already on the relay were put there again.
        final writing = on(mac);
        await writing.send(toInstall: phone.id, body: utf8Of('once is enough'));
        await writing.flush();
        final pointers = relay.pointers.length;
        await writing.dispose();

        final again = on(mac);
        await again.retryWaiting();
        await again.flush();
        expect(again.outbox.value.single.attempts, 1);
        expect(relay.pointers.length, pointers);
      },
    );

    test(
      'a receipt that could not be shelved is shelved on a later round',
      () async {
        final writing = on(mac);
        await writing.send(toInstall: phone.id, body: utf8Of('receipt later'));
        await writing.flush();
        final reading = on(phone);
        relay.refuseWrites = true;
        await reading.look();
        expect(reading.inbox.value.single.text, 'receipt later');
        expect(
          phone.of('receipt_tx').every((e) => e['deposited'] == false),
          isTrue,
          reason: 'tried, and tried again in the same round, in vain',
        );
        await writing.look();
        expect(writing.outbox.value.single.delivered, isFalse);

        relay.refuseWrites = false;
        await reading.look();
        expect(phone.of('receipt_tx').last['deposited'], isTrue);
        await writing.look();
        expect(writing.outbox.value.single.delivered, isTrue);
      },
    );

    test('nobody came for two days: the letter is shelved afresh and still '
        'arrives', () async {
      final writing = on(mac);
      await writing.send(toInstall: phone.id, body: utf8Of('patient'));
      await writing.flush();
      relay.expireEverything();
      mac.now = mac.now.add(const Duration(hours: 41));
      phone.now = mac.now;
      await writing.flush();
      expect(writing.outbox.value.single.attempts, 2);

      final reading = on(phone);
      await reading.look();
      expect(reading.inbox.value.single.text, 'patient');
      await writing.look();
      expect(writing.outbox.value.single.delivered, isTrue);
    });

    test(
      'a box the relay no longer has does not hold up the ones after it',
      () async {
        final writing = on(mac);
        await writing.send(toInstall: phone.id, body: utf8Of('lost'));
        await writing.flush();
        relay.objects.clear(); // The object is gone; its pointer is not.
        await writing.send(toInstall: phone.id, body: utf8Of('kept'));
        await writing.flush();
        final reading = on(phone);
        await reading.look();
        expect(reading.inbox.value.single.text, 'kept');
      },
    );
  });
}
