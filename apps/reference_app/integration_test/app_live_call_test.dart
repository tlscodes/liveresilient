/// The reference app places a REAL call from its own call tab.
///
/// What this proves, end to end and on the real stack: the Call button opens
/// a session through the production opener (dev relay at wss://localhost:4443,
/// real `SignalingClient`, real `flutter_webrtc` engine); the key the screen
/// shows is the relay session id, because a second, headless peer joins it as
/// the receiver and BOTH reach connected; the gauge is labelled "live path
/// stats" and never "synthetic demo profile"; the numbers it charts are the
/// path's own (a loopback round-trip, which the scripted profile — whose
/// floor is 40 ms — cannot produce); and hanging up from the screen ends the
/// call on the far side with "remote hangup".
///
/// Every number is printed to the log as evidence. The relay is bound
/// in-process on the port the app's dev entry point dials, so the run needs
/// no second terminal:
///
///   cd apps/reference_app && flutter test integration_test/app_live_call_test.dart -d macos
///
/// The library-level timeout mirrors the other survival gates: the default
/// 5-minute cap is shorter than a first-run microphone prompt plus connect.
@Timeout(Duration(minutes: 10))
library;

// Evidence numbers are deliberately printed to the test log.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:call_core/call_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:reference_app/main.dart';
import 'package:reference_app/src/demo_feeds.dart' show demoQualitySourceLabel;
import 'package:reference_app/src/live_quality_feed.dart'
    show liveQualitySourceLabel;
import 'package:signaling_server/signaling_server.dart';

import 'support/e2e_dev_tls.dart';
import 'support/e2e_support.dart';

/// The port `devConnectToLocalRelay` dials (main.dart), and the one the
/// public-STUN fallback manifest names. A relay anywhere else is not the one
/// the app would reach, so this test binds exactly here.
const int devRelayPort = 4443;

final RegExp _callKeyShape = RegExp(r'^[A-Za-z0-9_-]{22}$');
final RegExp _rttShape = RegExp(r'^(\d+) ms$');

/// Every visible [Text] widget's data.
Iterable<String> _visibleTexts() => find
    .byType(Text)
    .evaluate()
    .map((element) => (element.widget as Text).data)
    .whereType<String>();

/// Pumps until [found] returns non-null or [budget] elapses.
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the call tab places a real call: a headless peer joins the key shown on '
    'screen, both connect, the gauge is labelled live and charts the path\'s '
    'own numbers, and hanging up ends the call on both sides',
    (tester) async {
      final security = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(e2eDevCertificatePem))
        ..usePrivateKeyBytes(utf8.encode(e2eDevPrivateKeyPem));
      final relay = await SignalingRelayServer.bind(
        security: security,
        port: devRelayPort,
        abuseControls: e2eAbuseControls(),
      );
      addTearDown(relay.close);
      final endpoint = Uri.parse('wss://localhost:${relay.port}/');
      print('app-e2e relay: $endpoint (in-process, dev certificate)');

      // Probe the microphone BEFORE the app dials, so a first-run permission
      // prompt is answered outside the connect budget.
      final mode = await resolveMediaMode();

      await tester.pumpWidget(const MyApp());
      await tester.pump();
      expect(find.text('Idle'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Call'));
      await tester.pump();
      // On the real stack the opener resolves inside this same pump, so the
      // phase may already be past "Connecting…" (the synchronous acknowledge
      // is pinned by the unit test); what matters here is that the tap left
      // idle for a real session.
      expect(find.text('Idle'), findsNothing);

      // The key on screen IS the relay session id; the far side joins it.
      // The key card renders it as a SelectableText (copyable), not a Text.
      final key = await _pumpUntil<String>(tester, () {
        for (final element in find.byType(SelectableText).evaluate()) {
          final text = (element.widget as SelectableText).data;
          if (text != null && _callKeyShape.hasMatch(text)) return text;
        }
        return null;
      }, budget: const Duration(seconds: 10));
      expect(
        key,
        isNotNull,
        reason:
            'the call key never appeared on screen; screen shows '
            '${_visibleTexts().where((t) => t.length < 60).join(' | ')}',
      );
      print('app-e2e app: call key on screen = $key');

      final peer = E2eCallStack.build(
        endpoint: endpoint,
        callId: key!,
        role: CallRole.receiver,
        mode: mode,
      );
      addTearDown(peer.dispose);
      unawaited(peer.controller.start());

      const connectBudget = Duration(seconds: 60);
      final connectedAt = Stopwatch()..start();
      final appConnected = await _pumpUntil<bool>(tester, () {
        if (find.text('Connected').evaluate().isNotEmpty) return true;
        if (find.text('Call failed').evaluate().isNotEmpty) return false;
        return null;
      }, budget: connectBudget);
      expect(
        appConnected,
        isTrue,
        reason:
            'app never reached connected; screen shows '
            '${_visibleTexts().where((t) => t.length < 60).join(' | ')}',
      );
      final peerState = await peer.waitForConnected(timeout: connectBudget);
      expect(peerState.phase, CallPhase.connected);
      print(
        'app-e2e connected: both sides in ${connectedAt.elapsedMilliseconds} ms '
        '(media mode: ${mode.name})',
      );

      // The gauge names its source, and it is the live one.
      expect(find.text(liveQualitySourceLabel), findsOneWidget);
      expect(find.text(demoQualitySourceLabel), findsNothing);

      // The charted round-trip is the path's own. The scripted profile never
      // reads below 40 ms; a loopback path reads a few ms at most. Every
      // sample is printed, and every sample must be a loopback figure.
      final samples = <int>[];
      final sampleUntil = DateTime.now().add(const Duration(seconds: 12));
      while (DateTime.now().isBefore(sampleUntil)) {
        await tester.pump(const Duration(milliseconds: 500));
        for (final text in _visibleTexts()) {
          final match = _rttShape.firstMatch(text);
          if (match != null) samples.add(int.parse(match.group(1)!));
        }
      }
      print('app-e2e gauge rtt samples (ms): $samples');
      expect(
        samples,
        isNotEmpty,
        reason: 'the gauge never charted a round-trip while connected',
      );
      expect(
        samples.every((rtt) => rtt < 40),
        isTrue,
        reason:
            'a round-trip at or above the scripted profile\'s floor (40 ms) '
            'on a loopback path: $samples',
      );

      // Hang up from the screen: the far side learns it as a remote hangup.
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Hang up'));
      await tester.tap(find.widgetWithText(FilledButton, 'Hang up'));
      final ended = await _pumpUntil<bool>(
        tester,
        () => find.text('Call ended').evaluate().isNotEmpty ? true : null,
        budget: const Duration(seconds: 20),
      );
      expect(ended, isTrue, reason: 'the screen never showed "Call ended"');
      expect(find.text('You hung up'), findsOneWidget);
      expect(find.text(liveQualitySourceLabel), findsNothing);

      final peerDone = await peer.controller.done.timeout(
        const Duration(seconds: 20),
      );
      print(
        'app-e2e peer ended: phase=${peerDone.phase.name} '
        'reason=${peerDone.endReason?.name}',
      );
      expect(peerDone.endReason, CallEndReason.remoteHangup);

      // Ready for the next call, on a fresh key.
      expect(find.widgetWithText(FilledButton, 'Call'), findsOneWidget);
    },
  );
}
