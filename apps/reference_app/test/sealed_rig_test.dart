// The SEALED_RIG hooks in the real chat panel (phase پ). Run with the flag:
//
//   flutter test --dart-define=SEALED_RIG=true \
//     --dart-define=SEALED_RIG_DIR=<an empty scratch directory> \
//     test/sealed_rig_test.dart
//
// The rig box is filled here with known bytes. What is proven: the attach
// button is answered from the box in order (photo, 30 s voice, video) and the
// bytes sealed are the box's bytes; a #rig-reply-after text makes the other
// side write back a text and the three fixtures through its own panel; and
// every row's line read off the widget tree reaches the journal hook.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/intelligence/disk_json_storage.dart';
import 'package:reference_app/src/peer_identity.dart';
import 'package:reference_app/src/sealed/sealed_letter_service.dart';
import 'package:reference_app/src/sealed/sealed_rig.dart';
import 'package:reference_app/src/ui/sealed_letters_panel.dart';
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
  test('the rig flag is compiled in for this run', () {
    expect(
      kSealedRig,
      isTrue,
      reason: 'run with --dart-define=SEALED_RIG=true',
    );
  });

  testWidgets('rig letters go through the panel: attach is answered from the '
      'box, a #rig-reply-after text is answered with all four, and every '
      'row line reaches the journal', (tester) async {
    final box = SealedRig.instance.box;
    final fixtures = <String, Uint8List>{};
    late AppIdentity mac;
    late AppIdentity phone;
    late String macId;
    late String phoneId;
    late SealedLetterService macService;
    late SealedLetterService phoneService;
    final macEvents = <Map<String, Object?>>[];
    final phoneEvents = <Map<String, Object?>>[];
    await tester.runAsync(() async {
      box.createSync(recursive: true);
      for (final (name, _, _, _) in SealedRig.fixtures) {
        final bytes = Uint8List.fromList(
          List<int>.generate(700 + name.length, (i) => (i * 31 + 7) & 0xff),
        );
        File('${box.path}/$name').writeAsBytesSync(bytes);
        fixtures[name] = bytes;
      }
      final relay = MemoryRelay();
      mac = _newIdentity();
      phone = _newIdentity();
      macId = _hex(await mac.installId());
      phoneId = _hex(await phone.installId());
      await mac.store.checkRemoteIdentity(
        peerId: phoneId,
        presentedPublicKey: (await phone.store.localIdentity()).publicKey,
      );
      await phone.store.checkRemoteIdentity(
        peerId: macId,
        presentedPublicKey: (await mac.store.localIdentity()).publicKey,
      );
      macService = SealedLetterService(
        identity: mac,
        shelf: relay.shelfOf(macId),
        storage: _MemoryStorage(),
        onEvent: (e, f) => macEvents.add({'event': e, ...f}),
      );
      phoneService = SealedLetterService(
        identity: phone,
        shelf: relay.shelfOf(phoneId),
        storage: _MemoryStorage(),
        onEvent: (e, f) => phoneEvents.add({'event': e, ...f}),
      );
      await macService.load();
      await phoneService.load();
    });

    Future<void> show(SealedLetterService service, AppIdentity who) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SealedLettersPanel(
              key: ValueKey(who),
              service: service,
              identity: who,
              pickAttachment: SealedRig.instance.pick,
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }

    Future<void> realTime(int ms) async {
      await tester.runAsync(
        () => Future<void>.delayed(Duration(milliseconds: ms)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    // 1. The Mac: a typed text, then attach three times.
    await show(macService, mac);
    await tester.enterText(
      find.byKey(const Key('sealed-compose')),
      'written on the mac #rig-reply-after=1',
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('sealed-send')));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('sealed-attach')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }
    await realTime(200);
    final sent = macService.outbox.value;
    expect(sent.map((s) => s.content.kindLabel), [
      'text',
      'photo',
      'voice',
      'video',
    ]);
    expect(sent.every((s) => s.to == phoneId), isTrue);
    for (final s in sent.skip(1)) {
      final m = s.content.media!;
      final name = SealedRig.fixtures
          .firstWhere((f) => f.$2 == m.contentType)
          .$1;
      expect(m.size, fixtures[name]!.length, reason: name);
    }
    expect(sent[2].content.media!.duration, const Duration(seconds: 30));
    final macScreens = macEvents.where((e) => e['event'] == 'rig_screen');
    expect(
      macScreens.map((e) => '${e['dir']} ${e['kind']}').toSet(),
      containsAll(['out text', 'out photo', 'out voice', 'out video']),
    );
    expect(
      macScreens.firstWhere((e) => e['kind'] == 'text')['screen_text'],
      'written on the mac #rig-reply-after=1',
    );
    expect(
      macScreens.firstWhere((e) => e['kind'] == 'voice')['screen_text'],
      startsWith('voice'),
    );

    // 2. The phone: its own panel, one look — the rig answers a second later.
    await show(phoneService, phone);
    await tester.runAsync(() => phoneService.look());
    await realTime(200);
    final opened = phoneService.inbox.value;
    expect(opened.length, 4);
    for (final r in opened.where((r) => r.content.media != null)) {
      final name = SealedRig.fixtures
          .firstWhere((f) => f.$2 == r.content.media!.contentType)
          .$1;
      expect(r.media, fixtures[name], reason: 'the box bytes, opened');
    }
    await realTime(2500);
    final back = phoneService.outbox.value;
    expect(back.map((s) => s.content.kindLabel), [
      'text',
      'photo',
      'voice',
      'video',
    ]);
    expect(back.every((s) => s.to == macId), isTrue);
    expect(back.first.text, startsWith('written on the phone at '));
    final phoneScreens = phoneEvents.where((e) => e['event'] == 'rig_screen');
    expect(
      phoneScreens.map((e) => '${e['dir']} ${e['kind']}').toSet(),
      containsAll([
        'in text',
        'in photo',
        'in voice',
        'in video',
        'out text',
        'out photo',
        'out voice',
        'out video',
      ]),
    );
    expect(
      phoneEvents.where((e) => e['event'] == 'rig_reply_due').length,
      1,
      reason: 'one request, answered once',
    );
  });
}
