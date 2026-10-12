// Phase چ: one background turn drains the shelf, notifies once per new
// letter, sends the receipt, and stays inside its deadline. No flag needed:
// [SealedBackgroundTurn] is plain Dart; only the channel install is gated.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/intelligence/disk_json_storage.dart';
import 'package:reference_app/src/peer_identity.dart';
import 'package:reference_app/src/sealed/sealed_background.dart';
import 'package:reference_app/src/sealed/sealed_letter_service.dart';
import 'package:security/security.dart';

import 'support/memory_shelf.dart';

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

AppIdentity _newIdentity() => AppIdentity(
  engine: CryptographyIdentityKeyEngine(keyStore: InMemoryKeyStore()),
  pins: PinnedPeerStore(_MemoryStorage()),
);

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('the background flag is off in a plain build', () {
    expect(kSealedBackground, isFalse);
    expect(kSealedTxtOnly, isFalse);
  });

  group('one background turn', () {
    late SealedLetterService mac;
    late SealedLetterService phone;
    late String phoneId;
    final macEvents = <Map<String, Object?>>[];
    final phoneEvents = <Map<String, Object?>>[];

    setUp(() async {
      macEvents.clear();
      phoneEvents.clear();
      final relay = MemoryRelay();
      final a = _newIdentity();
      final b = _newIdentity();
      final macId = _hex(await a.installId());
      phoneId = _hex(await b.installId());
      await a.store.checkRemoteIdentity(
        peerId: phoneId,
        presentedPublicKey: (await b.store.localIdentity()).publicKey,
      );
      await b.store.checkRemoteIdentity(
        peerId: macId,
        presentedPublicKey: (await a.store.localIdentity()).publicKey,
      );
      mac = SealedLetterService(
        identity: a,
        shelf: relay.shelfOf(macId),
        storage: _MemoryStorage(),
        onEvent: (e, f) => macEvents.add({'event': e, ...f}),
      );
      phone = SealedLetterService(
        identity: b,
        shelf: relay.shelfOf(phoneId),
        storage: _MemoryStorage(),
        onEvent: (e, f) => phoneEvents.add({'event': e, ...f}),
      );
      await mac.load();
      await phone.load();
    });

    SealedBackgroundTurn turn(
      List<Map<String, Object?>> journal, {
      DateTime? until,
      Duration deadline = const Duration(seconds: 25),
      Future<SealedNotifyResult> Function(String)? notify,
    }) => SealedBackgroundTurn(
      service: () async => phone,
      notify:
          notify ?? (_) async => const SealedNotifyResult(auth: 'authorized'),
      journal: (e, f) => journal.add({'event': e, ...f}),
      until: until,
      deadline: deadline,
      lane: 'txt',
    );

    test('a new letter: rx, receipt_tx and one notify_local inside the turn, '
        'then resubmit', () async {
      final sent = await mac.send(
        toInstall: phoneId,
        body: Uint8List.fromList(utf8.encode('hello while closed')),
      );
      await mac.flush();
      final journal = <Map<String, Object?>>[];
      final r = await turn(journal).run(
        id: 'x.sealed.refresh',
        launchReason: 'bg_refresh',
        appState: 'background',
        protectedData: false,
      );
      expect(r['expired'], isFalse);
      expect(r['resubmit'], isTrue);
      expect(r['fresh'], 1);
      expect(r['lane'], 'txt');
      final notes = journal.where((e) => e['event'] == 'notify_local').toList();
      expect(notes, hasLength(1));
      expect(notes.single['letter_id'], sent.id);
      expect(notes.single['auth'], 'authorized');
      expect(notes.single['add_err'], isNull);
      expect(
        phoneEvents.where((e) => e['event'] == 'rx' && e['id'] == sent.id),
        hasLength(1),
      );
      expect(
        phoneEvents.where(
          (e) => e['event'] == 'receipt_tx' && e['id'] == sent.id,
        ),
        hasLength(1),
      );
      final bg = journal.lastWhere((e) => e['event'] == 'bg_turn');
      expect(
        DateTime.parse(
          '${bg['begin']}',
        ).isAfter(DateTime.parse('${bg['end']}')),
        isFalse,
      );
      // A second turn finds nothing new and notifies nothing.
      final again = <Map<String, Object?>>[];
      final r2 = await turn(again).run(
        id: 'x.sealed.refresh',
        launchReason: 'bg_refresh',
        appState: 'background',
        protectedData: false,
      );
      expect(r2['fresh'], 0);
      expect(again.where((e) => e['event'] == 'notify_local'), isEmpty);
    });

    test('past bg_until: no network, no notify, no resubmit', () async {
      await mac.send(
        toInstall: phoneId,
        body: Uint8List.fromList(utf8.encode('late')),
      );
      await mac.flush();
      final journal = <Map<String, Object?>>[];
      final r =
          await turn(
            journal,
            until: DateTime.now().subtract(const Duration(minutes: 1)),
          ).run(
            id: 'x',
            launchReason: 'bg_refresh',
            appState: 'background',
            protectedData: false,
          );
      expect(r['past_until'], isTrue);
      expect(r['resubmit'], isFalse);
      expect(phoneEvents.where((e) => e['event'] == 'rx'), isEmpty);
      expect(journal.where((e) => e['event'] == 'notify_local'), isEmpty);
    });

    test('a turn that overruns its deadline is journaled expired', () async {
      await mac.send(
        toInstall: phoneId,
        body: Uint8List.fromList(utf8.encode('slow')),
      );
      await mac.flush();
      final journal = <Map<String, Object?>>[];
      final r =
          await turn(
            journal,
            deadline: const Duration(milliseconds: 200),
            notify: (_) async {
              await Future<void>.delayed(const Duration(seconds: 2));
              return const SealedNotifyResult(auth: 'authorized');
            },
          ).run(
            id: 'x',
            launchReason: 'bg_refresh',
            appState: 'background',
            protectedData: false,
          );
      expect(r['expired'], isTrue);
      expect(journal.last['event'], 'bg_turn');
      expect(journal.last['expired'], isTrue);
    });

    test('no identity yet: the turn is a journaled no-op', () async {
      final journal = <Map<String, Object?>>[];
      final r =
          await SealedBackgroundTurn(
            service: () async => null,
            notify: (_) async => const SealedNotifyResult(auth: 'authorized'),
            journal: (e, f) => journal.add({'event': e, ...f}),
          ).run(
            id: 'x',
            launchReason: 'cold',
            appState: 'background',
            protectedData: true,
          );
      expect(r['no_service'], isTrue);
      expect(r['expired'], isFalse);
      expect(r['lane'], 'mixed');
    });
  });
}
