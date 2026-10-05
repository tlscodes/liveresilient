// ignore_for_file: avoid_print
// The Mac half of the "one side is off" rig run (tools/t2/sealed_offline_rig.sh).
// It starts the real app through its own main() and uses the app's own
// mailbox service and its own panel. No call, no hub.
//
//   SEALED_RIG_MODE=send     write a text (typed into the panel), a photo, a
//                            30 s voice note and a short video to the one
//                            pinned peer — which is switched off — print
//                            where each letter is, signal the script to
//                            switch the peer on, and print each receipt.
//   SEALED_RIG_MODE=receive  the app was off while the peer wrote; print
//                            each letter as it opens here.
//
// Media is handed to the service directly: a test cannot drive the system's
// file picker. The text goes through the panel's field and button. Lines
// carry ids, kinds, sizes, times and flags — never content.
@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:reference_app/main.dart' as app;
import 'package:reference_app/src/peer_identity.dart';
import 'package:reference_app/src/sealed/sealed_content.dart';
import 'package:reference_app/src/sealed/sealed_letters.dart';

const String _mode = String.fromEnvironment('SEALED_RIG_MODE');
const String _dir = String.fromEnvironment('SEALED_RIG_DIR');
const int _waitS = int.fromEnvironment('SEALED_RIG_WAIT_S', defaultValue: 240);
const int _replyAfterS = int.fromEnvironment('SEALED_RIG_REPLY_AFTER_S');

String _iso(DateTime? at) => at == null ? '-' : at.toUtc().toIso8601String();

