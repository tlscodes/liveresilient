// App-level smoke test: the home screen launches on the Call tab and
// switches to Chat via the NavigationBar, with no server/network/device
// required. Chat is driven by the in-app demo controller; the call tab is
// driven by the REAL session controller, given a fake opener here so the tap
// exercises the production wiring without a relay.

import 'package:call_core/call_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reference_app/main.dart';
import 'package:reference_app/src/call_session.dart';

/// Answers like a relay that is not running — null, the documented contract
/// of `devConnectToLocalRelay` — but only after a timer, so the phase the
/// screen shows on the very next frame is the one the controller set
/// synchronously, not the outcome. Top-level so `const MyApp(...)` can name
/// it.
Future<CallSessionHandle?> relayDownAfterATick({
  required String callId,
  required CallRole role,
}) async {
  await Future<void>.delayed(const Duration(milliseconds: 250));
  return null;
}

void main() {
  testWidgets('launches on the Call tab, idle, ready to call', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('Idle'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Call'), findsOneWidget);
  });

  // AMENDED with the 2026-08-10 UI/UX phase (declared, not silent): the Chat
  // tab now lands on the conversations LIST (one of the approved five
  // screens); the compose field lives in the thread pushed from a
  // conversation. The smoke journey still ends at the same truth — a
  // reachable composer — via the new information architecture.
  testWidgets('NavigationBar switches to Chat: list, then thread', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    await tester.tap(find.widgetWithText(NavigationDestination, 'Chat'));
    await tester.pumpAndSettle();

    // Conversations list first: the live loopback thread is anchored there.
    expect(find.text('Loopback peer'), findsOneWidget);
    await tester.tap(find.text('Loopback peer'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    expect(find.bySemanticsLabel('Send message'), findsOneWidget);
  });

  testWidgets('tapping Call moves the phase to Connecting, then reports the '
      'relay being down as a signaling failure', (tester) async {
    await tester.pumpWidget(const MyApp(openSession: relayDownAfterATick));
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Call'));
    await tester.pump();

    // Acknowledged on the next frame, before the opener has answered.
    expect(find.text('Connecting…'), findsOneWidget);

    // The opener answers: no session. The screen says so, in the words of
    // the phase and the reason, and is ready to call again.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Call failed'), findsOneWidget);
    expect(find.text('Signaling failure'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Call'), findsOneWidget);
  });
}
