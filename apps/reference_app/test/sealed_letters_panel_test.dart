// The sealed-letters panel: what a person sees. Real crypto and the real
// service; the door is a map in memory, because a widget test has no
// network. Lab only.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:messaging/messaging.dart' show Attachment, MediaKind;
import 'package:reference_app/src/intelligence/disk_json_storage.dart';
import 'package:reference_app/src/peer_identity.dart';
import 'package:reference_app/src/sealed/mailbox_door.dart';
import 'package:reference_app/src/sealed/sealed_content.dart';
import 'package:reference_app/src/sealed/sealed_letters.dart';
import 'package:reference_app/src/ui/sealed_letters_panel.dart';
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

/// Mailboxes in memory, with a switch for "the door is down".
class _MemoryDoor implements MailboxDoor {
  _MemoryDoor(this._boxes);

  final Map<String, List<Uint8List>> _boxes;
  static bool down = false;

  @override
  Future<bool> deposit(String install, Uint8List box) async {
    if (down) return false;
    (_boxes[install] ??= []).add(box);
    return true;
  }

  @override
  Future<Uint8List?> take(
    String install, {
    Duration wait = Duration.zero,
  }) async {
    if (down) return null;
    final held = _boxes.remove(install) ?? const <Uint8List>[];
    return Uint8List.fromList([for (final box in held) ...box]);
  }

  @override
  Future<void> dispose() async {}
}

