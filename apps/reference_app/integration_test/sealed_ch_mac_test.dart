// ignore_for_file: avoid_print
// Phase چ, the Mac half (tools/t2/sealed_ch_rig.sh): the REAL app, one plain
// text letter typed into the chat panel at T, then the app stays on for the
// whole window and waits for that letter's receipt. The phone is locked and
// never opened; whether its receipt comes is iOS's choice of wake.
//
//   flutter test integration_test/sealed_ch_mac_test.dart -d macos \
//     --dart-define=SEALED_CH_PEER=<phone install id> \
//     --dart-define=SEALED_CH_WAIT_S=<window seconds>
//
// Lines: `SEALED_CH tx id=… at=…` once the letter is on the shelf, then
// `SEALED_CH receipt id=… at=…` or `SEALED_CH receipt id=… none`.
@Timeout(Duration(hours: 9))
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:reference_app/main.dart' as app;
import 'package:reference_app/src/peer_identity.dart';
import 'package:reference_app/src/sealed/pair_shelf.dart';
import 'package:reference_app/src/sealed/sealed_letter_service.dart';

const String _peer = String.fromEnvironment('SEALED_CH_PEER');
const int _waitS = int.fromEnvironment('SEALED_CH_WAIT_S', defaultValue: 600);

String _iso(DateTime t) => t.toUtc().toIso8601String();

Future<T?> _until<T>(
  WidgetTester tester,
  T? Function() found,
  Duration limit, {
  Duration every = const Duration(seconds: 1),
}) async {
  final end = DateTime.now().add(limit);
  while (DateTime.now().isBefore(end)) {
    final v = found();
    if (v != null) return v;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() => Future<void>.delayed(every));
  }
  return found();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sealed letter to a closed phone: the Mac sends one text and '
      'waits for its receipt', (tester) async {
    final peer = _peer.trim().toLowerCase();
    expect(peer, isNotEmpty, reason: 'set SEALED_CH_PEER');
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
      print('SEALED_CH ready=false');
      fail('the app has no mailbox service');
    }
    final peers = (await tester.runAsync(identity.pinnedInstalls))!;
    expect(peers, contains(peer), reason: 'SEALED_CH_PEER is not pinned');
    print('SEALED_CH ready=true peer=$peer wait_s=$_waitS');
    // The shelf authors this letter can land on: the rig reads the relay's
    // push record for them (`GET /p/<author>`) after the window.
    final shelf = service.shelf;
    if (shelf is PairShelf) {
      final authors = await tester.runAsync(() => shelf.outboundAuthors(peer));
      print('SEALED_CH authors=${authors!.join(',')}');
    }

    await tester.tap(find.byIcon(Icons.chat_bubble));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('sealed-panel')), findsOneWidget);
    // With more than one pin the panel's picker names the peer; the rig
    // phone is the only pin on this Mac (checked by the script).
    final text = 'written on the mac at ${_iso(DateTime.now())} (ch)';
    await tester.enterText(find.byKey(const Key('sealed-compose')), text);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('sealed-send')));

    SealedSent? mine() {
      for (final s in service.outbox.value) {
        if (s.at.isAfter(started) && s.to == peer) return s;
      }
      return null;
    }

    final sent = await _until<SealedSent>(
      tester,
      () => mine()?.onShelf == true ? mine() : null,
      const Duration(seconds: 120),
    );
    expect(sent, isNotNull, reason: 'the letter never reached the shelf');
    print(
      'SEALED_CH tx id=${sent!.id} at=${_iso(sent.at)} bytes=${sent.bytes}',
    );

    final got = await _until<SealedSent>(
      tester,
      () {
        final s = mine();
        return s != null && s.delivered ? s : null;
      },
      const Duration(seconds: _waitS),
      every: const Duration(seconds: 5),
    );
    print(
      got == null
          ? 'SEALED_CH receipt id=${sent.id} none'
          : 'SEALED_CH receipt id=${sent.id} at=${_iso(got.deliveredAt!)}',
    );
  });
}
