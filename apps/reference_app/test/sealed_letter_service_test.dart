// Sealed letters end to end, without a device: real Ed25519 / X25519 /
// ChaCha20-Poly1305, the real service, the real pair shelf and the real
// counted transport, against a relay on loopback that keeps the border
// relay's archive contract. Lab only: nothing here is a device result.
//
// Plain `test`, never `testWidgets`: the widget binding replaces HttpClient
// with one that answers 400 to everything.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/sealed/sealed_box.dart';
import 'package:reference_app/src/sealed/sealed_content.dart';
import 'package:reference_app/src/sealed/sealed_letter_service.dart';

import 'support/loopback_relay.dart';

void main() {
  late LoopbackRelay relay;
  late TestInstall mac;
  late TestInstall phone;
  final services = <SealedLetterService>[];

  SealedLetterService open(TestInstall install) {
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
    // The two have had a call: each pinned the other.
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

  group('the box', () {
    test('opens only for the pinned key it was sealed to, and names its '
        'sender inside', () async {
      final sealer = SealedBoxCodec(mac.identity);
      final id = sealer.newLetterId();
      final box = await sealer.seal(
        recipientInstall: phone.id,
        recipientKey: phone.key,
        kind: SealedKind.letter,
        letterId: id,
        createdAt: DateTime.utc(2026, 10, 5, 9, 30),
        body: utf8Of('to the phone'),
      );

      final opened = await SealedBoxCodec(phone.identity).open(box);
      expect(opened, isNotNull);
      expect(opened!.kind, SealedKind.letter);
      expect(opened.senderInstall, mac.id);
      expect(opened.senderKey, mac.key);
      expect(opened.letterId, id);
      expect(opened.createdAt, DateTime.utc(2026, 10, 5, 9, 30));
      expect(utf8.decode(opened.body), 'to the phone');

      // Not the sender, and not a third install.
      expect(await SealedBoxCodec(mac.identity).open(box), isNull);
      final third = TestInstall();
      await third.ready();
      expect(await SealedBoxCodec(third.identity).open(box), isNull);
    });

    test(
      'says nothing in the clear: no sender, no recipient, no text',
      () async {
        final box = await SealedBoxCodec(mac.identity).seal(
          recipientInstall: phone.id,
          recipientKey: phone.key,
          kind: SealedKind.letter,
          letterId: SealedBoxCodec(mac.identity).newLetterId(),
          createdAt: mac.now,
          body: utf8Of('a plain sentence nobody else may read'),
        );
        expect(containsBytes(box, utf8Of('a plain sentence')), isFalse);
        expect(containsBytes(box, mac.idBytes), isFalse);
        expect(containsBytes(box, mac.key), isFalse);
        expect(containsBytes(box, phone.idBytes), isFalse);
        expect(containsBytes(box, phone.key), isFalse);
      },
    );

    test('a receipt and a short letter are the same size', () async {
      final codec = SealedBoxCodec(mac.identity);
      Future<int> size(SealedKind kind, int bodyBytes) async =>
          (await codec.seal(
            recipientInstall: phone.id,
            recipientKey: phone.key,
            kind: kind,
            letterId: codec.newLetterId(),
            createdAt: mac.now,
            body: Uint8List(bodyBytes),
          )).length;

      final receipt = await size(SealedKind.receipt, 32);
      expect(await size(SealedKind.letter, 1), receipt);
      expect(await size(SealedKind.letter, 100), receipt);
      // And sizes move in whole buckets.
      final longer = await size(SealedKind.letter, 400);
      expect(longer, greaterThan(receipt));
      expect((longer - receipt) % sealedBucket, 0);
    });

    test('one changed byte anywhere and it does not open', () async {
      final codec = SealedBoxCodec(mac.identity);
      final box = await codec.seal(
        recipientInstall: phone.id,
        recipientKey: phone.key,
        kind: SealedKind.letter,
        letterId: codec.newLetterId(),
        createdAt: mac.now,
        body: utf8Of('intact'),
      );
      final opener = SealedBoxCodec(phone.identity);
      for (final at in [9, 20, 41, 60, box.length ~/ 2, box.length - 1]) {
        final damaged = Uint8List.fromList(box)..[at] ^= 0x01;
        expect(await opener.open(damaged), isNull, reason: 'byte $at');
      }
      expect(await opener.open(Uint8List(0)), isNull);
      expect(await opener.open(Uint8List.fromList(sealedMagic)), isNull);
    });

    test('a box sealed for another install id does not open here', () async {
      // Sealed to the phone's KEY but for a different install id: the id
      // is part of what the key is derived from.
      final codec = SealedBoxCodec(mac.identity);
      final box = await codec.seal(
        recipientInstall: 'aa' * 16,
        recipientKey: phone.key,
        kind: SealedKind.letter,
        letterId: codec.newLetterId(),
        createdAt: mac.now,
        body: utf8Of('misaddressed'),
      );
      expect(await SealedBoxCodec(phone.identity).open(box), isNull);
    });

    test('boxes handed over as one stream are cut back into boxes, and a '
        'stranger\'s bytes spoil nothing', () async {
      final codec = SealedBoxCodec(mac.identity);
      Future<Uint8List> box(String text) async => codec.seal(
        recipientInstall: phone.id,
        recipientKey: phone.key,
        kind: SealedKind.letter,
        letterId: codec.newLetterId(),
        createdAt: mac.now,
        body: utf8Of(text),
      );
      final one = await box('one');
      final two = await box('two');
      final three = await box('three');
      final stream = Uint8List.fromList([
        ...one,
        ...utf8Of('not a box at all'),
        ...two,
        ...sealedMagic, 0, 0, 9, 9, // a magic with a length that overruns
        ...three,
        ...one.sublist(0, 40), // a truncated tail
      ]);
      final cut = SealedBoxCodec.split(stream);
      final opener = SealedBoxCodec(phone.identity);
      final texts = <String>[];
      for (final piece in cut) {
        final opened = await opener.open(piece);
        if (opened != null) texts.add(utf8.decode(opened.body));
      }
      expect(texts, ['one', 'two', 'three']);
    });

    test('a body over the limit is refused', () async {
      final codec = SealedBoxCodec(mac.identity);
      expect(
        () async => codec.seal(
          recipientInstall: phone.id,
          recipientKey: phone.key,
          kind: SealedKind.letter,
          letterId: codec.newLetterId(),
          createdAt: mac.now,
          body: Uint8List(sealedMaxBody + 1),
        ),
        throwsArgumentError,
      );
    });
  });

  group('a letter, each way', () {
    test('Mac writes, the phone opens it, and the Mac learns it was '
        'opened', () async {
      final macService = open(mac);
      final phoneService = open(phone);

      final sent = await macService.send(
        toInstall: phone.id,
        body: utf8Of('from the Mac'),
      );
      await macService.flush();
      expect(sent.delivered, isFalse);
      expect(relay.pointers, hasLength(1));
      expect(macService.outbox.value.single.state, SealedSentState.shelved);
      expect(macService.relay.value, SealedRelayState.reachable);

      expect(await phoneService.look(), isTrue);
      final got = phoneService.inbox.value.single;
      expect(got.text, 'from the Mac');
      expect(got.from, mac.id);
      expect(got.id, sent.id);
      expect(got.verified, isFalse, reason: 'pinned, numbers not compared');

      // The receipt is waiting on the phone's shelf for the Mac.
      expect(await macService.look(), isTrue);
      final after = macService.outbox.value.single;
      expect(after.delivered, isTrue);
      expect(after.text, 'from the Mac');
      expect(macService.inbox.value, isEmpty, reason: 'a receipt is no letter');

      // The raw facts a rig run prints.
      final rx = phone.of('rx').single;
      expect(rx['from'], mac.id);
      expect(rx['to'], phone.id);
      expect(rx['bytes'], 'from the Mac'.length);
      expect(rx['opened'], isTrue);
      expect(mac.of('receipt_rx').single['id'], sent.id);

      // Opened: nothing more is ever sent for it.
      final puts = relay.puts;
      mac.now = mac.now.add(const Duration(hours: 60));
      await macService.flush();
      expect(relay.puts, puts);
    });

    test('the phone writes, the Mac opens it', () async {
      final macService = open(mac);
      final phoneService = open(phone);
      final sent = await phoneService.send(
        toInstall: mac.id,
        body: utf8Of('from the phone'),
      );
      await phoneService.flush();
      await macService.look();
      expect(macService.inbox.value.single.text, 'from the phone');
      expect(macService.inbox.value.single.from, phone.id);
      await phoneService.look();
      expect(phoneService.outbox.value.single.delivered, isTrue);
      expect(phoneService.outbox.value.single.id, sent.id);
    });

    test('a verified sender reads verified', () async {
      await phone.identity.markVerified(mac.id, mac.key);
      final macService = open(mac);
      final phoneService = open(phone);
      await macService.send(toInstall: phone.id, body: utf8Of('hi'));
      await macService.flush();
      await phoneService.look();
      expect(phoneService.inbox.value.single.verified, isTrue);
    });

    test('the relay only ever held boxes, and only on its shelf', () async {
      final macService = open(mac);
      final phoneService = open(phone);
      await macService.send(
        toInstall: phone.id,
        body: utf8Of('the relay must not read this'),
      );
      await macService.flush();
      await phoneService.look();
      await macService.look();

      expect(relay.objects, hasLength(2), reason: 'the letter, its receipt');
      for (final body in relay.objects.values) {
        expect(body.sublist(0, 5), sealedMagic);
        expect(containsBytes(body, utf8Of('the relay must not')), isFalse);
        expect(containsBytes(body, mac.idBytes), isFalse);
        expect(containsBytes(body, mac.key), isFalse);
        expect(containsBytes(body, phone.key), isFalse);
      }
      // A letter and its receipt are the same size on the wire.
      expect(relay.objects.values.map((b) => b.length).toSet(), hasLength(1));
      // No long-poll, no mailbox: every request named an object or a
      // pointer.
      expect(
        relay.requests.every((r) => RegExp(r'^(GET|PUT) /(o|a)/').hasMatch(r)),
        isTrue,
      );
    });
  });

  group('the letter waits until the relay can be reached', () {
    test(
      'relay out of reach: the letter stays queued, and goes when it is back',
      () async {
        final macService = open(mac);
        final phoneService = open(phone);
        relay.down = true;
        await macService.send(
          toInstall: phone.id,
          body: utf8Of('written while the relay was out of reach'),
        );
        await macService.flush();
        expect(macService.relay.value, SealedRelayState.unreachable);
        expect(macService.outbox.value.single.state, SealedSentState.waiting);
        expect(mac.of('tx').every((e) => e['deposited'] == false), isTrue);
        expect(await phoneService.look(), isFalse);

        // Still down a moment later: nothing is hammered before its pause.
        final attempts = macService.outbox.value.single.attempts;
        await macService.flush();
        expect(macService.outbox.value.single.attempts, attempts);

        relay.down = false;
        mac.now = mac.now.add(const Duration(minutes: 6));
        await macService.flush();
        expect(macService.relay.value, SealedRelayState.reachable);
        await phoneService.look();
        expect(
          phoneService.inbox.value.single.text,
          'written while the relay was out of reach',
        );
        await macService.look();
        expect(macService.outbox.value.single.delivered, isTrue);
      },
    );

    test('the queue outlives a relaunch', () async {
      relay.down = true;
      final first = open(mac);
      await first.send(toInstall: phone.id, body: utf8Of('kept'));
      await first.flush();
      await first.dispose();

      // Nothing on disk is in the clear.
      final onDisk = jsonEncode(mac.letters.data);
      expect(onDisk, isNot(contains('kept')));
      expect(onDisk, isNot(contains(base64.encode(utf8Of('kept')))));

      relay.down = false;
      mac.now = mac.now.add(const Duration(minutes: 6));
      final second = open(mac);
      await second.load();
      expect(second.outbox.value.single.text, 'kept');
      expect(second.outbox.value.single.delivered, isFalse);
      await second.flush();
      final phoneService = open(phone);
      await phoneService.look();
      expect(phoneService.inbox.value.single.text, 'kept');

      // And the phone's inbox outlives a relaunch too, still sealed.
      expect(jsonEncode(phone.letters.data), isNot(contains('kept')));
      final phoneAgain = open(phone);
      await phoneAgain.load();
      expect(phoneAgain.inbox.value.single.text, 'kept');
    });

    test('a letter that never reached the relay goes at once when the app '
        'is opened again, without waiting out its pause', () async {
      relay.down = true;
      final first = open(mac);
      await first.send(toInstall: phone.id, body: utf8Of('at once'));
      await first.flush();
      expect(first.outbox.value.single.attempts, 1);
      await first.dispose();

      // The clock has not moved: only being opened makes it due.
      relay.down = false;
      final second = open(mac);
      await second.flush();
      expect(second.outbox.value.single.onShelf, isFalse);
      await second.retryWaiting();
      await second.flush();
      expect(second.outbox.value.single.onShelf, isTrue);
    });
  });

  group('only a pinned key is a correspondent', () {
    test('no pinned key, no letter', () async {
      final stranger = TestInstall();
      await stranger.ready();
      expect(
        () async =>
            open(mac).send(toInstall: stranger.id, body: utf8Of('to nobody')),
        throwsA(isA<NotPinnedError>()),
      );
      expect(relay.requests, isEmpty);
    });

    test('a valid box from an install this one never pinned is not shown '
        'and not answered', () async {
      // The stranger knows the phone's key; the phone has never met it.
      // Its box reaches the shelf the phone reads only because the Mac —
      // who can write there — put it there.
      final stranger = TestInstall();
      await stranger.ready();
      final codec = SealedBoxCodec(stranger.identity);
      final box = await codec.seal(
        recipientInstall: phone.id,
        recipientKey: phone.key,
        kind: SealedKind.letter,
        letterId: codec.newLetterId(),
        createdAt: mac.now,
        body: const SealedContent.text('unsolicited').encode(),
      );
      expect(await mac.shelf(relay).put(phone.id, box), isTrue);
      final phoneService = open(phone);
      final puts = relay.puts;
      await phoneService.look();
      expect(phoneService.inbox.value, isEmpty);
      expect(phone.of('rejected').single['why'], 'sender_not_pinned');
      expect(relay.puts, puts, reason: 'no receipt went out');
    });

    test(
      'a box under a pinned install id but another key is refused',
      () async {
        // The Mac's public install id, a key of its own.
        final fake = TestInstall(
          pins: MemoryStorage()..data = {'install-id': mac.id},
        );
        await fake.ready();
        expect(fake.id, mac.id);
        final codec = SealedBoxCodec(fake.identity);
        final box = await codec.seal(
          recipientInstall: phone.id,
          recipientKey: phone.key,
          kind: SealedKind.letter,
          letterId: codec.newLetterId(),
          createdAt: mac.now,
          body: const SealedContent.text('I am the Mac, honest').encode(),
        );
        expect(await mac.shelf(relay).put(phone.id, box), isTrue);
        final phoneService = open(phone);
        await phoneService.look();
        expect(phoneService.inbox.value, isEmpty);
        expect(phone.of('rejected').single['why'], 'sender_key_changed');
      },
    );

    test('a forged receipt opens nothing', () async {
      final macService = open(mac);
      await macService.send(toInstall: phone.id, body: utf8Of('real'));
      await macService.flush();
      final id = macService.outbox.value.single.id;
      final phoneShelf = phone.shelf(relay);

      // A third install, pinned by nobody, seals a receipt for that
      // letter; it is on the shelf the Mac reads.
      final third = TestInstall();
      await third.ready();
      final forged = await SealedBoxCodec(third.identity).seal(
        recipientInstall: mac.id,
        recipientKey: mac.key,
        kind: SealedKind.receipt,
        letterId: id,
        createdAt: mac.now,
        body: Uint8List(32),
      );
      expect(await phoneShelf.put(mac.id, forged), isTrue);
      await macService.look();
      expect(macService.outbox.value.single.delivered, isFalse);
      expect(mac.of('rejected').single['why'], 'sender_not_pinned');

      // And a receipt from the real phone for the WRONG body proves
      // nothing either.
      final wrong = await SealedBoxCodec(phone.identity).seal(
        recipientInstall: mac.id,
        recipientKey: mac.key,
        kind: SealedKind.receipt,
        letterId: id,
        createdAt: mac.now,
        body: Uint8List(32),
      );
      expect(await phoneShelf.put(mac.id, wrong), isTrue);
      await macService.look();
      expect(macService.outbox.value.single.delivered, isFalse);
    });
  });

  group('what a letter says', () {
    test('a text and a described photo survive the round trip', () {
      final text = SealedContent.decode(
        const SealedContent.text('سلام — hello').encode(),
      );
      expect(text.text, 'سلام — hello');
      expect(text.media, isNull);
      expect(text.kindLabel, 'text');

      final sha = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final media = SealedContent.decode(
        SealedContent.media(
          SealedMedia(
            kind: SealedMediaKind.voice,
            contentType: 'audio/ogg',
            size: 100000,
            sha256: sha,
            chunks: 3,
            duration: const Duration(seconds: 30),
            caption: 'thirty seconds',
          ),
        ).encode(),
      ).media!;
      expect(media.kind, SealedMediaKind.voice);
      expect(media.contentType, 'audio/ogg');
      expect(media.size, 100000);
      expect(media.sha256, sha);
      expect(media.chunks, 3);
      expect(media.duration, const Duration(seconds: 30));
      expect(media.caption, 'thirty seconds');
    });

    test('a body from before letters had types is still a text', () {
      expect(
        SealedContent.decode(utf8Of('plain old text')).text,
        'plain old text',
      );
    });

    test('a description that lies about its pieces is not media', () {
      final lying = SealedContent.media(
        SealedMedia(
          kind: SealedMediaKind.photo,
          contentType: 'image/jpeg',
          size: 100000,
          sha256: Uint8List(32),
          chunks: 1, // 100 000 bytes cannot be one piece
        ),
      ).encode();
      expect(SealedContent.decode(lying).media, isNull);
    });
  });

  group('a photo, a voice note, a video', () {
    Uint8List bytesOf(int length, int seed) => Uint8List.fromList(
      List<int>.generate(length, (i) => (i * 31 + seed * 7 + (i >> 8)) & 0xff),
    );

    test(
      'cross whole, verified, and the receipt waits for the last piece',
      () async {
        final macService = open(mac);
        final phoneService = open(phone);
        final photo = bytesOf(130000, 1); // three pieces
        final sent = await macService.sendMedia(
          toInstall: phone.id,
          kind: SealedMediaKind.photo,
          contentType: 'image/jpeg',
          bytes: photo,
          caption: 'the harbour',
        );
        await macService.flush();
        expect(sent.content.media!.chunks, 3);
        expect(mac.of('tx').last['pieces_sent'], 3);
        expect(
          mac.blobs.blobs.keys.where((k) => k.startsWith('out.')),
          hasLength(3),
        );

        await phoneService.look();
        final got = phoneService.inbox.value.single;
        expect(got.content.media!.kind, SealedMediaKind.photo);
        expect(got.content.media!.caption, 'the harbour');
        expect(got.media, photo);
        expect(got.bytes, 130000);
        final rx = phone.of('rx').single;
        expect(rx['kind'], 'photo');
        expect(rx['bytes'], 130000);
        expect(rx['sent_at'], isNotNull);
        expect(rx['opened_at'], isNotNull);

        await macService.look();
        final after = macService.outbox.value.single;
        expect(after.state, SealedSentState.opened);
        expect(after.text, contains('photo'));
        expect(mac.of('receipt_rx').single['receipt_at'], isNotNull);
        // The pieces are not kept once the receipt is here.
        expect(
          mac.blobs.blobs.keys.where((k) => k.startsWith('out.')),
          isEmpty,
        );

        // The relay held boxes only, never the photo.
        for (final body in relay.objects.values) {
          expect(body.sublist(0, 5), sealedMagic);
          expect(containsBytes(body, photo.sublist(1000, 1040)), isFalse);
        }
      },
    );

    test(
      'one piece lost: only that piece is asked for and sent again',
      () async {
        final macService = open(mac);
        final phoneService = open(phone);
        final video = bytesOf(200000, 3); // five pieces
        await macService.sendMedia(
          toInstall: phone.id,
          kind: SealedMediaKind.video,
          contentType: 'video/mp4',
          bytes: video,
        );
        await macService.flush();
        // The relay lost one object: the letter, piece 0, [piece 1].
        relay.objects.remove(relay.objects.keys.elementAt(2));

        await phoneService.look();
        expect(phoneService.inbox.value, isEmpty, reason: 'not whole yet');
        expect(
          phone.of('receipt_tx'),
          isEmpty,
          reason: 'no receipt for a part',
        );
        expect(
          phone.of('need_tx'),
          isEmpty,
          reason: 'pieces may still be coming',
        );

        // Quiet for a while: the phone asks for exactly what it lacks.
        phone.now = phone.now.add(const Duration(seconds: 10));
        await phoneService.look();
        final need = phone.of('need_tx').single;
        expect(need['missing'], 1);
        expect(need['of'], 5);

        final puts = relay.puts;
        await macService.look();
        expect(mac.of('need_rx').single['pieces_sent'], 1);
        expect(
          relay.puts,
          puts + 2,
          reason: 'one piece — its box and its pointer — not five',
        );

        await phoneService.look();
        expect(phoneService.inbox.value.single.media, video);
        await macService.look();
        expect(macService.outbox.value.single.delivered, isTrue);
      },
    );

    test(
      'half a letter survives a relaunch and is finished after it',
      () async {
        final macService = open(mac);
        final photo = bytesOf(100000, 4); // three pieces
        await macService.sendMedia(
          toInstall: phone.id,
          kind: SealedMediaKind.photo,
          contentType: 'image/jpeg',
          bytes: photo,
        );
        await macService.flush();
        // The relay lost the last piece.
        relay.objects.remove(relay.objects.keys.elementAt(3));
        final first = open(phone);
        await first.look();
        expect(first.inbox.value, isEmpty);
        await first.dispose();

        // Nothing the phone kept is in the clear.
        expect(jsonEncode(phone.letters.data), isNot(contains('image/jpeg')));
        for (final blob in phone.blobs.blobs.values) {
          expect(blob.sublist(0, 5), sealedMagic);
          expect(containsBytes(blob, photo.sublist(500, 540)), isFalse);
        }

        phone.now = phone.now.add(const Duration(seconds: 10));
        final second = open(phone);
        await second.look();
        expect(phone.of('need_tx').single['missing'], 1);
        await macService.look();
        await second.look();
        expect(second.inbox.value.single.media, photo);

        // And the finished letter opens again after another relaunch.
        final third = open(phone);
        await third.load();
        expect(third.inbox.value.single.media, photo);
      },
    );

    test(
      'nothing, and too much, are refused before anything is queued',
      () async {
        final macService = open(mac);
        for (final bad in [Uint8List(0), Uint8List(sealedMaxMediaBytes + 1)]) {
          expect(
            () async => macService.sendMedia(
              toInstall: phone.id,
              kind: SealedMediaKind.file,
              contentType: 'application/octet-stream',
              bytes: bad,
            ),
            throwsArgumentError,
          );
        }
        expect(macService.outbox.value, isEmpty);
      },
    );
  });

  group('where a letter is, in words', () {
    test(
      'in the queue, then on the relay, then opened — never "sending"',
      () async {
        final macService = open(mac);
        final phoneService = open(phone);
        relay.down = true;
        await macService.send(toInstall: phone.id, body: utf8Of('where'));
        await macService.flush();
        var letter = macService.outbox.value.single;
        expect(letter.state, SealedSentState.waiting);
        expect(letter.describe(mac.now), contains('in queue'));
        expect(letter.describe(mac.now), contains('relay unreachable'));
        expect(letter.describe(mac.now), contains('again in'));

        relay.down = false;
        mac.now = mac.now.add(const Duration(seconds: 6));
        await macService.flush();
        letter = macService.outbox.value.single;
        expect(letter.state, SealedSentState.shelved);
        expect(letter.describe(mac.now), contains('on the relay'));
        expect(letter.describe(mac.now), contains('about two days'));

        await phoneService.look();
        await macService.look();
        letter = macService.outbox.value.single;
        expect(letter.state, SealedSentState.opened);
        expect(letter.describe(mac.now), 'opened by them');
      },
    );
  });
}
