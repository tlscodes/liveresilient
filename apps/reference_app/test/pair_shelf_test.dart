// The pair shelf, without a device: real crypto, the real service, the real
// HTTP transport, and a relay on loopback that keeps the border relay's
// archive contract — `/o/<hash>` must hash to its name, `/a/<author>/<seq>`
// must prove its author with the same three-link check the worker runs,
// both are write-once — and whose mailbox keeps NOTHING for a side that is
// not reading, which is what the real one was measured to do after seconds.
// Lab only: nothing here is a device result.
//
// Plain `test`, never `testWidgets`: the widget binding replaces HttpClient.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/broadcast_wiring.dart'
    show IoBroadcastHttpTransport;
import 'package:reference_app/src/intelligence/disk_json_storage.dart';
import 'package:reference_app/src/peer_identity.dart';
import 'package:reference_app/src/sealed/mailbox_door.dart';
import 'package:reference_app/src/sealed/pair_shelf.dart';
import 'package:reference_app/src/sealed/sealed_blob_store.dart';
import 'package:reference_app/src/sealed/sealed_box.dart';
import 'package:reference_app/src/sealed/sealed_content.dart';
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

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// The border relay on loopback: the archive as the worker implements it,
/// and a mailbox that forgets at once.
class _Relay {
  _Relay._(this._server);

  static Future<_Relay> start() async {
    final relay = _Relay._(await HttpServer.bind('127.0.0.1', 0));
    relay._server.listen(relay._serve);
    return relay;
  }

  final HttpServer _server;
  final Map<String, Uint8List> objects = {};
  final Map<String, Uint8List> pointers = {};

  /// Answer 503 to everything.
  bool down = false;

  /// Reads work, writes are refused: the relay is reachable but full.
  bool refuseWrites = false;
  int rings = 0;
  int refusedPointerWrites = 0;

  Uri get origin => Uri.parse('http://127.0.0.1:${_server.port}');

  Uri mailbox(String install, String role) => Uri.parse(
    'http://127.0.0.1:${_server.port}/http?session=$install&role=$role',
  );

  /// The relay's two days are up.
  void expireEverything() {
    objects.clear();
    pointers.clear();
  }

  Future<Uint8List> _body(HttpRequest request) async {
    final body = BytesBuilder();
    await for (final chunk in request) {
      body.add(chunk);
    }
    return body.takeBytes();
  }

  Future<String> _sha(List<int> bytes) async =>
      _hex((await Sha256().hash(bytes)).bytes);

  Future<bool> _signed(List<int> key, List<int> message, List<int> sig) =>
      Ed25519().verify(
        message,
        signature: Signature(
          sig,
          publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
        ),
      );

  /// The worker's `authorizeDescriptorWrite`, link for link.
  Future<bool> _authorised(
    String author,
    Uint8List pointer,
    String? header,
  ) async {
    if (header == null) return false;
    final Uint8List credentials;
    try {
      credentials = base64Url.decode(base64Url.normalize(header));
    } on FormatException {
      return false;
    }
    if (credentials.length != 32 + 125) return false;
    final root = credentials.sublist(0, 32);
    final certificate = credentials.sublist(32);
    if ((await _sha(root)).substring(0, 32) != author) return false;
    if (_hex(certificate.sublist(1, 17)) != author) return false;
    if (!await _signed(root, [
      ...utf8.encode('vck/broadcast/publishing-key/v1\n'),
      ...certificate.sublist(0, 125 - 64),
    ], certificate.sublist(125 - 64))) {
      return false;
    }
    if (pointer.length < 2 + 16 + 64) return false;
    if (_hex(pointer.sublist(2, 18)) != author) return false;
    return _signed(certificate.sublist(17, 49), [
      ...utf8.encode('vck/broadcast/descriptor/v1\n'),
      ...pointer.sublist(0, pointer.length - 64),
    ], pointer.sublist(pointer.length - 64));
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final path = request.uri.path;
    final write = request.method == 'PUT' || request.method == 'POST';
    final body = write ? await _body(request) : Uint8List(0);
    if (!write) await request.drain<void>();
    if (down || (write && refuseWrites)) {
      response.statusCode = 503;
    } else if (path == '/http') {
      // The mailbox: accepts, keeps nothing — nobody is ever reading here.
      if (write) rings++;
      response.statusCode = 204;
    } else if (path.startsWith('/o/')) {
      final hash = path.substring(3);
      if (!write) {
        final held = objects[hash];
        response.statusCode = held == null ? 404 : 200;
        if (held != null) response.add(held);
      } else if (body.isEmpty) {
        response.statusCode = 400;
      } else if (body.length > 100000) {
        response.statusCode = 413;
      } else if (await _sha(body) != hash) {
        response.statusCode = 400;
      } else {
        response.statusCode = objects.containsKey(hash) ? 204 : 201;
        objects[hash] = body;
      }
    } else if (path.startsWith('/a/')) {
      final key = path.substring(3);
      final author = key.split('/').first;
      if (!write) {
        final held = pointers[key];
        response.statusCode = held == null ? 404 : 200;
        if (held != null) response.add(held);
      } else if (body.isEmpty || body.length > 512) {
        response.statusCode = body.isEmpty ? 400 : 413;
      } else if (!await _authorised(
        author,
        body,
        request.headers.value('x-broadcast-auth'),
      )) {
        refusedPointerWrites++;
        response.statusCode = 403;
      } else {
        final held = pointers[key];
        if (held == null) {
          pointers[key] = body;
          response.statusCode = 201;
        } else {
          response.statusCode = _hex(held) == _hex(body) ? 204 : 409;
        }
      }
    } else {
      response.statusCode = 404;
    }
    await response.close();
  }

