// ignore_for_file: avoid_print
// Phase پ, the Mac half: the REAL app — lib/main.dart's own main() — built
// with --dart-define=SEALED_RIG=true, driven only through the chat panel a
// person uses (tools/t2/sealed_txt_phone_rig.sh, SEALED_TARGET=real).
//
//   SEALED_RIG_MODE=write    type a text ending in #rig-reply-after=<s> into
//                            the panel and press send, then press attach
//                            three times (the rig box answers: photo, 30 s
//                            voice note, short video); see each letter onto
//                            the relay's shelf, print where it is, leave.
//   SEALED_RIG_MODE=receive  the app was off while the phone wrote; print
//                            each letter as it opens here and the receipts
//                            of what this app wrote.
//
// The panel itself writes each row's line, read off the widget tree, to the
// journal (`rig_screen`). Lines here carry ids, kinds, sizes, times, flags.
@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:reference_app/main.dart' as app;
import 'package:reference_app/src/peer_identity.dart';
import 'package:reference_app/src/sealed/sealed_content.dart';
import 'package:reference_app/src/sealed/sealed_letter_service.dart';
import 'package:reference_app/src/sealed/sealed_rig.dart';

import 'support/sealed_screen_probe.dart';

const String _mode = String.fromEnvironment('SEALED_RIG_MODE');
const String _dir = String.fromEnvironment('SEALED_RIG_DIR');
const int _waitS = int.fromEnvironment('SEALED_RIG_WAIT_S', defaultValue: 240);
const int _replyAfterS = int.fromEnvironment(
  'SEALED_RIG_REPLY_AFTER_S',
  defaultValue: 60,
);

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

  testWidgets('sealed letters on the real app: the Mac ($_mode)', (
    tester,
  ) async {
    expect(kSealedRig, isTrue, reason: 'build with SEALED_RIG=true');
    expect(['write', 'receive'], contains(_mode));
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
    final peer = kSealedRigPeer.trim().toLowerCase();
    // With two pins the rig must say which one it writes to, so a letter
    // never goes silently to an old pin.
    expect(peer, isNotEmpty, reason: 'set SEALED_RIG_PEER');
    expect(peers, contains(peer), reason: 'SEALED_RIG_PEER is not pinned');
    print(
      'SEALED_RIG ready=true mode=$_mode target=real own=$own '
      'pins=${peers.length} peer=$peer',
    );

    // A rig build opens on Chat; the tab is pressed anyway, as a person would.
    await tester.tap(find.byIcon(Icons.chat_bubble));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('sealed-panel')), findsOneWidget);

    String stateLine(String id) {
      final line = find.byKey(Key('sealed-state-$id'));
      return line.evaluate().isEmpty
          ? 'not_built'
          : tester.widget<Text>(line).data!.replaceAll(' ', '_');
    }

    if (_mode == 'write') {
      final text =
          'written on the mac at ${_iso(DateTime.now())} '
          '#rig-reply-after=$_replyAfterS';
      await tester.enterText(find.byKey(const Key('sealed-compose')), text);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('sealed-send')));
      Iterable<SealedSent> mine() =>
          service.outbox.value.where((s) => s.at.isAfter(started));
      // Each letter is awaited by its own kind, not by the outbox length: in
      // full3 the text took a second attempt, every count shifted by one and
      // the video tap landed while the panel was busy (attach is disabled
      // then, so the tap was dropped and the video never left).
      bool has(String kind) => mine().any((s) => s.content.kindLabel == kind);
      await _until<bool>(
        tester,
        () => has('text') ? true : null,
        const Duration(seconds: 60),
      );
      print(
        'SEALED_RIG fixture kind=text bytes=${utf8.encode(text).length} '
        'sha=${await tester.runAsync(() => _sha8(utf8.encode(text)))}',
      );
      for (final (name, _, _, _) in SealedRig.fixtures) {
        final kind = name.split('.').first; // photo, voice, video
        bool? queued;
        for (var tap = 0; tap < 3 && queued == null; tap++) {
          await _until<bool>(
            tester,
            () =>
                tester
                        .widget<IconButton>(
                          find.byKey(const Key('sealed-attach')),
                        )
                        .onPressed !=
                    null
                ? true
                : null,
            const Duration(seconds: 60),
          );
          // A tap the panel took late would pick the next fixture on re-tap.
          if (has(kind)) {
            queued = true;
            break;
          }
          await tester.tap(find.byKey(const Key('sealed-attach')));
          queued = await _until<bool>(
            tester,
            () => has(kind) ? true : null,
            const Duration(seconds: 60),
          );
        }
        final bytes = File('$_dir/$name').readAsBytesSync();
        print(
          'SEALED_RIG fixture kind=$kind bytes=${bytes.length} '
          'sha=${await tester.runAsync(() => _sha8(bytes))} '
          'queued=${queued ?? false}',
        );
      }
      // Every letter onto the relay's shelf, then leave: nobody is there to
      // open them, and this app is off long before anyone is.
      await _until<bool>(
        tester,
        () =>
            mine().length == 4 && mine().every((s) => s.onShelf) ? true : null,
        const Duration(seconds: 120),
      );
      await tester.pump(const Duration(seconds: 2));
      for (final s in mine()) {
        expect(s.to, peer);
        print(
          'SEALED_RIG written dir=mac_to_phone kind=${s.content.kindLabel} '
          'from=$own to=${s.to} bytes=${s.bytes} sent_at=${_iso(s.at)} '
          'on_relay=${s.onShelf} receipt=${s.delivered} '
          'attempts=${s.attempts} screen=${stateLine(s.id)}',
        );
      }
      print('SEALED_RIG leaving_at=${_iso(DateTime.now())}');
      return;
    }

    // Everything the phone wrote while this app was off.
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
      final sight = await sealedRowSight(
        tester,
        id: r.id,
        text: r.text,
        photo: r.content.media?.kind == SealedMediaKind.photo,
      );
      print(
        'SEALED_RIG row dir=phone_to_mac kind=${r.content.kindLabel} '
        'id=${r.id} from=${r.from} to=$own bytes=${r.bytes} '
        'sent_at=${_iso(r.sentAt)} opened_at=${_iso(r.receivedAt)} '
        'opened=true verified=${r.verified} '
        'sha=${await tester.runAsync(() => _sha8(r.body))} '
        'on_screen=${sight.shown} in_view=${sight.inView}',
      );
    }
    print('SEALED_RIG received=${fresh().length}');
    // And the receipts for what THIS app wrote before it was switched off.
    final cutoff = started.subtract(const Duration(hours: 6));
    Iterable<SealedSent> recent() =>
        service.outbox.value.where((s) => s.at.isAfter(cutoff));
    await _until<bool>(
      tester,
      () => recent().every((s) => s.delivered) ? true : null,
      const Duration(seconds: 60),
    );
    for (final s in recent()) {
      print(
        'SEALED_RIG row dir=mac_to_phone kind=${s.content.kindLabel} '
        'from=$own to=${s.to} bytes=${s.bytes} sent_at=${_iso(s.at)} '
        'receipt_read_at=${_iso(s.deliveredAt)} receipt=${s.delivered} '
        'attempts=${s.attempts} screen=${stateLine(s.id)}',
      );
    }
    // Give the receipts time to leave before the app goes off again.
    await _until<bool>(tester, () => null, const Duration(seconds: 12));
  });
}
