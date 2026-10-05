// Sealed letters end to end, without a device: real Ed25519 / X25519 /
// ChaCha20-Poly1305, the real long-poll lane, and a relay on loopback that
// keeps the border relay's contract (POST to one side queues for the other,
// GET takes the queue, frames concatenated with nothing between them).
// Lab only: nothing here is a device result.
//
// Plain `test`, never `testWidgets`: the widget binding replaces HttpClient
// with one that answers 400 to everything.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart'
    show HttpLongPollLane;
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/intelligence/disk_json_storage.dart';
import 'package:reference_app/src/peer_identity.dart';
import 'package:reference_app/src/sealed/mailbox_door.dart';
import 'package:reference_app/src/sealed/sealed_box.dart';
import 'package:reference_app/src/sealed/sealed_letters.dart';
import 'package:security/security.dart';

class _MemoryStorage implements PersistentStorage {
  Map<String, Object?> data = {};

  @override
  Future<Map<String, Object?>> load() async =>
      jsonDecode(jsonEncode(data)) as Map<String, Object?>;

  @override
  Future<void> save(Map<String, Object?> data) async {
    this.data = jsonDecode(jsonEncode(data)) as Map<String, Object?>;
  }
}

/// The border relay's long-poll route, on loopback.
class _Relay {
  _Relay._(this._server);

  static Future<_Relay> start() async {
    final relay = _Relay._(await HttpServer.bind('127.0.0.1', 0));
    relay._server.listen(relay._serve);
    return relay;
  }

  final HttpServer _server;
  final Map<String, List<Uint8List>> _held = {};

  /// Every body the relay was ever handed: what an operator could keep.
  final List<Uint8List> seen = [];

  /// Answer 503 to everything: the door is down.
  bool down = false;

  /// Accept this many more POSTs and then lose them (a session that
  /// expired before the recipient came).
  int loseNext = 0;

  int posts = 0;

  Uri uriFor(String install, String role) => Uri.parse(
    'http://127.0.0.1:${_server.port}/http?session=$install&role=$role',
  );

  MailboxDoor door() => RelayMailboxDoor(
    uriFor: uriFor,
    requestTimeout: const Duration(seconds: 2),
  );

  int waiting(String install) => (_held['$install:b'] ?? const []).length;

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final session = request.uri.queryParameters['session'];
    final role = request.uri.queryParameters['role'];
    if (down) {
      await request.drain<void>();
      response.statusCode = 503;
    } else if (request.uri.path != '/http' || session == null || role == null) {
      await request.drain<void>();
      response.statusCode = 400;
    } else if (request.method == 'POST') {
      final body = BytesBuilder();
      await for (final chunk in request) {
        body.add(chunk);
      }
      final bytes = body.takeBytes();
      posts++;
      seen.add(bytes);
      if (loseNext > 0) {
        loseNext--;
      } else {
        final other = role == 'a' ? 'b' : 'a';
        (_held['$session:$other'] ??= []).add(bytes);
      }
      response.statusCode = 204;
    } else if (request.method == 'GET') {
      await request.drain<void>();
      final frames = _held.remove('$session:$role') ?? const <Uint8List>[];
      if (frames.isEmpty) {
        response.statusCode = 204;
      } else {
        response.statusCode = 200;
        for (final frame in frames) {
          response.add(frame);
        }
      }
    } else {
      await request.drain<void>();
      response.statusCode = 405;
    }
    await response.close();
  }

  Future<void> stop() => _server.close(force: true);
}

/// One install: its own keystore, pin file, letter file and clock.
class _Install {
  _Install(this.name) : identity = _identity();

  static AppIdentity _identity() => AppIdentity(
    engine: CryptographyIdentityKeyEngine(keyStore: InMemoryKeyStore()),
    pins: PinnedPeerStore(_MemoryStorage()),
  );

  final String name;
  final AppIdentity identity;
  final _MemoryStorage letters = _MemoryStorage();
  final List<(String, Map<String, Object?>)> events = [];
  DateTime now = DateTime.utc(2026, 10, 5, 12);

  Future<String> id() async => _hex(await identity.installId());
  Future<Uint8List> key() async =>
      (await identity.store.localIdentity()).publicKey;

