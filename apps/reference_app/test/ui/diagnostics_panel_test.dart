@Tags(['golden'])
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/ui/diagnostics_panel.dart';
import 'package:reference_app/src/ui/network_truth.dart';
import 'package:reference_app/src/ui/tokens.dart';

/// Deterministic 40-reading history (no Random) shared by tests and goldens.
QualityHistory seededHistory({int count = 40}) {
  final history = QualityHistory();
  for (var i = 0; i < count; i++) {
    history.add(
      CallQualityReading(
        at: Duration(seconds: i),
        rttMs: 90 + (i * 37) % 140,
        lossFraction: ((i * 13) % 80) / 1000,
        bitrateBps: 24000 + (i * 911) % 20000,
      ),
    );
  }
  return history;
}

Widget wrap(Widget child, {Brightness brightness = Brightness.light}) {
  return MaterialApp(
    theme: buildAppThemeData(brightness),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsetsDirectional.all(AppSpacing.s16),
        child: child,
      ),
    ),
  );
}

void main() {
  testWidgets('seed renders three populated tiles and stream updates them', (
    tester,
  ) async {
    final controller = StreamController<CallQualityReading>();
    addTearDown(controller.close);
    final seed = QualityHistory()
      ..add(
        const CallQualityReading(
          at: Duration(seconds: 1),
          rttMs: 120,
          lossFraction: 0.02,
          bitrateBps: 32000,
        ),
      );

    await tester.pumpWidget(
      wrap(DiagnosticsPanel(readings: controller.stream, seed: seed)),
    );
    expect(find.text('120'), findsOneWidget); // RTT ms
    expect(find.text('2.0'), findsOneWidget); // loss %
    expect(find.text('32'), findsOneWidget); // rate kbps

    controller.add(
      const CallQualityReading(
        at: Duration(seconds: 2),
        rttMs: 250,
        lossFraction: 0.05,
        bitrateBps: 48000,
      ),
    );
    await tester.pump(); // deliver the stream event
    await tester.pump(); // frame after setState

    expect(find.text('250'), findsOneWidget);
    expect(find.text('5.0'), findsOneWidget);
    expect(find.text('48'), findsOneWidget);
  });

  testWidgets('dispose cancels the stream subscription', (tester) async {
    final controller = StreamController<CallQualityReading>();
    addTearDown(controller.close);

    await tester.pumpWidget(
      wrap(DiagnosticsPanel(readings: controller.stream)),
    );
    expect(controller.hasListener, isTrue);

    await tester.pumpWidget(wrap(const SizedBox()));
    expect(controller.hasListener, isFalse);
  });

  testWidgets('loss 0.2 paints the loss tile with the poor band color', (
    tester,
  ) async {
    final seed = QualityHistory()
      ..add(
        const CallQualityReading(
          at: Duration(seconds: 1),
          rttMs: 100,
          lossFraction: 0.2,
          bitrateBps: 32000,
        ),
      );

    await tester.pumpWidget(wrap(DiagnosticsPanel(seed: seed)));

    final tokens = buildAppThemeData(Brightness.light).extension<AppTokens>()!;
    final lossText = tester.widget<Text>(find.text('20.0'));
    expect(lossText.style?.color, tokens.gaugePoor);
  });

  testWidgets('absent data renders honest dashes, no invented zeros', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const DiagnosticsPanel()));
    expect(find.text('—'), findsNWidgets(3));
    expect(find.text('0'), findsNothing);
    expect(find.text('0.0'), findsNothing);
  });

  testWidgets('sourceLabel chip text appears', (tester) async {
    await tester.pumpWidget(
      wrap(const DiagnosticsPanel(sourceLabel: 'loopback demo')),
    );
    expect(find.text('loopback demo'), findsOneWidget);
  });

  testWidgets('golden: diagnostics light', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(DiagnosticsPanel(seed: seededHistory())));
    await expectLater(
      find.byType(DiagnosticsPanel),
      matchesGoldenFile('goldens/diagnostics_light.png'),
    );
  });

  testWidgets('golden: diagnostics dark', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      wrap(
        DiagnosticsPanel(seed: seededHistory()),
        brightness: Brightness.dark,
      ),
    );
    await expectLater(
      find.byType(DiagnosticsPanel),
      matchesGoldenFile('goldens/diagnostics_dark.png'),
    );
  });
}
