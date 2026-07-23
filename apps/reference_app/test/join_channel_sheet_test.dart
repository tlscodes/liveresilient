/// Join sheet: live validation of ids and both link forms, the language
/// chip, and completing with the parsed invite.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_captions/live_captions.dart';
import 'package:reference_app/src/join_channel_sheet.dart';

Future<void> _pumpSheet(
  WidgetTester tester,
  void Function(ChannelInvite?) onResult,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () async =>
                  onResult(await showJoinChannelSheet(context)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('invalid input disables Join and shows the error', (
    tester,
  ) async {
    await _pumpSheet(tester, (_) {});
    await tester.enterText(find.byType(TextField), 'ab');
    await tester.pumpAndSettle();

    expect(find.text('Not a valid channel ID or invite link'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Join channel'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('a pasted web invite shows channel + language chips and '
      'completes with the parsed invite', (tester) async {
    ChannelInvite? result;
    await _pumpSheet(tester, (invite) => result = invite);
    await tester.enterText(
      find.byType(TextField),
      'https://vck.app/c/room-42?lang=fa',
    );
    await tester.pumpAndSettle();

    expect(find.text('room-42'), findsOneWidget);
    expect(find.text('Captions in fa'), findsOneWidget);

    await tester.tap(find.text('Join channel'));
    await tester.pumpAndSettle();
    expect(result!.channelId, 'room-42');
    expect(result!.language, 'fa');
  });

  testWidgets('a bare 6-digit code joins too (the old flow, kept)', (
    tester,
  ) async {
    ChannelInvite? result;
    await _pumpSheet(tester, (invite) => result = invite);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Join channel'));
    await tester.pumpAndSettle();
    expect(result!.channelId, '123456');
  });
}
