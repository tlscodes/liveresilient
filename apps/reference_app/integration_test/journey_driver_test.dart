/// The near side of the app journey: the reference app ITSELF on the Mac,
/// driven through its own screens, joining the phone's call by key and
/// reporting what the live monitor bar shows.
///
/// Orchestrated by tools/t2/journey_run.sh: this test writes READY once the
/// app is on screen, waits for GO (a file whose content is the call key,
/// written when the phone's stack is up), joins through the "Join with key"
/// dialog, samples the gauge for the hold period, and prints one
/// `JOURNEY_APP` line per event plus a `summary` line the orchestrator reads.
///
/// Defines:
///   JOURNEY_READY_FILE   path this test creates when the app is on screen
///   JOURNEY_GO_FILE      path the orchestrator writes the key into
///   JOURNEY_HOLD_S       seconds to sample the gauge once connected (45)
///   E2E_CONNECT_BUDGET_S seconds to wait for Connected (300)
@Timeout(Duration(minutes: 15))
library;

// Evidence lines are deliberately printed to the test log.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:reference_app/main.dart';
import 'package:reference_app/src/demo_feeds.dart' show demoQualitySourceLabel;
import 'package:reference_app/src/live_quality_feed.dart'
    show liveQualitySourceLabel;

const String readyFile = String.fromEnvironment('JOURNEY_READY_FILE');
const String goFile = String.fromEnvironment('JOURNEY_GO_FILE');
const int holdS = int.fromEnvironment('JOURNEY_HOLD_S', defaultValue: 45);
const int connectBudgetS = int.fromEnvironment(
  'E2E_CONNECT_BUDGET_S',
  defaultValue: 300,
);

final RegExp _rttShape = RegExp(r'^(\d+) ms$');
final RegExp _lossShape = RegExp(r'^([\d.]+)% loss$');
final RegExp _attemptShape = RegExp(r'^Attempt (\d+)$');

Iterable<String> _visibleTexts() => find
    .byType(Text)
    .evaluate()
    .map((element) => (element.widget as Text).data)
    .whereType<String>();

Future<T?> _pumpUntil<T>(
  WidgetTester tester,
  T? Function() found, {
  required Duration budget,
  Duration step = const Duration(milliseconds: 250),
}) async {
  final deadline = DateTime.now().add(budget);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(step);
    final value = found();
    if (value != null) return value;
  }
  return found();
}

