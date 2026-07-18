// App-level smoke test: the home screen launches on the Call tab and
// switches to Chat via the NavigationBar, with no server/network/device
// required — every state is driven by the in-app demo controllers.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reference_app/main.dart';

void main() {
  testWidgets('launches on the Call tab, idle, ready to call', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('Idle'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Call'), findsOneWidget);
  });

  testWidgets('NavigationBar switches to the Chat tab', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    await tester.tap(find.widgetWithText(NavigationDestination, 'Chat'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    expect(find.bySemanticsLabel('Send message'), findsOneWidget);
  });

  testWidgets('tapping Call moves the phase to Connecting', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Call'));
    await tester.pump();

    expect(find.text('Connecting…'), findsOneWidget);

    // Let the simulated connect/negotiate timers finish so no pending timer
    // outlives the test.
    await tester.pump(const Duration(seconds: 1));
  });
}
