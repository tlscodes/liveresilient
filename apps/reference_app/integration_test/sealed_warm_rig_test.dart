// ignore_for_file: avoid_print
// The Mac half of the warm run (tools/t2/sealed_warm_rig.sh): both apps are
// open and the conversation is warm, and the time from "written" to "opened
// on the other side" is taken for texts in both directions.
//
// It starts the real app through its own main(), types each text into the
// app's own panel, and uses the app's own letter service. The phone runs
// the rig peer, which answers a text ending in `#rig-echo=<n>` at once with
// one that says when it opened it. So one round trip gives four instants:
//
//   mac_sent    the Mac wrote text n            (Mac clock)
//   phone_open  the phone opened it             (phone clock)
//   phone_sent  the phone wrote its answer      (phone clock)
//   mac_open    the Mac opened the answer       (Mac clock)
//
// The two clocks are not assumed to agree: the script that reads these
// lines bounds the difference from the data itself. Round 0 is a warm-up
// and is not counted. Lines carry counters and times — never content.
@Timeout(Duration(minutes: 20))
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:reference_app/main.dart' as app;
import 'package:reference_app/src/peer_identity.dart';
import 'package:reference_app/src/sealed/sealed_letter_service.dart';

const int _count = int.fromEnvironment('SEALED_WARM_COUNT', defaultValue: 10);

int _ms(DateTime at) => at.toUtc().millisecondsSinceEpoch;

Future<T?> _until<T>(
  WidgetTester tester,
  T? Function() found,
  Duration budget,
) async {
  final deadline = DateTime.now().add(budget);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    final value = found();
    if (value != null) return value;
  }
  return found();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sealed letters, warm: written to opened, both ways', (
    tester,
  ) async {
    final booted = app.main();
    final service = await _until<SealedLetterService>(
      tester,
      () => sealedLetterService.value,
      const Duration(seconds: 90),
    );
    await tester.runAsync(() => booted.timeout(const Duration(seconds: 60)));
    final identity = appIdentity;
    if (service == null || identity == null) {
      print('SEALED_WARM ready=false service=${service != null}');
      fail('the app has no letter service');
    }
    final own = (await tester.runAsync(
      identity.installId,
    ))!.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final peers = (await tester.runAsync(identity.pinnedInstalls))!;
    expect(peers, isNotEmpty, reason: 'this install has pinned nobody');
    final peer = peers.first;
    print(
      'SEALED_WARM ready=true own=$own peer=$peer peers=${peers.length} '
      'count=$_count',
    );

    // The panel is on the Chat tab.
    await tester.tap(find.byIcon(Icons.chat_bubble));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('sealed-panel')), findsOneWidget);

    final spread = Random(7);
    var counted = 0;
    for (var i = 0; i <= _count; i++) {
      final text = 'warm $i at ${_ms(DateTime.now())} #rig-echo=$i';
      // Clicking Send moves the focus to the button and the field's input
      // connection closes with it (seen on the rig: the second text was
      // never typed). So the field is clicked before every text, as a
      // person would; and if typing still did not land, the text is put in
      // the field directly and the line says so.
      final compose = find.byKey(const Key('sealed-compose'));
      await tester.tap(compose);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(compose, text);
      await tester.pump(const Duration(milliseconds: 200));
      final field = tester.widget<TextField>(compose).controller;
      if (field != null && field.text != text) {
        print('SEALED_WARM note i=$i typing_did_not_land=true');
        field.text = text;
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.byKey(const Key('sealed-send')));
      final sent = await _until<SealedSent>(
        tester,
        () => service.outbox.value.where((s) => s.text == text).firstOrNull,
        const Duration(seconds: 10),
      );
      if (sent == null) {
        print('SEALED_WARM lost i=$i why=not_queued');
        continue;
      }
      final echo = await _until<SealedReceived>(
        tester,
        () => service.inbox.value
            .where(
              (r) =>
                  r.from == peer &&
                  (r.content.text ?? '').startsWith('rig-echo=$i '),
            )
            .firstOrNull,
        // The warm-up may find the phone cold; the counted ones may not.
        Duration(seconds: i == 0 ? 180 : 60),
      );
      final opened = RegExp(
        r'opened_ms=(\d+)',
      ).firstMatch(echo?.content.text ?? '');
      if (echo == null || opened == null) {
        print(
          'SEALED_WARM lost i=$i why=no_echo mac_sent_ms=${_ms(sent.at)} '
          'relay=${service.relay.value.name}',
        );
        continue;
      }
      if (i > 0) counted++;
      print(
        'SEALED_WARM pair i=$i counted=${i > 0} mac_sent_ms=${_ms(sent.at)} '
        'phone_open_ms=${opened.group(1)} phone_sent_ms=${_ms(echo.sentAt)} '
        'mac_open_ms=${_ms(echo.receivedAt)}',
      );
      // Not on the other side's beat: the next text is written a different
      // part of three seconds later each time.
      await tester.pump(Duration(milliseconds: 300 + spread.nextInt(2700)));
    }

    final requests = service.budget?.now;
    print(
      'SEALED_WARM requests since_start=${requests?.sinceStart} '
      'today=${requests?.usedToday} cap=${requests?.dailyCap} '
      'longest_ms=${requests?.longestOpen.inMilliseconds}',
    );
    print('SEALED_WARM done pairs=$counted/$_count');
    // Let the last receipt leave before the app goes off.
    await _until<bool>(tester, () => null, const Duration(seconds: 6));
    expect(counted, _count, reason: 'every counted text must come back');
  });
}