String _phaseOnScreen() {
  const phases = [
    'Idle',
    'Connecting…',
    'Negotiating…',
    'Connected',
    'Connected — survival mode',
    'Reconnecting…',
    'Ending call…',
    'Call ended',
    'Call failed',
  ];
  for (final text in _visibleTexts()) {
    if (phases.contains(text)) return text;
  }
  return '?';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('journey driver: the app joins the phone\'s call by key and '
      'reports its monitor bar', (tester) async {
    expect(readyFile, isNotEmpty, reason: 'JOURNEY_READY_FILE is required');
    expect(goFile, isNotEmpty, reason: 'JOURNEY_GO_FILE is required');

    await tester.pumpWidget(const MyApp());
    await tester.pump();
    expect(find.text('Idle'), findsOneWidget);
    File(readyFile).writeAsStringSync('ready\n');
    print('JOURNEY_APP ready hold=${holdS}s budget=${connectBudgetS}s');

    // Wait for the key: the orchestrator writes it once the phone's stack
    // has reported connecting, so the app joins inside the phone's watchdog.
    final key = await _pumpUntil<String>(
      tester,
      () {
        final file = File(goFile);
        if (!file.existsSync()) return null;
        final text = file.readAsStringSync().trim();
        return text.isEmpty ? null : text;
      },
      budget: const Duration(minutes: 10),
      step: const Duration(milliseconds: 500),
    );
    expect(key, isNotNull, reason: 'GO file never carried a key');
    print('JOURNEY_APP go key=$key');

    final joinButton = find.widgetWithText(OutlinedButton, 'Join with key');
    await tester.ensureVisible(joinButton);
    await tester.tap(joinButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), key!);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(FilledButton, 'Join'));
    await tester.pump(const Duration(milliseconds: 300));
    final joinedAt = DateTime.now();
    print('JOURNEY_APP joined phase=${_phaseOnScreen()}');

    var lastSeen = '';
    final outcome = await _pumpUntil<String>(tester, () {
      final phase = _phaseOnScreen();
      // Every phase change while connecting is evidence: a receiver that
      // never gets an offer walks connecting -> reconnecting (attempt n) ->
      // failed, and the attempt count says how long it waited.
      final attempt = _visibleTexts()
          .map((t) => _attemptShape.firstMatch(t)?.group(1))
          .whereType<String>()
          .join(',');
      final seen = '$phase/$attempt';
      if (seen != lastSeen) {
        lastSeen = seen;
        print(
          'JOURNEY_APP phase t=${DateTime.now().difference(joinedAt).inSeconds}s '
          '$phase attempt=${attempt.isEmpty ? '-' : attempt}',
        );
      }
      if (phase == 'Connected' || phase == 'Connected — survival mode') {
        return phase;
      }
      if (phase == 'Call failed' || phase == 'Call ended') return phase;
      return null;
    }, budget: Duration(seconds: connectBudgetS));
    final connectMs = DateTime.now().difference(joinedAt).inMilliseconds;
    // Long texts included on purpose: the failure detail under a failed call
    // is the controller's own exception, and it is the evidence.
    final visible = _visibleTexts().where((t) => t.length < 400).join(' | ');
    print(
      'JOURNEY_APP outcome=${(outcome ?? 'timeout').replaceAll(' ', '_')} connect_ms=$connectMs '
      'screen=$visible',
    );

    var samples = 0;
    int? rttMin;
    int? rttMax;
    double lossMax = 0;
    var reconnects = 0;
    var attemptMax = 0;
    var chipLive = 0;
    var chipDemo = 0;
    var lastPhase = '';
    var endedOnScreen = outcome == 'Call failed' || outcome == 'Call ended';
    if (outcome == 'Connected' || outcome == 'Connected — survival mode') {
      final holdUntil = DateTime.now().add(Duration(seconds: holdS));
      while (DateTime.now().isBefore(holdUntil)) {
        await tester.pump(const Duration(milliseconds: 500));
        final phase = _phaseOnScreen();
        int? rtt;
        double? loss;
        String? chip;
        int? attempt;
        for (final text in _visibleTexts()) {
          final r = _rttShape.firstMatch(text);
          if (r != null) rtt = int.parse(r.group(1)!);
          final l = _lossShape.firstMatch(text);
          if (l != null) loss = double.parse(l.group(1)!);
          final a = _attemptShape.firstMatch(text);
          if (a != null) attempt = int.parse(a.group(1)!);
          if (text == liveQualitySourceLabel) chip = 'live';
          if (text == demoQualitySourceLabel) chip = 'demo';
        }
        samples++;
        if (rtt != null) {
          rttMin = rttMin == null ? rtt : (rtt < rttMin ? rtt : rttMin);
          rttMax = rttMax == null ? rtt : (rtt > rttMax ? rtt : rttMax);
        }
        if (loss != null && loss > lossMax) lossMax = loss;
        if (attempt != null && attempt > attemptMax) attemptMax = attempt;
        if (chip == 'live') chipLive++;
        if (chip == 'demo') chipDemo++;
        if (phase == 'Reconnecting…' && lastPhase != 'Reconnecting…') {
          reconnects++;
        }
        lastPhase = phase;
        print(
          'JOURNEY_APP sample t=${DateTime.now().difference(joinedAt).inSeconds}s '
          'phase=$phase rtt=${rtt ?? '-'} loss=${loss ?? '-'} '
          'chip=${chip ?? 'none'} attempt=${attempt ?? '-'}',
        );
        if (phase == 'Call ended' || phase == 'Call failed') {
          endedOnScreen = true;
          break;
        }
      }
    }

    if (!endedOnScreen) {
      final hangUp = find.widgetWithText(FilledButton, 'Hang up');
      if (hangUp.evaluate().isNotEmpty) {
        await tester.ensureVisible(hangUp);
        await tester.tap(hangUp);
      }
      await _pumpUntil<bool>(tester, () {
        final phase = _phaseOnScreen();
        return (phase == 'Call ended' || phase == 'Call failed') ? true : null;
      }, budget: const Duration(seconds: 30));
    }
    final endTexts = _visibleTexts().where((t) => t.length < 70).join(' | ');
    print(
      'JOURNEY_APP summary outcome=${(outcome ?? 'timeout').replaceAll(' ', '_')} '
      'connect_ms=$connectMs samples=$samples rtt_min=${rttMin ?? '-'} '
      'rtt_max=${rttMax ?? '-'} loss_max=$lossMax chip_live=$chipLive '
      'chip_demo=$chipDemo reconnects=$reconnects attempt_max=$attemptMax '
      'end=${_phaseOnScreen().replaceAll(' ', '_')} screen=$endTexts',
    );
    await tester.pump(const Duration(seconds: 1));
  });
}
