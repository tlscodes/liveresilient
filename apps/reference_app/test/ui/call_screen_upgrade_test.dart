/// The upgraded live-call screen: real-stats gauge card, adaptive-ladder
/// display, voice-note banner, and the unchanged pinned contract (phase
/// labels, button types/labels, privacy line).
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/call_screen.dart';
import 'package:reference_app/src/ui/network_truth.dart';
import 'package:reference_app/src/ui/quality_gauge.dart';
import 'package:reference_app/src/ui/tokens.dart';

const String _bannerText =
    'Live voice degraded — voice-note mode keeps audio flowing';

Widget app(Widget home, {Brightness brightness = Brightness.light}) {
  return MaterialApp(
    theme: buildAppThemeData(brightness),
    home: Scaffold(body: home),
  );
}

void main() {
  testWidgets('gauge card appears in-call and updates from the stream', (
    tester,
  ) async {
    final readings = StreamController<CallQualityReading>();
    // NOT `addTearDown(readings.close)`: close()'s future only completes
    // once a listener receives the done event, and the idle-phase tests
    // never build the StreamBuilder — awaiting it would hang the run.
    addTearDown(() => unawaited(readings.close()));

    await tester.pumpWidget(
      app(
        CallScreen(
          phase: CallPhase.connected,
          quality: readings.stream,
          rung: OperatingRung.audioOnly,
        ),
      ),
    );

    // The card exists as soon as a call is live, dashes until real stats.
    expect(find.byType(QualityGauge), findsOneWidget);
    expect(find.byType(LadderRungIndicator), findsOneWidget);
    expect(find.text('audioOnly'), findsOneWidget);
    expect(find.text('120 ms'), findsNothing);

    readings.add(
      const CallQualityReading(
        at: Duration(seconds: 1),
        rttMs: 120,
        lossFraction: 0.02,
        bitrateBps: 32000,
      ),
    );
    await tester.pump(); // deliver the stream event
    await tester.pump(AppMotion.base); // finish the one-shot needle tween

    expect(find.text('120 ms'), findsOneWidget);
    expect(find.text('2.0% loss'), findsOneWidget);
  });

  testWidgets('no gauge card when idle, even with a stream provided', (
    tester,
  ) async {
    final readings = StreamController<CallQualityReading>();
    // NOT `addTearDown(readings.close)`: close()'s future only completes
    // once a listener receives the done event, and the idle-phase tests
    // never build the StreamBuilder — awaiting it would hang the run.
    addTearDown(() => unawaited(readings.close()));

    await tester.pumpWidget(
      app(
        CallScreen(
          phase: CallPhase.idle,
          quality: readings.stream,
          rung: OperatingRung.fullVideo,
        ),
      ),
    );

    expect(find.byType(QualityGauge), findsNothing);
    expect(find.byType(LadderRungIndicator), findsNothing);
  });

  testWidgets('no gauge card without a stream, even in-call', (tester) async {
    await tester.pumpWidget(
      app(const CallScreen(phase: CallPhase.connected)),
    );
    expect(find.byType(QualityGauge), findsNothing);
  });

  testWidgets('Call button still fires onCall in the upgraded layout', (
    tester,
  ) async {
    var called = false;
    final readings = StreamController<CallQualityReading>();
    // NOT `addTearDown(readings.close)`: close()'s future only completes
    // once a listener receives the done event, and the idle-phase tests
    // never build the StreamBuilder — awaiting it would hang the run.
    addTearDown(() => unawaited(readings.close()));

    await tester.pumpWidget(
      app(
        CallScreen(
          phase: CallPhase.idle,
          quality: readings.stream,
          onCall: () => called = true,
        ),
      ),
    );

    expect(find.widgetWithText(FilledButton, 'Call'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Call'));
    await tester.pump();
    expect(called, isTrue);
  });

  testWidgets('voice-note banner mirrors the real degraded mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        const CallScreen(
          phase: CallPhase.degraded,
          degradedMode: DegradedMode.voiceNotes,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(_bannerText), findsOneWidget);

    await tester.pumpWidget(
      app(
        const CallScreen(
          phase: CallPhase.degraded,
          degradedMode: DegradedMode.lowRateVoice,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(_bannerText), findsNothing);
  });

  testWidgets('hero color is deterministic for a call id', (tester) async {
    // Stable across runs/platforms — goldens depend on this.
    final a = heroColorFor('AbC-123_xyz', Brightness.light);
    final b = heroColorFor('AbC-123_xyz', Brightness.light);
    final c = heroColorFor('different-id', Brightness.light);
    expect(a, b);
    expect(a, isNot(c));
  });

  group('goldens', () {
    Future<void> pumpCallScreen(
      WidgetTester tester, {
      required Brightness brightness,
      bool rtl = false,
    }) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final readings = StreamController<CallQualityReading>();
      // NOT `addTearDown(readings.close)`: close()'s future only completes
    // once a listener receives the done event, and the idle-phase tests
    // never build the StreamBuilder — awaiting it would hang the run.
    addTearDown(() => unawaited(readings.close()));

      final home = Scaffold(
        body: CallScreen(
          phase: CallPhase.connected,
          callId: 'AbC-123_xyz',
          quality: readings.stream,
          rung: OperatingRung.audioOnly,
          audioOnly: true,
          onHangUp: () {},
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppThemeData(brightness),
          home: rtl
              ? Directionality(textDirection: TextDirection.rtl, child: home)
              : home,
        ),
      );

      readings.add(
        const CallQualityReading(
          at: Duration(seconds: 2),
          rttMs: 140,
          lossFraction: 0.02,
          bitrateBps: 24000,
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();
    }

    testWidgets('call screen light', (tester) async {
      await pumpCallScreen(tester, brightness: Brightness.light);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/call_screen_light.png'),
      );
    });

    testWidgets('call screen dark', (tester) async {
      await pumpCallScreen(tester, brightness: Brightness.dark);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/call_screen_dark.png'),
      );
    });

    testWidgets('call screen rtl', (tester) async {
      await pumpCallScreen(tester, brightness: Brightness.light, rtl: true);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/call_screen_rtl.png'),
      );
    });
  });
}
