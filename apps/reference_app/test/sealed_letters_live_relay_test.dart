// Sealed letters against the REAL border relay, from this machine. Not a
// device result and not part of the default suite: it talks to the
// internet, so it runs only when asked.
//
//   SEALED_LIVE_RELAY=1 flutter test test/sealed_letters_live_relay_test.dart
//
// Two installs made for the run (fresh keys, pinned to each other, nothing
// on disk). It measures two things a loopback relay cannot: whether the
// real relay still has a box after its recipient was away for 30 s (it does
// not) and that the letter arrives anyway once the recipient is back, and
// that a letter written while the path is closed leaves the queue once the
// path is open.
// The "closed path" is closed at this end — a switch in front of the real
// door — because the relay itself cannot be taken down from here.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/call_session.dart'
    show defaultBorderRelayHost;
import 'package:reference_app/src/intelligence/disk_json_storage.dart';
import 'package:reference_app/src/peer_identity.dart';
import 'package:reference_app/src/sealed/mailbox_door.dart';
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

/// The real door behind a switch.
class _Switched implements MailboxDoor {
  _Switched(this._real);

  final MailboxDoor _real;
  bool closed = false;

  @override
  Future<bool> deposit(String install, Uint8List box) async =>
      closed ? false : _real.deposit(install, box);

  @override
  Future<Uint8List?> take(
    String install, {
    Duration wait = Duration.zero,
  }) async => closed ? null : _real.take(install, wait: wait);

  @override
  Future<void> dispose() => _real.dispose();
}

AppIdentity _newIdentity() => AppIdentity(
  engine: CryptographyIdentityKeyEngine(keyStore: InMemoryKeyStore()),
  pins: PinnedPeerStore(_MemoryStorage()),
);

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final live = Platform.environment['SEALED_LIVE_RELAY'] == '1';

  test(
    'a letter reaches a recipient who was away, and a letter written '
    'with the path closed leaves once it is open',
    () async {
      final a = _newIdentity();
      final b = _newIdentity();
      final aId = _hex(await a.installId());
      final bId = _hex(await b.installId());
      await a.store.checkRemoteIdentity(
        peerId: bId,
        presentedPublicKey: (await b.store.localIdentity()).publicKey,
      );
      await b.store.checkRemoteIdentity(
        peerId: aId,
        presentedPublicKey: (await a.store.localIdentity()).publicKey,
      );
      final aDoor = _Switched(
        RelayMailboxDoor.borderRelay(defaultBorderRelayHost),
      );
      final aService = SealedLetterService(
        identity: a,
        door: aDoor,
        storage: _MemoryStorage(),
        retryBase: const Duration(seconds: 2),
      );
      final bService = SealedLetterService(
        identity: b,
        door: RelayMailboxDoor.borderRelay(defaultBorderRelayHost),
        storage: _MemoryStorage(),
      );
      addTearDown(aService.dispose);
      addTearDown(bService.dispose);
      Uint8List text(String s) => Uint8List.fromList(utf8.encode(s));

      // 1. The recipient is away for half a minute. Measured on this
      // relay: a frame for a side that is not reading is gone somewhere
      // between 8 and 15 s. So the box must NOT be there — and the letter
      // must still arrive, because the recipient says "I am here" when it
      // comes back and the sender puts the box in again.
      final watch = Stopwatch()..start();
      final first = await aService.send(
        toInstall: bId,
        body: text('for a recipient who was away'),
      );
      await aService.flush();
      await Future<void>.delayed(const Duration(seconds: 30));
      expect(await bService.pollOnce(), isTrue);
      final keptByRelay = bService.inbox.value.isNotEmpty;

      // The sender is listening; the recipient comes back and announces.
      final senderListening = aService.pollOnce(
        wait: const Duration(seconds: 15),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      final recipientListening = bService.pollOnce(
        wait: const Duration(seconds: 20),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      await bService.announce();
      await senderListening;
      await aService.flush();
      await recipientListening;
      if (bService.inbox.value.isEmpty) {
        await bService.pollOnce(wait: const Duration(seconds: 10));
      }
      final arrivedMs = watch.elapsedMilliseconds;
      expect(bService.inbox.value.single.text, 'for a recipient who was away');
      await aService.pollOnce(wait: const Duration(seconds: 10));
      final sentFirst = aService.outbox.value.firstWhere(
        (s) => s.id == first.id,
      );
      expect(sentFirst.delivered, isTrue);
      // ignore: avoid_print
      print(
        'LIVE_RELAY away from=$aId to=$bId away_s=30 '
        'relay_still_had_it=$keptByRelay opened_after_return=true '
        'receipt=true attempts=${sentFirst.attempts} total_ms=$arrivedMs',
      );

      // 2. The path is closed when the letter is written.
      aDoor.closed = true;
      final second = await aService.send(
        toInstall: bId,
        body: text('written with the path closed'),
      );
      await aService.flush();
      expect(aService.doorUp.value, isFalse);
      await bService.pollOnce();
      expect(bService.inbox.value, hasLength(1), reason: 'nothing left');
      final closedAttempts = aService.outbox.value
          .firstWhere((s) => s.id == second.id)
          .attempts;

      aDoor.closed = false;
      await Future<void>.delayed(const Duration(seconds: 5));
      await aService.flush();
      expect(
        await bService.pollOnce(wait: const Duration(seconds: 10)),
        isTrue,
      );
      expect(bService.inbox.value.last.text, 'written with the path closed');
      await aService.pollOnce(wait: const Duration(seconds: 10));
      final after = aService.outbox.value.firstWhere((s) => s.id == second.id);
      expect(after.delivered, isTrue);
      // ignore: avoid_print
      print(
        'LIVE_RELAY queued from=$aId to=$bId attempts_while_closed='
        '$closedAttempts delivered_after_open=true attempts=${after.attempts}',
      );
    },
    skip: live ? false : 'set SEALED_LIVE_RELAY=1 to talk to the real relay',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
