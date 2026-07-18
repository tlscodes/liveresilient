import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:messaging/messaging.dart';
import 'package:reference_app/src/chat_screen.dart';

ChatMessage _msg(String senderId, int seq, String text) => ChatMessage(
  id: '$senderId-$seq',
  senderId: senderId,
  seq: seq,
  sentAtMs: 0,
  text: text,
);

void main() {
  testWidgets('renders a plain text bubble', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatScreen(
            entries: [ChatEntry(message: _msg('me', 0, 'hello there'))],
            localSenderId: 'me',
            onSend: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('hello there'), findsOneWidget);
  });

  testWidgets('renders an image attachment via Image.memory', (tester) async {
    final attachment = Attachment(
      id: 'a1',
      kind: MediaKind.image,
      contentType: 'image/png',
      bytes: demoTinyPngBytes,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatScreen(
            entries: [
              ChatEntry(
                message: _msg('me', 0, '[photo]'),
                attachment: attachment,
              ),
            ],
            localSenderId: 'me',
            onSend: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    expect(find.bySemanticsLabel('Photo attachment from You'), findsOneWidget);
  });

  testWidgets('renders a file attachment bubble with name-equivalent info', (
    tester,
  ) async {
    final attachment = Attachment(
      id: 'a2',
      kind: MediaKind.file,
      contentType: 'application/pdf',
      bytes: List<int>.filled(2048, 0),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatScreen(
            entries: [
              ChatEntry(
                message: _msg('peer', 0, '[file]'),
                attachment: attachment,
              ),
            ],
            localSenderId: 'me',
            onSend: (_) {},
          ),
        ),
      ),
    );

    expect(find.textContaining('application/pdf'), findsOneWidget);
    expect(find.textContaining('2.0 KB'), findsOneWidget);
    expect(find.byIcon(Icons.insert_drive_file), findsOneWidget);
  });

  testWidgets('send button has a Semantics label and invokes onSend', (
    tester,
  ) async {
    String? sent;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatScreen(
            entries: const [],
            localSenderId: 'me',
            onSend: (text) => sent = text,
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('Send message'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'salaam');
    await tester.tap(find.bySemanticsLabel('Send message'));
    await tester.pump();

    expect(sent, 'salaam');
  });

  testWidgets('empty input never invokes onSend', (tester) async {
    var invoked = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatScreen(
            entries: const [],
            localSenderId: 'me',
            onSend: (_) => invoked = true,
          ),
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Send message'));
    await tester.pump();

    expect(invoked, isFalse);
  });

  for (final size in const [Size(320, 568), Size(800, 1280)]) {
    testWidgets('no overflow at ${size.width}x${size.height}', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final entries = [
        ChatEntry(message: _msg('me', 0, 'hi')),
        ChatEntry(
          message: _msg('peer', 1, '[photo]'),
          attachment: Attachment(
            id: 'a3',
            kind: MediaKind.image,
            contentType: 'image/png',
            bytes: demoTinyPngBytes,
          ),
        ),
        ChatEntry(
          message: _msg('me', 2, '[file]'),
          attachment: Attachment(
            id: 'a4',
            kind: MediaKind.file,
            contentType: 'application/pdf',
            bytes: List<int>.filled(4096, 0),
          ),
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatScreen(
              entries: entries,
              localSenderId: 'me',
              onSend: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  }
}
