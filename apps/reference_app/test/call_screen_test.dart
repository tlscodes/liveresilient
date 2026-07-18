import 'package:call_core/call_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/call_screen.dart';

Future<void> _pumpAt(WidgetTester tester, Widget child, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  const sizes = [Size(320, 568), Size(800, 1280)];

  for (final phase in CallPhase.values) {
    testWidgets('renders the label for ${phase.name}', (tester) async {
      final needsReason = phase == CallPhase.ended || phase == CallPhase.failed;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CallScreen(
              phase: phase,
              reconnectAttempt: phase == CallPhase.reconnecting ? 2 : 0,
              endReason: needsReason ? CallEndReason.localHangup : null,
            ),
          ),
        ),
      );

      expect(find.text(callPhaseLabel(phase)), findsOneWidget);
    });
  }

  testWidgets('reconnecting shows the attempt number', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CallScreen(phase: CallPhase.reconnecting, reconnectAttempt: 3),
        ),
      ),
    );

    expect(find.text('Attempt 3'), findsOneWidget);
  });

  testWidgets('ended shows the end reason', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CallScreen(
            phase: CallPhase.ended,
            endReason: CallEndReason.remoteHangup,
          ),
        ),
      ),
    );

    expect(
      find.text(callEndReasonLabel(CallEndReason.remoteHangup)),
      findsOneWidget,
    );
  });

  testWidgets('audio-only chip appears only when the flag is set', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CallScreen(phase: CallPhase.connected, audioOnly: true),
        ),
      ),
    );
    expect(find.text('Audio only'), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CallScreen(phase: CallPhase.connected, audioOnly: false),
        ),
      ),
    );
    expect(find.text('Audio only'), findsNothing);
  });

  testWidgets('privacy status line is always present', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: CallScreen(phase: CallPhase.idle)),
      ),
    );

    expect(
      find.text('E2E media · no telemetry without opt-in'),
      findsOneWidget,
    );
  });

  testWidgets('call and hang-up controls expose Semantics labels', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CallScreen(phase: CallPhase.idle, onCall: () {}),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Call'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CallScreen(phase: CallPhase.connected, onHangUp: () {}),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Hang up'), findsOneWidget);
  });

  testWidgets('tapping Call invokes onCall', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CallScreen(phase: CallPhase.idle, onCall: () => tapped = true),
        ),
      ),
    );

    await tester.tap(find.text('Call'));
    await tester.pump();
    expect(tapped, isTrue);
  });

  for (final size in sizes) {
    testWidgets('no overflow at ${size.width}x${size.height}', (tester) async {
      await _pumpAt(
        tester,
        const CallScreen(
          phase: CallPhase.reconnecting,
          reconnectAttempt: 4,
          audioOnly: true,
        ),
        size,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
