/// The call id the app hands to the relay is minted, not chosen.
///
/// It doubles as the border relay's session id, so a guessable id lets
/// anyone attach to the call as the missing side. These assert that the
/// app layer produces one per call, that it is unguessable, and that the
/// screen presents it as a secret rather than as a room number.
library;

import 'package:call_core/call_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/call_demo_controller.dart';
import 'package:reference_app/src/call_screen.dart';
import 'package:reference_app/src/call_session.dart';

void main() {
  group('CallDemoController', () {
    test('has no call id until a call is placed', () {
      expect(CallDemoController().callId, isNull);
    });

    test('mints a secure id when a call is placed', () {
      final controller = CallDemoController();
      addTearDown(controller.dispose);

      controller.placeCall();

      // 16 bytes of CSPRNG output, base64url without padding — the same
      // alphabet the relay accepts.
      expect(controller.callId, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
    });

    test('a second call gets a different id', () {
      final controller = CallDemoController();
      addTearDown(controller.dispose);

      controller.placeCall();
      final first = controller.callId;
      controller.placeCall();

      expect(controller.callId, isNot(first));
    });

    test('production default is newSecureCallId', () {
      // The seam exists for tests; the app must not be relying on it.
      expect(CallDemoController().mintCallId, same(newSecureCallId));
    });
  });

  group('CallScreen', () {
    testWidgets('shows the call key while a call is active', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: CallScreen(phase: CallPhase.connected, callId: 'AbC-123_xyz'),
        ),
      );

      expect(find.text('AbC-123_xyz'), findsOneWidget);
      expect(find.text('Call key'), findsOneWidget);
      // The warning is the point: this string is a credential.
      expect(
        find.textContaining('anyone with this key can join'),
        findsOneWidget,
      );
    });

    testWidgets('hides the call key once the call has ended', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: CallScreen(phase: CallPhase.ended, callId: 'AbC-123_xyz'),
        ),
      );

      expect(find.text('AbC-123_xyz'), findsNothing);
    });

    testWidgets('shows nothing extra when there is no call id', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: CallScreen(phase: CallPhase.connected)),
      );

      expect(find.text('Call key'), findsNothing);
    });
  });
}