AppIdentity _newIdentity() => AppIdentity(
  engine: CryptographyIdentityKeyEngine(keyStore: InMemoryKeyStore()),
  pins: PinnedPeerStore(_MemoryStorage()),
);

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late Map<String, List<Uint8List>> relay;
  late AppIdentity mac;
  late AppIdentity phone;
  late SealedLetterService macService;
  late SealedLetterService phoneService;
  late String macId;
  late String phoneId;

  SealedLetterService service(AppIdentity identity) => SealedLetterService(
    identity: identity,
    door: _MemoryDoor(relay),
    storage: _MemoryStorage(),
  );

  Future<void> setUpPair(WidgetTester tester, {bool pinned = true}) async {
    await tester.runAsync(() async {
      relay = {};
      _MemoryDoor.down = false;
      mac = _newIdentity();
      phone = _newIdentity();
      macId = _hex(await mac.installId());
      phoneId = _hex(await phone.installId());
      if (pinned) {
        await mac.store.checkRemoteIdentity(
          peerId: phoneId,
          presentedPublicKey: (await phone.store.localIdentity()).publicKey,
        );
        await phone.store.checkRemoteIdentity(
          peerId: macId,
          presentedPublicKey: (await mac.store.localIdentity()).publicKey,
        );
      }
      macService = service(mac);
      phoneService = service(phone);
      await macService.load();
      await phoneService.load();
    });
  }

  Future<void> show(
    WidgetTester tester, {
    Future<Attachment?> Function()? picker,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SealedLettersPanel(
            service: macService,
            identity: mac,
            pickAttachment: picker,
          ),
        ),
      ),
    );
    // The pinned list is read from the pin file.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
  }

  /// Lets real time pass for work started in real time, then redraws.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Taps Send in real time. A tap dispatched on the test's fake clock
  /// would start the Send's futures there, where they only move when the
  /// test pumps — and every later real-time step would wait behind them.
  Future<void> tapSend(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('sealed-send')));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();
  }

  testWidgets('with nobody pinned and nothing to show, the panel is absent', (
    tester,
  ) async {
    await setUpPair(tester, pinned: false);
    await show(tester);
    expect(find.byKey(const Key('sealed-panel')), findsNothing);
  });

  testWidgets('a pinned peer can be written to: the letter waits, then '
      'reads "opened by them" once the receipt is back', (tester) async {
    await setUpPair(tester);
    await show(tester);
    expect(find.byKey(const Key('sealed-panel')), findsOneWidget);
    expect(
      find.textContaining('to ${phoneId.substring(0, 8)}'),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('sealed-compose')),
      'written on the Mac',
    );
    await tapSend(tester);
    await settle(tester);
    expect(find.text('written on the Mac'), findsOneWidget);
    expect(find.textContaining('in queue'), findsOneWidget);
    expect(find.textContaining('opened by them'), findsNothing);

    await tester.runAsync(() async {
      await phoneService.pollOnce();
      await macService.pollOnce();
    });
    await settle(tester);
    expect(find.textContaining('opened by them'), findsOneWidget);
    expect(find.textContaining('in queue'), findsNothing);
    expect(
      phoneService.inbox.value.single.text,
      'written on the Mac',
      reason: 'and the other side really opened it',
    );
  });

  testWidgets('a letter that opened here is shown with who it is from and '
      'how far that key is trusted', (tester) async {
    await setUpPair(tester);
    await show(tester);
    await tester.runAsync(() async {
      await phoneService.send(
        toInstall: macId,
        body: Uint8List.fromList(utf8.encode('written on the phone')),
      );
      await phoneService.flush();
      await macService.pollOnce();
    });
    await settle(tester);
    expect(find.text('written on the phone'), findsOneWidget);
    expect(
      find.textContaining('from ${phoneId.substring(0, 8)}'),
      findsOneWidget,
    );
    expect(find.textContaining('not yet verified'), findsOneWidget);
    expect(find.textContaining('opened here'), findsOneWidget);
  });

  testWidgets('the door down: the panel says the letter waits', (tester) async {
    await setUpPair(tester);
    await show(tester);
    _MemoryDoor.down = true;
    await tester.enterText(find.byKey(const Key('sealed-compose')), 'later');
    await tapSend(tester);
    await settle(tester);
    expect(find.text('later'), findsOneWidget);
    expect(find.textContaining('in queue'), findsOneWidget);
    expect(find.textContaining('mailbox unreachable'), findsWidgets);
  });

  testWidgets('the line under a waiting letter says why, in words', (
    tester,
  ) async {
    await setUpPair(tester);
    await show(tester);
    _MemoryDoor.down = true;
    await tester.enterText(find.byKey(const Key('sealed-compose')), 'why');
    await tapSend(tester);
    await settle(tester);
    final id = macService.outbox.value.single.id;
    final line = tester.widget<Text>(find.byKey(Key('sealed-state-$id'))).data!;
    expect(line, contains('in queue'));
    expect(line, contains('mailbox unreachable'));
    // Nothing on the panel spins.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('a photo that opened here is drawn; a voice note and a video '
      'are named with their size and length', (tester) async {
    await setUpPair(tester);
    await show(tester);
    await tester.runAsync(() async {
      await phoneService.sendMedia(
        toInstall: macId,
        kind: SealedMediaKind.photo,
        contentType: 'image/png',
        bytes: Uint8List.fromList(List<int>.generate(900, (i) => i & 0xff)),
        caption: 'the harbour',
      );
      await phoneService.sendMedia(
        toInstall: macId,
        kind: SealedMediaKind.voice,
        contentType: 'audio/ogg',
        bytes: Uint8List(60000),
        duration: const Duration(seconds: 30),
      );
      await phoneService.sendMedia(
        toInstall: macId,
        kind: SealedMediaKind.video,
        contentType: 'video/mp4',
        bytes: Uint8List(90000),
        duration: const Duration(seconds: 4),
      );
      await phoneService.flush();
      await macService.pollOnce();
    });
    await settle(tester);
    final photo = macService.inbox.value.firstWhere(
      (l) => l.content.media!.kind == SealedMediaKind.photo,
    );
    expect(find.byKey(Key('sealed-photo-${photo.id}')), findsOneWidget);
    expect(find.textContaining('the harbour'), findsOneWidget);
    expect(find.textContaining('voice · 59 KB · 30 s'), findsOneWidget);
    expect(find.textContaining('video · 88 KB · 4.0 s'), findsOneWidget);
  });

  testWidgets('the attach button seals what was chosen, and the text '
      'becomes its caption', (tester) async {
    await setUpPair(tester);
    await show(
      tester,
      picker: () async => Attachment(
        id: 'picked',
        kind: MediaKind.image,
        contentType: 'image/jpeg',
        bytes: List<int>.filled(5000, 7),
      ),
    );
    await tester.enterText(find.byKey(const Key('sealed-compose')), 'look');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('sealed-attach')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await settle(tester);
    final sent = macService.outbox.value.single;
    expect(sent.content.media!.kind, SealedMediaKind.photo);
    expect(sent.content.media!.size, 5000);
    expect(sent.content.media!.caption, 'look');
    expect(find.textContaining('photo · 5 KB — look'), findsOneWidget);
  });

  testWidgets('with no picker there is no attach button', (tester) async {
    await setUpPair(tester);
    await show(tester);
    expect(find.byKey(const Key('sealed-attach')), findsNothing);
  });
}
