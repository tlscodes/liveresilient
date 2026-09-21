// The reference app's letter sheet and its entry on the conversations
// screen, without a network: the courier has no lane, so every verdict is
// immediate and the banner's state is read off its key.
import 'package:connection_orchestrator/connection_orchestrator.dart'
    show ResilientLaneEndpoints;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/letter_composer.dart';
import 'package:reference_app/src/letter_courier.dart';
import 'package:reference_app/src/ui/conversations_screen.dart';
import 'package:reference_app/src/ui/letter_sheet.dart';

void main() {
  testWidgets(
    'Send with nothing in hand says so; a typed line reaches the courier and ends on a verdict',
    (tester) async {
      final composer = LetterComposer();
      final courier = LetterCourier(
        endpoints: () => const ResilientLaneEndpoints(),
      );
      addTearDown(courier.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LetterSheet(composer: composer, courier: courier),
          ),
        ),
      );
      expect(find.byKey(const Key('letter-sheet-title')), findsOneWidget);
      expect(find.text('Record voice (5 min cap)'), findsOneWidget);
      expect(find.textContaining('≤10 letters'), findsOneWidget);
      // No banner before any act: a blank is honest here, a spinner is not.
      expect(find.byKey(const Key('letter-sheet-hint')), findsNothing);

      await tester.tap(find.byKey(const Key('letter-sheet-send')));
      await tester.pump();
      expect(find.byKey(const Key('letter-sheet-hint')), findsOneWidget);
      expect(courier.status.value, isNull);

      await tester.enterText(
        find.byKey(const Key('letter-sheet-draft')),
        'a short line',
      );
      await tester.tap(find.byKey(const Key('letter-sheet-send')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(courier.status.value!.state, LetterState.notDelivered);
      expect(
        find
                .byKey(const Key('letter-sheet-state-notDelivered'))
                .evaluate()
                .isNotEmpty ||
            find
                .byKey(const Key('journey-peer-letter-state-notDelivered'))
                .evaluate()
                .isNotEmpty,
        isTrue,
      );
      expect(find.text('Letter not delivered'), findsOneWidget);
      // The draft was consumed by the send, so a repeat cannot re-send it.
      expect(composer.draft.value, isEmpty);
      expect(
        courier.notes.value.join('\n'),
        contains('letter state: Letter not delivered'),
      );
    },
  );

  testWidgets(
    'the conversations screen shows the letter entry only when wired',
    (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationsScreen(
            conversations: const [],
            onOpen: (_) {},
            onLetter: () => opened++,
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byKey(const Key('conversations-letter')));
      expect(opened, 1);

      await tester.pumpWidget(
        MaterialApp(
          home: ConversationsScreen(conversations: const [], onOpen: (_) {}),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const Key('conversations-letter')), findsNothing);
    },
  );
}