  /// What a call's identity exchange leaves behind: [other]'s key pinned.
  Future<void> pin(_Install other) => identity.store.checkRemoteIdentity(
    peerId: _hexSync(other._idBytes!),
    presentedPublicKey: other._keyBytes!,
  );

  Uint8List? _idBytes;
  Uint8List? _keyBytes;
  Future<void> ready() async {
    _idBytes = await identity.installId();
    _keyBytes = await key();
  }

  /// A fresh service over the same files — what a relaunch is.
  SealedLetterService service(_Relay relay) => SealedLetterService(
    identity: identity,
    door: relay.door(),
    storage: letters,
    clock: () => now,
    onEvent: (event, fields) => events.add((event, fields)),
  );

  Iterable<Map<String, Object?>> of(String event) =>
      events.where((e) => e.$1 == event).map((e) => e.$2);
}

String _hex(List<int> bytes) => _hexSync(bytes);
String _hexSync(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _utf8(String text) => Uint8List.fromList(utf8.encode(text));

bool _contains(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

void main() {
  late _Relay relay;
  late _Install mac;
  late _Install phone;
  final services = <SealedLetterService>[];

  SealedLetterService open(_Install install) {
    final service = install.service(relay);
    services.add(service);
    return service;
  }

  setUp(() async {
    relay = await _Relay.start();
    mac = _Install('mac');
    phone = _Install('phone');
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
        recipientInstall: await phone.id(),
        recipientKey: await phone.key(),
        kind: SealedKind.letter,
        letterId: id,
        createdAt: DateTime.utc(2026, 10, 5, 9, 30),
        body: _utf8('to the phone'),
      );

      final opened = await SealedBoxCodec(phone.identity).open(box);
      expect(opened, isNotNull);
      expect(opened!.kind, SealedKind.letter);
      expect(opened.senderInstall, await mac.id());
      expect(opened.senderKey, await mac.key());
      expect(opened.letterId, id);
      expect(opened.createdAt, DateTime.utc(2026, 10, 5, 9, 30));
      expect(utf8.decode(opened.body), 'to the phone');

      // Not the sender, and not a third install.
      expect(await SealedBoxCodec(mac.identity).open(box), isNull);
      final third = _Install('third');
      await third.ready();
      expect(await SealedBoxCodec(third.identity).open(box), isNull);
    });

    test(
      'says nothing in the clear: no sender, no recipient, no text',
      () async {
        final box = await SealedBoxCodec(mac.identity).seal(
          recipientInstall: await phone.id(),
          recipientKey: await phone.key(),
          kind: SealedKind.letter,
          letterId: SealedBoxCodec(mac.identity).newLetterId(),
          createdAt: mac.now,
          body: _utf8('a plain sentence nobody else may read'),
        );
        expect(_contains(box, _utf8('a plain sentence')), isFalse);
        expect(_contains(box, mac._idBytes!), isFalse);
        expect(_contains(box, mac._keyBytes!), isFalse);
        expect(_contains(box, phone._idBytes!), isFalse);
        expect(_contains(box, phone._keyBytes!), isFalse);
      },
    );

    test('a receipt and a short letter are the same size', () async {
      final codec = SealedBoxCodec(mac.identity);
      Future<int> size(SealedKind kind, int bodyBytes) async =>
          (await codec.seal(
            recipientInstall: await phone.id(),
            recipientKey: await phone.key(),
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
        recipientInstall: await phone.id(),
        recipientKey: await phone.key(),
        kind: SealedKind.letter,
        letterId: codec.newLetterId(),
        createdAt: mac.now,
        body: _utf8('intact'),
      );
      final opener = SealedBoxCodec(phone.identity);
      for (final at in [9, 20, 41, 60, box.length ~/ 2, box.length - 1]) {
        final damaged = Uint8List.fromList(box)..[at] ^= 0x01;
        expect(await opener.open(damaged), isNull, reason: 'byte $at');
      }
      expect(await opener.open(Uint8List(0)), isNull);
      expect(await opener.open(Uint8List.fromList(sealedMagic)), isNull);
    });

    test('a box moved to another mailbox does not open there', () async {
      // Sealed to the phone's KEY but for a different install id: the id
      // is part of what the key is derived from.
      final codec = SealedBoxCodec(mac.identity);
      final box = await codec.seal(
        recipientInstall: 'aa' * 16,
        recipientKey: await phone.key(),
        kind: SealedKind.letter,
        letterId: codec.newLetterId(),
        createdAt: mac.now,
        body: _utf8('misaddressed'),
      );
      expect(await SealedBoxCodec(phone.identity).open(box), isNull);
    });

    test('a mailbox handed over as one stream is cut back into boxes, and '
        'a stranger\'s bytes spoil nothing', () async {
      final codec = SealedBoxCodec(mac.identity);
      Future<Uint8List> box(String text) async => codec.seal(
        recipientInstall: await phone.id(),
        recipientKey: await phone.key(),
        kind: SealedKind.letter,
        letterId: codec.newLetterId(),
        createdAt: mac.now,
        body: _utf8(text),
      );
      final one = await box('one');
      final two = await box('two');
      final three = await box('three');
      final stream = Uint8List.fromList([
        ...one,
        ..._utf8('not a box at all'),
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
          recipientInstall: await phone.id(),
          recipientKey: await phone.key(),
          kind: SealedKind.letter,
          letterId: codec.newLetterId(),
          createdAt: mac.now,
          body: Uint8List(sealedMaxBody + 1),
        ),
        throwsArgumentError,
      );
    });
  });

  group('the long-poll lane reads as well as writes', () {
    test('what one side posted is what the other side receives', () async {
      final a = HttpLongPollLane(sendUri: relay.uriFor('room', 'a'));
      final b = HttpLongPollLane(sendUri: relay.uriFor('room', 'b'));
      addTearDown(a.dispose);
      addTearDown(b.dispose);

      expect(await b.receive(), isEmpty, reason: 'nothing waiting');
      await a.send([1, 2, 3]);
      await a.send([4, 5]);
      expect(await b.receive(), [1, 2, 3, 4, 5]);
      expect(await b.receive(), isEmpty, reason: 'taken once');

      relay.down = true;
      expect(await b.receive(), isNull, reason: 'the door is down');
    });
  });

  group('a letter, each way', () {
    test('Mac writes, the phone opens it, and the Mac learns it was '
        'opened', () async {
      final macService = open(mac);
      final phoneService = open(phone);

      final sent = await macService.send(
        toInstall: await phone.id(),
        body: _utf8('from the Mac'),
      );
      await macService.flush();
      expect(sent.delivered, isFalse);
      expect(relay.waiting(await phone.id()), greaterThan(0));

      expect(await phoneService.pollOnce(), isTrue);
      final got = phoneService.inbox.value.single;
      expect(got.text, 'from the Mac');
      expect(got.from, await mac.id());
      expect(got.id, sent.id);
      expect(got.verified, isFalse, reason: 'pinned, numbers not compared');

      // The receipt is waiting in the Mac's own mailbox.
      expect(await macService.pollOnce(), isTrue);
      final after = macService.outbox.value.single;
      expect(after.delivered, isTrue);
      expect(after.text, 'from the Mac');
      expect(macService.inbox.value, isEmpty, reason: 'a receipt is no letter');

      // The raw facts a rig run prints.
      final rx = phone.of('rx').single;
      expect(rx['from'], await mac.id());
      expect(rx['to'], await phone.id());
      expect(rx['bytes'], 'from the Mac'.length);
      expect(rx['opened'], isTrue);
      expect(mac.of('receipt_rx').single['id'], sent.id);
    });

    test('the phone writes, the Mac opens it', () async {
      final macService = open(mac);
      final phoneService = open(phone);
      final sent = await phoneService.send(
        toInstall: await mac.id(),
        body: _utf8('from the phone'),
      );
      await phoneService.flush();
      await macService.pollOnce();
      expect(macService.inbox.value.single.text, 'from the phone');
      expect(macService.inbox.value.single.from, await phone.id());
      await phoneService.pollOnce();
      expect(phoneService.outbox.value.single.delivered, isTrue);
      expect(phoneService.outbox.value.single.id, sent.id);
    });

    test('a verified sender reads verified', () async {
      await phone.identity.markVerified(await mac.id(), await mac.key());
      final macService = open(mac);
      final phoneService = open(phone);
      await macService.send(toInstall: await phone.id(), body: _utf8('hi'));
      await macService.flush();
      await phoneService.pollOnce();
      expect(phoneService.inbox.value.single.verified, isTrue);
    });

    test('the relay only ever held boxes', () async {
      final macService = open(mac);
      final phoneService = open(phone);
      await macService.send(
        toInstall: await phone.id(),
        body: _utf8('the relay must not read this'),
      );
      await macService.flush();
      await phoneService.pollOnce();
      await macService.pollOnce();

      expect(relay.seen, isNotEmpty);
      for (final body in relay.seen) {
        expect(body.sublist(0, 5), sealedMagic);
        expect(_contains(body, _utf8('the relay must not')), isFalse);
        expect(_contains(body, mac._idBytes!), isFalse);
        expect(_contains(body, mac._keyBytes!), isFalse);
        expect(_contains(body, phone._keyBytes!), isFalse);
      }
      // A letter and its receipt are the same size on the wire.
      expect(relay.seen.map((b) => b.length).toSet(), hasLength(1));
    });
  });

  group('the letter waits until the path is up', () {
    test(
      'door down: the letter stays queued, and goes when it is back',
      () async {
        final macService = open(mac);
        final phoneService = open(phone);
        relay.down = true;
        await macService.send(
          toInstall: await phone.id(),
          body: _utf8('written while the door was down'),
        );
        await macService.flush();
        expect(macService.doorUp.value, isFalse);
        expect(macService.outbox.value.single.delivered, isFalse);
        expect(mac.of('tx').every((e) => e['deposited'] == false), isTrue);
        expect(await phoneService.pollOnce(), isFalse);

        // Still down a moment later: nothing is hammered before its pause.
        final attempts = macService.outbox.value.single.attempts;
        await macService.flush();
        expect(macService.outbox.value.single.attempts, attempts);

        relay.down = false;
        mac.now = mac.now.add(const Duration(minutes: 6));
        await macService.flush();
        expect(macService.doorUp.value, isTrue);
        await phoneService.pollOnce();
        expect(
          phoneService.inbox.value.single.text,
          'written while the door was down',
        );
        await macService.pollOnce();
        expect(macService.outbox.value.single.delivered, isTrue);
      },
    );

    test('the queue outlives a relaunch', () async {
      relay.down = true;
      final first = open(mac);
      await first.send(toInstall: await phone.id(), body: _utf8('kept'));
      await first.flush();
      await first.dispose();

      // Nothing on disk is in the clear.
      final onDisk = jsonEncode(mac.letters.data);
      expect(onDisk, isNot(contains('kept')));
      expect(onDisk, isNot(contains(base64.encode(_utf8('kept')))));

      relay.down = false;
      mac.now = mac.now.add(const Duration(minutes: 6));
      final second = open(mac);
      await second.load();
      expect(second.outbox.value.single.text, 'kept');
      expect(second.outbox.value.single.delivered, isFalse);
      await second.flush();
      final phoneService = open(phone);
      await phoneService.pollOnce();
      expect(phoneService.inbox.value.single.text, 'kept');

      // And the phone's inbox outlives a relaunch too, still sealed.
      expect(jsonEncode(phone.letters.data), isNot(contains('kept')));
      final phoneAgain = open(phone);
      await phoneAgain.load();
      expect(phoneAgain.inbox.value.single.text, 'kept');
    });

    test('the relay lost the box: it is put in again, shown once, and '
        'answered every time', () async {
      final macService = open(mac);
      final phoneService = open(phone);
      relay.loseNext = 1;
      await macService.send(toInstall: await phone.id(), body: _utf8('once'));
      await macService.flush();
      await phoneService.pollOnce();
      expect(phoneService.inbox.value, isEmpty, reason: 'the relay lost it');

      mac.now = mac.now.add(const Duration(seconds: 6));
      await macService.flush();
      await phoneService.pollOnce();
      expect(phoneService.inbox.value.single.text, 'once');

      // The receipt is lost too: the Mac asks again, the phone answers
      // again and still shows one letter.
      relay._held.clear();
      mac.now = mac.now.add(const Duration(seconds: 30));
      await macService.flush();
      await phoneService.pollOnce();
      expect(phoneService.inbox.value, hasLength(1));
      expect(phone.of('receipt_tx'), hasLength(2));
      expect(phone.of('receipt_tx').last['duplicate'], isTrue);
      await macService.pollOnce();
      expect(macService.outbox.value.single.delivered, isTrue);

      // Delivered: nothing more is ever sent for it.
      final posts = relay.posts;
      mac.now = mac.now.add(const Duration(hours: 1));
      await macService.flush();
      expect(relay.posts, posts);
    });
  });

  group('only a pinned key is a correspondent', () {
    test('no pinned key, no letter', () async {
      final stranger = _Install('stranger');
      await stranger.ready();
      expect(
        () async => open(
          mac,
        ).send(toInstall: await stranger.id(), body: _utf8('to nobody')),
        throwsA(isA<NotPinnedError>()),
      );
      expect(relay.posts, 0);
    });

    test('a valid box from an install this one never pinned is not shown '
        'and not answered', () async {
      final stranger = _Install('stranger');
      await stranger.ready();
      // The stranger knows the phone's key; the phone has never met it.
      await stranger.pin(phone);
      final strangerService = open(stranger);
      final phoneService = open(phone);
      await strangerService.send(
        toInstall: await phone.id(),
        body: _utf8('unsolicited'),
      );
      await strangerService.flush();
      final posts = relay.posts;
      await phoneService.pollOnce();
      expect(phoneService.inbox.value, isEmpty);
      expect(phone.of('rejected').single['why'], 'sender_not_pinned');
      expect(relay.posts, posts, reason: 'no receipt went out');
    });

    test(
      'a box under a pinned install id but another key is refused',
      () async {
        // The Mac's public install id, a key of its own.
        final impostor = _Install('impostor');
        (impostor.identity.store, impostor.letters);
        final pins = _MemoryStorage()..data = {'install-id': await mac.id()};
        final fake = AppIdentity(
          engine: CryptographyIdentityKeyEngine(keyStore: InMemoryKeyStore()),
          pins: PinnedPeerStore(pins),
        );
        expect(_hex(await fake.installId()), await mac.id());
        await fake.store.checkRemoteIdentity(
          peerId: await phone.id(),
          presentedPublicKey: await phone.key(),
        );
        final fakeService = SealedLetterService(
          identity: fake,
          door: relay.door(),
          storage: _MemoryStorage(),
        );
        services.add(fakeService);
        final phoneService = open(phone);
        await fakeService.send(
          toInstall: await phone.id(),
          body: _utf8('I am the Mac, honest'),
        );
        await fakeService.flush();
        await phoneService.pollOnce();
        expect(phoneService.inbox.value, isEmpty);
        expect(phone.of('rejected').single['why'], 'sender_key_changed');
      },
    );

    test('a forged receipt opens nothing', () async {
      final macService = open(mac);
      await macService.send(toInstall: await phone.id(), body: _utf8('real'));
      await macService.flush();
      final id = macService.outbox.value.single.id;

      // A third install, pinned by nobody, puts a receipt for that letter
      // in the Mac's mailbox.
      final third = _Install('third');
      await third.ready();
      final forged = await SealedBoxCodec(third.identity).seal(
        recipientInstall: await mac.id(),
        recipientKey: await mac.key(),
        kind: SealedKind.receipt,
        letterId: id,
        createdAt: mac.now,
        body: Uint8List(32),
      );
      await relay.door().deposit(await mac.id(), forged);
      await macService.pollOnce();
      expect(macService.outbox.value.single.delivered, isFalse);

      // And a receipt from the real phone for the WRONG body proves
      // nothing either.
      final wrong = await SealedBoxCodec(phone.identity).seal(
        recipientInstall: await mac.id(),
        recipientKey: await mac.key(),
        kind: SealedKind.receipt,
        letterId: id,
        createdAt: mac.now,
        body: Uint8List(32),
      );
      await relay.door().deposit(await mac.id(), wrong);
      await macService.pollOnce();
      expect(macService.outbox.value.single.delivered, isFalse);
    });
  });
}
