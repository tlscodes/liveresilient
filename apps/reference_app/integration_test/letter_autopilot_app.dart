// The emergency letter on the REAL app, driven on the phone with no debugger
// attached: this entry point boots lib/main.dart's MyApp, then taps through
// it the way a person would — Chats → "Letter through the door" → one typed
// line → Send — waits for the verdict, and shows the Chats row and the
// thread. It is a plain profile-mode app (installed and launched with
// devicectl, like journey_peer_app.dart), so nothing needs Xcode's debug
// tunnel. Every step is a `LETTER_APP` line POSTed to the journey hub's
// /report (phone_events.jsonl) and three PNG screenshots of the live widget
// tree go to /blob, so the evidence lands on the Mac.
//
//   flutter build ios --profile -t integration_test/letter_autopilot_app.dart \
//     --dart-define=JOURNEY_HUB_URL=http://192.168.2.1:8765 \
//     --dart-define=DNS_VALVE_DOMAIN=valve.test \
//     --dart-define=DNS_VALVE_RESOLVERS=192.168.2.1:5300
//   xcrun devicectl device install app --device <udid> build/ios/iphoneos/Runner.app
//   xcrun devicectl device process launch --terminate-existing --device <udid> com.tlscodes.referenceApp
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:messaging/messaging.dart' show contentSha256Hex;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart' show LiveWidgetController, find;
import 'package:reference_app/main.dart' as app;
import 'package:reference_app/src/intelligence/device_bindings.dart';
import 'package:reference_app/src/intelligence/intelligence_boot.dart';
import 'package:reference_app/src/ui/letter_sheet.dart';

const String hubUrl = String.fromEnvironment(
  'JOURNEY_HUB_URL',
  defaultValue: 'http://192.168.2.1:8765',
);
const String runId = String.fromEnvironment(
  'LETTER_RUN',
  defaultValue: 'app-letter',
);

final GlobalKey shotKey = GlobalKey();
final HttpClient http = HttpClient()
  ..connectionTimeout = const Duration(seconds: 3);

Future<void> report(
  String line, [
  Map<String, Object?> extra = const {},
]) async {
  debugPrint('LETTER_APP $line');
  final body = jsonEncode(<String, Object?>{
    'event': 'app_letter',
    'run': runId,
    'at': DateTime.now().toUtc().toIso8601String(),
    'line': line,
    ...extra,
  });
  try {
    final req = await http
        .postUrl(Uri.parse('$hubUrl/report'))
        .timeout(const Duration(seconds: 5));
    req.headers.contentType = ContentType.json;
    req.write(body);
    final res = await req.close().timeout(const Duration(seconds: 5));
    await res.drain<void>();
  } on Object catch (error) {
    debugPrint('LETTER_APP report failed: $error');
  }
}

Future<void> screenshot(String id) async {
  try {
    final boundary =
        shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.5);
    final png = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    final sha = contentSha256Hex(png);
    final url = Uri.parse(
      '$hubUrl/blob?run=${Uri.encodeQueryComponent(runId)}'
      '&kind=screenshot&id=$id&sha256=$sha',
    );
    final req = await http.postUrl(url).timeout(const Duration(seconds: 5));
    req.headers.contentType = ContentType('image', 'png');
    req.add(png);
    final res = await req.close().timeout(const Duration(seconds: 20));
    await res.drain<void>();
    await report('screenshot $id ${png.length} B http=${res.statusCode}');
  } on Object catch (error) {
    await report('screenshot $id failed: $error');
  }
}

Future<void> settle(Duration total) async {
  final until = DateTime.now().add(total);
  while (DateTime.now().isBefore(until)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

String textOf(LiveWidgetController c, Key key) {
  final f = find.byKey(key);
  if (f.evaluate().isEmpty) return '<absent>';
  return c.widget<Text>(f).data ?? '<no data>';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final intelligence = await bootIntelligence(
    localLinkLane: buildLocalLinkLane(),
    storageDirFactory: buildStorageDirectory(),
  );
  runApp(
    RepaintBoundary(
      key: shotKey,
      child: app.MyApp(intelligence: intelligence),
    ),
  );
  unawaited(_drive());
}

Future<void> _drive() async {
  final c = LiveWidgetController(WidgetsBinding.instance);
  await settle(const Duration(seconds: 4));
  await report('app booted (real MyApp), run=$runId');

  await c.tap(find.byIcon(Icons.chat_bubble));
  await settle(const Duration(seconds: 2));
  final letterAction = find.byKey(const Key('conversations-letter'));
  if (letterAction.evaluate().isEmpty) {
    await report('FAIL: no Letter action on the Chats screen');
    return;
  }
  await report('Chats tab open, Letter action present');

  await c.tap(letterAction);
  await settle(const Duration(seconds: 4));
  final sheetFinder = find.byType(LetterSheet);
  if (sheetFinder.evaluate().isEmpty) {
    await report('FAIL: the letter sheet did not open');
    return;
  }
  await report(
    'sheet open · banner after probe: '
    '${textOf(c, const Key('journey-peer-letter-state-label'))} · '
    '${textOf(c, const Key('journey-peer-letter-state-detail'))}',
  );

  final stamp = DateTime.now().toUtc().toIso8601String();
  final text =
      'from the app on the phone, $stamp: Letter tapped in Chats, this went '
      'out the DNS door.';
  // A person types into the field; here the composer's draft is set the
  // same way the field's onChanged would set it.
  c.widget<LetterSheet>(sheetFinder).composer.draft.value = text;
  await c.tap(find.byKey(const Key('letter-sheet-send')));
  await report('Send tapped · ${text.length} B', {'text': text});

  final deadline = DateTime.now().add(const Duration(seconds: 200));
  var verdict = '<none>';
  while (DateTime.now().isBefore(deadline)) {
    await settle(const Duration(seconds: 1));
    for (final state in ['arrived', 'notDelivered']) {
      if (find
          .byKey(Key('journey-peer-letter-state-$state'))
          .evaluate()
          .isNotEmpty) {
        verdict = state;
      }
    }
    if (verdict != '<none>') break;
  }
  final label = textOf(c, const Key('journey-peer-letter-state-label'));
  final detail = textOf(c, const Key('journey-peer-letter-state-detail'));
  await report('verdict=$verdict · $label · $detail', {
    'verdict': verdict,
    'label': label,
    'detail': detail,
  });
  await screenshot('1-sheet-verdict');
  if (verdict != 'arrived') {
    await report('FAIL: the letter did not arrive');
    return;
  }

  Navigator.of(c.element(sheetFinder)).pop();
  await settle(const Duration(seconds: 2));
  final row = find.byKey(const ValueKey('conversation-tile-letter'));
  final rowText = find.text(text).evaluate().isNotEmpty;
  await report(
    'Chats row: ${row.evaluate().isEmpty ? 'ABSENT' : 'present'} · '
    'shows the letter text: $rowText',
  );
  await screenshot('2-chats-row');
  if (row.evaluate().isEmpty) return;

  await c.tap(row);
  await settle(const Duration(seconds: 2));
  final bubble = find.byKey(const ValueKey('letter-bubble-0'));
  await report(
    'thread: bubble ${bubble.evaluate().isEmpty ? 'ABSENT' : 'present'} · '
    'shows the letter text: ${find.text(text).evaluate().isNotEmpty} · '
    'lanes: ${textOf(c, const Key('letter-thread-lanes'))}',
  );
  await screenshot('3-thread');
  await report('DONE');
}
