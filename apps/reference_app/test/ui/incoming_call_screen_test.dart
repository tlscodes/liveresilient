@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/ui/incoming_call_screen.dart';
import 'package:reference_app/src/ui/tokens.dart';

Widget app({
  String callerName = 'Sara Ahmadi',
  String? callId,
  bool audioOnly = false,
  VoidCallback? onAccept,
  VoidCallback? onDecline,
  Brightness brightness = Brightness.light,
  bool rtl = false,
}) {
  final screen = IncomingCallScreen(
    callerName: callerName,
    callId: callId,
    audioOnly: audioOnly,
    onAccept: onAccept ?? () {},
    onDecline: onDecline ?? () {},
  );
  return MaterialApp(
    theme: buildAppThemeData(brightness),
    home: rtl
        ? Directionality(textDirection: TextDirection.rtl, child: screen)
        : screen,
  );
}

void main() {
  testWidgets('renders name, subtitle, both actions — and settles '
      '(no ambient timers under flutter test)', (tester) async {
    // The whole point of AppMotion.ambientEnabled: with it false, only the
    // one-shot nudge runs, so pumpAndSettle terminates.
    expect(AppMotion.ambientEnabled, isFalse);

    await tester.pumpWidget(app(callId: 'deadbeefcafef00d'));
    await tester.pumpAndSettle();

    expect(find.text('Sara Ahmadi'), findsOneWidget);
    expect(find.text('Incoming call · video'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNWidgets(2));
    expect(find.byIcon(Icons.call), findsOneWidget);
    expect(find.byIcon(Icons.call_end), findsOneWidget);
  });

  testWidgets('tap accept / decline invokes exactly the right callback once', (
    tester,
  ) async {
    var accepts = 0;
    var declines = 0;
    await tester.pumpWidget(
      app(onAccept: () => accepts++, onDecline: () => declines++),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.call));
    await tester.pump();
    expect(accepts, 1);
    expect(declines, 0);

    await tester.tap(find.byIcon(Icons.call_end));
    await tester.pump();
    expect(accepts, 1);
    expect(declines, 1);
  });

  testWidgets('call id chip shows exactly 8 chars + ellipsis, only when '
      'callId is given', (tester) async {
    await tester.pumpWidget(app(callId: 'deadbeefcafef00d'));
    await tester.pumpAndSettle();
    expect(find.text('deadbeef…'), findsOneWidget);
    expect(find.byTooltip('Secure call id'), findsOneWidget);

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byTooltip('Secure call id'), findsNothing);
    expect(find.textContaining('…'), findsNothing);
  });

  testWidgets('audioOnly toggles the voice/video suffix', (tester) async {
    await tester.pumpWidget(app(audioOnly: true));
    await tester.pumpAndSettle();
    expect(find.text('Incoming call · voice'), findsOneWidget);
    expect(find.text('Incoming call · video'), findsNothing);
  });

  testWidgets('semantics labels present on both actions', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Accept call'), findsOneWidget);
    expect(find.bySemanticsLabel('Decline call'), findsOneWidget);

    handle.dispose();
  });

  testWidgets('golden: incoming light', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(app(callId: 'deadbeefcafef00d'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/incoming_light.png'),
    );
  });

  testWidgets('golden: incoming dark', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      app(callId: 'deadbeefcafef00d', brightness: Brightness.dark),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/incoming_dark.png'),
    );
  });

  testWidgets('golden: incoming rtl', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(app(callId: 'deadbeefcafef00d', rtl: true));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/incoming_rtl.png'),
    );
  });
}