  Future<void> stop() => _server.close(force: true);
}

/// One install: its own keystore, pins, letter file, pieces and clock.
class _Install {
  _Install()
    : identity = AppIdentity(
        engine: CryptographyIdentityKeyEngine(keyStore: InMemoryKeyStore()),
        pins: PinnedPeerStore(_MemoryStorage()),
      );

  final AppIdentity identity;
  final _MemoryStorage letters = _MemoryStorage();
  final MemorySealedBlobStore blobs = MemorySealedBlobStore();
  final List<(String, Map<String, Object?>)> events = [];
  DateTime now = DateTime.utc(2026, 10, 5, 12);
  late final String id;
  late final Uint8List key;

  Future<void> ready() async {
    id = _hex(await identity.installId());
    key = (await identity.store.localIdentity()).publicKey;
  }

  Future<void> pin(_Install other) => identity.store.checkRemoteIdentity(
    peerId: other.id,
    presentedPublicKey: other.key,
  );

  PairShelf shelf(_Relay relay) => PairShelf(
    identity: identity,
    origin: relay.origin,
    transport: IoBroadcastHttpTransport(),
    clock: () => now,
  );

  /// A fresh service over the same files — what switching the app on is.
  SealedLetterService service(_Relay relay) => SealedLetterService(
    identity: identity,
    door: RelayMailboxDoor(
      uriFor: relay.mailbox,
      requestTimeout: const Duration(seconds: 2),
    ),
    storage: letters,
    blobs: blobs,
    shelf: shelf(relay),
    clock: () => now,
    onEvent: (event, fields) => events.add((event, fields)),
  );

  Iterable<Map<String, Object?>> of(String event) =>
      events.where((e) => e.$1 == event).map((e) => e.$2);
}

