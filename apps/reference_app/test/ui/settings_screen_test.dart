@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/ui/network_truth.dart';
import 'package:reference_app/src/ui/settings_screen.dart';
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

Widget app({
  ThemeMode themeMode = ThemeMode.system,
  ValueChanged<ThemeMode>? onThemeMode,
  Brightness brightness = Brightness.light,
  bool rtl = false,
  QualityHistory? seed,
}) {
  final screen = SettingsScreen(
    themeMode: themeMode,
    onThemeMode: onThemeMode ?? (_) {},
    diagnosticsSeed: seed,
  );
  return MaterialApp(
    theme: buildAppThemeData(brightness),
    home: rtl
        ? Directionality(textDirection: TextDirection.rtl, child: screen)
        : screen,
  );
}

void main() {
  testWidgets('renders the three grouped sections', (tester) async {
    await tester.pumpWidget(app(seed: seededHistory()));
    expect(find.text('APPEARANCE'), findsOneWidget);
    expect(find.text('NETWORK'), findsOneWidget);
    expect(find.text('ABOUT'), findsOneWidget);
    expect(find.text('Network diagnostics'), findsOneWidget);
    expect(find.text('loopback demo'), findsOneWidget);
    expect(find.text('Version'), findsOneWidget);
    expect(find.text('dev'), findsOneWidget);
    expect(
      find.text('E2E media · no telemetry without opt-in'),
      findsOneWidget,
    );
  });

  testWidgets('SegmentedButton change calls onThemeMode with the new mode', (
    tester,
  ) async {
    ThemeMode? received;
    await tester.pumpWidget(
      app(themeMode: ThemeMode.system, onThemeMode: (m) => received = m),
    );

    await tester.tap(find.text('Dark'));
    await tester.pump();
    expect(received, ThemeMode.dark);

    await tester.tap(find.text('Light'));
    await tester.pump();
    expect(received, ThemeMode.light);
  });

  testWidgets('golden: settings light', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(app(seed: seededHistory()));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_light.png'),
    );
  });

  testWidgets('golden: settings dark', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      app(seed: seededHistory(), brightness: Brightness.dark),
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_dark.png'),
    );
  });

  testWidgets('golden: settings rtl', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(app(seed: seededHistory(), rtl: true));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_rtl.png'),
    );
  });
}
