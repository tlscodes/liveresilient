// The pair shelf against the REAL border relay, from this machine. Not a
// device result and not part of the default suite: it talks to the
// internet, so it runs only when asked.
//
//   SEALED_LIVE_RELAY=1 flutter test test/pair_shelf_live_relay_test.dart
//
// Two installs made for the run (fresh keys, pinned to each other, nothing
// on disk). It answers what a loopback relay cannot: does the deployed
// relay accept this code's write credential, and does a letter written by
// a sender who then goes away open for a recipient who was never there at
// the same time — with the receipt going back the same way.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/call_session.dart'
    show defaultBorderRelayHost;
import 'package:reference_app/src/intelligence/disk_json_storage.dart';
import 'package:reference_app/src/peer_identity.dart';
import 'package:reference_app/src/sealed/pair_shelf.dart';
import 'package:reference_app/src/sealed/relay_requests.dart';
import 'package:reference_app/src/sealed/sealed_blob_store.dart';
import 'package:reference_app/src/sealed/sealed_content.dart';
import 'package:reference_app/src/sealed/sealed_letter_service.dart';
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

class _Install {
  final AppIdentity identity = AppIdentity(
    engine: CryptographyIdentityKeyEngine(keyStore: InMemoryKeyStore()),
    pins: PinnedPeerStore(_MemoryStorage()),
  );
  final _MemoryStorage letters = _MemoryStorage();
  final MemorySealedBlobStore blobs = MemorySealedBlobStore();
  final List<String> events = [];
  late final String id;

  /// What this install has asked of the real relay, counted and cut off
  /// exactly as the app's own requests are.
  final RequestBudget budget = RequestBudget();

  SealedLetterService service() => SealedLetterService(
    identity: identity,
    storage: letters,
    blobs: blobs,
    shelf: PairShelf(
      identity: identity,
      origin: Uri(scheme: 'https', host: defaultBorderRelayHost),
      transport: MeteredRelayTransport(budget: budget),
    ),
    budget: budget,
    onEvent: (event, fields) => events.add('$event ${jsonEncode(fields)}'),
  );
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final live = Platform.environment['SEALED_LIVE_RELAY'] == '1';

  test(
    'on the deployed relay a letter waits for a recipient who was never '
    'there with its sender, and so does the receipt',
    () async {
      final a = _Install();
      final b = _Install();
      a.id = _hex(await a.identity.installId());
      b.id = _hex(await b.identity.installId());
      await a.identity.store.checkRemoteIdentity(
        peerId: b.id,
        presentedPublicKey: (await b.identity.store.localIdentity()).publicKey,
      );
      await b.identity.store.checkRemoteIdentity(
        peerId: a.id,
        presentedPublicKey: (await a.identity.store.localIdentity()).publicKey,
      );
      final media = Uint8List.fromList(
        List<int>.generate(60000, (i) => (i * 13 + (i >> 7)) & 0xff),
      );

      // A writes, and is gone.
      final writing = a.service();
      await writing.send(
        toInstall: b.id,
        body: Uint8List.fromList(utf8.encode('waiting on the shelf')),
      );
      await writing.sendMedia(
        toInstall: b.id,
        kind: SealedMediaKind.photo,
        contentType: 'image/jpeg',
        bytes: media,
      );
      await writing.flush();
      expect(
        writing.outbox.value.every((s) => s.onShelf),
        isTrue,
        reason: 'the relay refused a write: ${a.events.join(' | ')}',
      );
      await writing.dispose();

      // Well past the seconds the mailbox keeps anything.
      await Future<void>.delayed(const Duration(seconds: 40));

      // B comes on, alone.
      final reading = b.service();
      expect(await reading.look(), isTrue);
      expect(reading.inbox.value.map((l) => l.content.kindLabel), [
        'text',
        'photo',
      ]);
      expect(reading.inbox.value.last.media, media);
      await reading.dispose();

      await Future<void>.delayed(const Duration(seconds: 20));

      // A comes back, alone, to its receipts.
      final back = a.service();
      expect(await back.look(), isTrue);
      expect(back.outbox.value.every((s) => s.delivered), isTrue);
      await back.dispose();
      // ignore: avoid_print
      print(
        'LIVE_SHELF from=${a.id} to=${b.id} sender_off=true '
        'recipient_came_after_s=40 opened=text,photo photo_bytes=60000 '
        'receipts_read_by_sender_alone=true',
      );
    },
    skip: live ? false : 'set SEALED_LIVE_RELAY=1 to talk to the real relay',
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