Uint8List _utf8(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  late _Relay relay;
  late _Install mac;
  late _Install phone;
  final services = <SealedLetterService>[];

  SealedLetterService on(_Install install) {
    final service = install.service(relay);
    services.add(service);
    return service;
  }

  setUp(() async {
    relay = await _Relay.start();
    mac = _Install();
    phone = _Install();
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

  group('a letter waits on the shelf', () {
    test('the Mac writes and is switched off; the phone comes on later and '
        'opens it; the Mac learns of it the next time IT comes on', () async {
      final photo = Uint8List.fromList(
        List<int>.generate(130000, (i) => (i * 31 + (i >> 9)) & 0xff),
      );
      final writing = on(mac);
      await writing.send(
        toInstall: phone.id,
        body: _utf8('while you were away'),
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
      expect(await reading.pollOnce(), isTrue);
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
      expect(await back.pollOnce(), isTrue);
      expect(back.outbox.value.every((s) => s.delivered), isTrue);
      expect(back.outbox.value.first.describe(mac.now), 'opened by them');
    });

    test('the mailbox kept nothing; only the shelf carried it', () async {
      final writing = on(mac);
      await writing.send(toInstall: phone.id, body: _utf8('shelf only'));
      await writing.flush();
      expect(relay.rings, greaterThan(0), reason: 'the doorbell was rung');
      await writing.dispose();
      final reading = on(phone);
      await reading.pollOnce();
      expect(reading.inbox.value.single.text, 'shelf only');
    });

    test(
      'what is on the relay is sealed boxes and pointers, nothing else',
      () async {
        final writing = on(mac);
        await writing.send(
          toInstall: phone.id,
          body: _utf8('nobody else may read this'),
        );
        await writing.flush();
        expect(relay.objects, isNotEmpty);
        for (final entry in relay.objects.entries) {
          expect(entry.value.sublist(0, 5), sealedMagic);
          expect(
            utf8.decode(entry.value, allowMalformed: true),
            isNot(contains('nobody else')),
          );
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
        await writing.send(toInstall: phone.id, body: _utf8('once'));
        await writing.flush();
        final first = on(phone);
        await first.pollOnce();
        await first.pollOnce();
        expect(first.inbox.value, hasLength(1));
        expect(phone.of('rx'), hasLength(1));
        expect(phone.of('receipt_tx'), hasLength(1));
        await first.dispose();

        final again = on(phone);
        await again.pollOnce();
        expect(again.inbox.value, hasLength(1));
        expect(phone.of('rx'), hasLength(1), reason: 'the cursor was kept');
        expect(phone.of('receipt_tx'), hasLength(1));
      },
    );

    test(
      'both directions at once, each side off when the other writes',
      () async {
        final macWrites = on(mac);
        await macWrites.send(toInstall: phone.id, body: _utf8('from the Mac'));
        await macWrites.flush();
        await macWrites.dispose();
        final phoneWrites = on(phone);
        await phoneWrites.send(
          toInstall: mac.id,
          body: _utf8('from the phone'),
        );
        await phoneWrites.flush();
        await phoneWrites.pollOnce();
        expect(phoneWrites.inbox.value.single.text, 'from the Mac');
        await phoneWrites.dispose();

        final macBack = on(mac);
        await macBack.pollOnce();
        expect(macBack.inbox.value.single.text, 'from the phone');
        expect(macBack.outbox.value.single.delivered, isTrue);
        await macBack.dispose();

        final phoneBack = on(phone);
        await phoneBack.pollOnce();
        expect(phoneBack.outbox.value.single.delivered, isTrue);
      },
    );
  });

  group('only the two can use their shelf', () {
    test('a third install that knows both keys finds nothing and can put '
        'nothing there', () async {
      final writing = on(mac);
      await writing.send(toInstall: phone.id, body: _utf8('for the phone'));
      await writing.flush();

      final third = _Install();
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
      await writing.send(toInstall: phone.id, body: _utf8('first'));
      await writing.flush();
      final before = Map<String, Uint8List>.of(relay.pointers);
      // The same install, having lost its file and its count, writes again:
      // it steps over the taken number instead of overwriting it.
      mac.letters.data = {};
      final amnesiac = on(mac);
      await amnesiac.send(toInstall: phone.id, body: _utf8('second'));
      await amnesiac.flush();
      for (final entry in before.entries) {
        expect(relay.pointers[entry.key], entry.value);
      }
      expect(relay.pointers.length, greaterThan(before.length));

      final reading = on(phone);
      await reading.pollOnce();
      expect(reading.inbox.value.map((l) => l.text), ['first', 'second']);
    });
  });

  group('when the relay is out of reach or forgets', () {
    test('unreachable: the letter stays in the queue and says so; shelved '
        'later, it says that instead', () async {
      final writing = on(mac);
      relay.down = true;
      await writing.send(toInstall: phone.id, body: _utf8('later'));
      await writing.flush();
      var letter = writing.outbox.value.single;
      expect(letter.state, SealedSentState.queuedDoorClosed);
      expect(letter.onShelf, isFalse);
      expect(letter.describe(mac.now), contains('mailbox unreachable'));

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
        // Seen on the rig: the app's "I am here" made every unopened letter
        // due at once, so letters already on the relay were put there again.
        final writing = on(mac);
        await writing.send(toInstall: phone.id, body: _utf8('once is enough'));
        await writing.flush();
        final pointers = relay.pointers.length;
        await writing.dispose();

        final again = on(mac);
        await again.announce();
        await again.flush();
        expect(again.outbox.value.single.attempts, 1);
        expect(relay.pointers.length, pointers);
      },
    );

    test(
      'a receipt that could not be shelved is shelved on a later round',
      () async {
        final writing = on(mac);
        await writing.send(toInstall: phone.id, body: _utf8('receipt later'));
        await writing.flush();
        final reading = on(phone);
        relay.refuseWrites = true;
        await reading.pollOnce();
        expect(reading.inbox.value.single.text, 'receipt later');
        expect(
          phone.of('receipt_tx').every((e) => e['deposited'] == false),
          isTrue,
          reason: 'tried, and tried again in the same round, in vain',
        );
        await writing.pollOnce();
        expect(writing.outbox.value.single.delivered, isFalse);

        relay.refuseWrites = false;
        await reading.pollOnce();
        expect(phone.of('receipt_tx').last['deposited'], isTrue);
        await writing.pollOnce();
        expect(writing.outbox.value.single.delivered, isTrue);
      },
    );

    test('nobody came for two days: the letter is shelved afresh and still '
        'arrives', () async {
      final writing = on(mac);
      await writing.send(toInstall: phone.id, body: _utf8('patient'));
      await writing.flush();
      relay.expireEverything();
      mac.now = mac.now.add(const Duration(hours: 41));
      phone.now = mac.now;
      await writing.flush();
      expect(writing.outbox.value.single.attempts, 2);

      final reading = on(phone);
      await reading.pollOnce();
      expect(reading.inbox.value.single.text, 'patient');
      await writing.pollOnce();
      expect(writing.outbox.value.single.delivered, isTrue);
    });

    test(
      'a box the relay no longer has does not hold up the ones after it',
      () async {
        final writing = on(mac);
        await writing.send(toInstall: phone.id, body: _utf8('lost'));
        await writing.flush();
        relay.objects.clear(); // The object is gone; its pointer is not.
        await writing.send(toInstall: phone.id, body: _utf8('kept'));
        await writing.flush();
        final reading = on(phone);
        await reading.pollOnce();
        expect(reading.inbox.value.single.text, 'kept');
      },
    );
  });
}