Future<String> _sha8(List<int> bytes) async => (await Sha256().hash(
  bytes,
)).bytes.take(4).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Future<T?> _until<T>(
  WidgetTester tester,
  T? Function() found,
  Duration budget,
) async {
  final deadline = DateTime.now().add(budget);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 500));
    final value = found();
    if (value != null) return value;
  }
  return found();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sealed letters with one side off: the Mac app ($_mode)', (
    tester,
  ) async {
    expect(['send', 'receive'], contains(_mode));
    expect(_dir, isNotEmpty);
    final started = DateTime.now();
    final booted = app.main();
    final service = await _until<SealedLetterService>(
      tester,
      () => sealedLetterService.value,
      const Duration(seconds: 90),
    );
    await tester.runAsync(() => booted.timeout(const Duration(seconds: 60)));
    final identity = appIdentity;
    if (service == null || identity == null) {
      print('SEALED_RIG ready=false service=${service != null}');
      fail('the app has no mailbox service');
    }
    final own = (await tester.runAsync(
      identity.installId,
    ))!.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final peers = (await tester.runAsync(identity.pinnedInstalls))!;
    expect(peers, isNotEmpty, reason: 'this install has pinned nobody');
    final peer = peers.first;
    print('SEALED_RIG ready=true mode=$_mode own=$own peer=$peer');

    // The panel is on the Chat tab.
    await tester.tap(find.byIcon(Icons.chat_bubble));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('sealed-panel')), findsOneWidget);

    // The list builds only the rows in view, so a row is scrolled to before
    // its line is read off the screen.
    Future<String> onScreen(String id) async {
      final line = find.byKey(Key('sealed-state-$id'));
      if (line.evaluate().isEmpty) {
        try {
          await tester.scrollUntilVisible(
            line,
            60,
            scrollable: find
                .descendant(
                  of: find.byKey(const Key('sealed-panel')),
                  matching: find.byType(Scrollable),
                )
                .first,
            maxScrolls: 30,
          );
        } catch (_) {
          // Reported below as not in view.
        }
      }
      return line.evaluate().isEmpty
          ? 'not_in_view'
          : tester.widget<Text>(line).data!.replaceAll(' ', '_');
    }

    if (_mode == 'send') {
      // The rig peer writes back this many seconds after it opens this
      // text — by then this app has exited.
      final text =
          'written on the mac at ${_iso(DateTime.now())}'
          '${_replyAfterS > 0 ? ' #rig-reply-after=$_replyAfterS' : ''}';
      await tester.enterText(find.byKey(const Key('sealed-compose')), text);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('sealed-send')));
      await tester.pump(const Duration(seconds: 1));
      Future<void> media(
        SealedMediaKind kind,
        String file,
        String type,
        Duration duration,
      ) async {
        final bytes = File('$_dir/$file').readAsBytesSync();
        await tester.runAsync(
          () => service.sendMedia(
            toInstall: peer,
            kind: kind,
            contentType: type,
            bytes: Uint8List.fromList(bytes),
            duration: duration,
          ),
        );
        print(
          'SEALED_RIG fixture kind=${kind.label} bytes=${bytes.length} '
          'sha=${await tester.runAsync(() => _sha8(bytes))}',
        );
      }

      await media(
        SealedMediaKind.photo,
        'photo.jpg',
        'image/jpeg',
        Duration.zero,
      );
      await media(
        SealedMediaKind.voice,
        'voice.m4a',
        'audio/mp4',
        const Duration(seconds: 30),
      );
      await media(
        SealedMediaKind.video,
        'video.mp4',
        'video/mp4',
        const Duration(seconds: 10),
      );

      // The peer is off. Let the queue try, then say where each letter is.
      await _until<bool>(tester, () => null, const Duration(seconds: 25));
      for (final s in service.outbox.value.where(
        (s) => s.at.isAfter(started),
      )) {
        print(
          'SEALED_RIG queued kind=${s.content.kindLabel} from=$own to=${s.to} '
          'bytes=${s.bytes} sent_at=${_iso(s.at)} state=${s.state.name} '
          'attempts=${s.attempts} receipt=${s.delivered} '
          'screen=${await onScreen(s.id)}',
        );
      }
      // The script switches the peer on when this file appears.
      File('$_dir/peer_may_start').writeAsStringSync(_iso(DateTime.now()));

      await _until<bool>(
        tester,
        () =>
            service.outbox.value
                .where((s) => s.at.isAfter(started))
                .every((s) => s.delivered)
            ? true
            : null,
        const Duration(seconds: _waitS),
      );
      await tester.pump(const Duration(seconds: 1));
      for (final s in service.outbox.value.where(
        (s) => s.at.isAfter(started),
      )) {
        print(
          'SEALED_RIG row dir=mac_to_phone kind=${s.content.kindLabel} '
          'from=$own to=${s.to} bytes=${s.bytes} sent_at=${_iso(s.at)} '
          'receipt_at=${_iso(s.deliveredAt)} receipt=${s.delivered} '
          'state=${s.state.name} attempts=${s.attempts} '
          'screen=${await onScreen(s.id)}',
        );
      }
    } else {
      // Everything the peer wrote while this app was off.
      Iterable<SealedReceived> fresh() => service.inbox.value.where(
        (r) => r.from == peer && r.receivedAt.isAfter(started),
      );
      await _until<bool>(
        tester,
        () =>
            {
              for (final r in fresh()) r.content.kindLabel,
            }.containsAll(const ['text', 'photo', 'voice', 'video'])
            ? true
            : null,
        const Duration(seconds: _waitS),
      );
      await tester.pump(const Duration(seconds: 1));
      for (final r in fresh()) {
        final drawn = r.content.media?.kind == SealedMediaKind.photo
            ? find.byKey(Key('sealed-photo-${r.id}')).evaluate().isNotEmpty
            : find.textContaining(r.text).evaluate().isNotEmpty;
        print(
          'SEALED_RIG row dir=phone_to_mac kind=${r.content.kindLabel} '
          'from=${r.from} to=$own bytes=${r.bytes} sent_at=${_iso(r.sentAt)} '
          'opened_at=${_iso(r.receivedAt)} opened=true verified=${r.verified} '
          'sha=${await tester.runAsync(() => _sha8(r.body))} '
          'on_screen=$drawn',
        );
      }
      print('SEALED_RIG received=${fresh().length}');
      // Give the receipts time to leave before the app goes off again.
      await _until<bool>(tester, () => null, const Duration(seconds: 12));
      print('SEALED_RIG note=utf8_check ${utf8.encode('ok').length == 2}');
    }
  });
}
