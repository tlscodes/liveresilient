import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_captions/live_captions.dart';
import 'package:messaging/messaging.dart';
import 'package:reference_app/main.dart';
import 'package:reference_app/src/chat_screen.dart';
import 'package:reference_app/src/loopback_port.dart';

ChatMessage _msg(String senderId, int seq, String text) => ChatMessage(
  id: '$senderId-$seq',
  senderId: senderId,
  seq: seq,
  sentAtMs: 0,
  text: text,
);

/// Holds outbound frames until [release] — lets a test keep a message
/// un-acked (marker stays pending) and then deliver the ack on demand.
class _HoldingPort implements DataChannelPort {
  _HoldingPort(this._inner);

  final DataChannelPort _inner;
  final List<List<int>> _held = [];

  @override
  Stream<List<int>> get inbound => _inner.inbound;

  @override
  Future<void> send(List<int> frame) async {
    _held.add(frame);
  }

  Future<void> release() async {
    for (final frame in _held) {
      await _inner.send(frame);
    }
    _held.clear();
  }

  @override
  Future<void> close() => _inner.close();
}

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

  testWidgets('voice-note and recovered-audio bubbles render with a play '
      'affordance; tapping invokes onPlayAudio with the attachment', (
    tester,
  ) async {
    final voiceNote = Attachment(
      id: 'vn1',
      kind: MediaKind.file,
      contentType: 'audio/ogg',
      bytes: List<int>.filled(64, 1),
    );
    final replay = Attachment(
      id: 'gr1',
      kind: MediaKind.file,
      contentType: 'audio/replay',
      bytes: List<int>.filled(32, 2),
    );
    final played = <Attachment>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatScreen(
            entries: [
              ChatEntry(
                message: _msg('peer', 0, '[voice]'),
                attachment: voiceNote,
              ),
              ChatEntry(
                message: _msg('peer', 1, '[replay]'),
                attachment: replay,
              ),
            ],
            localSenderId: 'me',
            onSend: (_) {},
            onPlayAudio: played.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Voice note'), findsOneWidget);
    expect(find.textContaining('Recovered audio'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outline), findsNWidgets(2));

    await tester.tap(find.textContaining('Voice note'));
    await tester.tap(find.textContaining('Recovered audio'));
    expect(played.map((a) => a.id).toList(), ['vn1', 'gr1']);
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

  testWidgets('outbound marker goes pending -> delivered when the ack '
      'delivery event arrives', (tester) async {
    final (callPort, remotePort) = pairLoopbackPorts();
    // The remote human's acks are held until we release them.
    final ackGate = _HoldingPort(remotePort);
    final controller = ChatDemoController(callChannelPort: callPort);
    final remoteHuman = ReliableMessenger(ackGate, peerId: 'remote');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (_, _) => ChatScreen(
              entries: controller.entries,
              localSenderId: controller.localSenderId,
              onSend: controller.sendText,
              deliveryStates: controller.deliveryStates,
            ),
          ),
        ),
      ),
    );

    // No bare awaits on messenger futures here: under testWidgets' FakeAsync
    // their microtasks only run inside pump().
    unawaited(controller.sendText('در راه'));
    await tester.pump();

    // Sent but not acknowledged: the bubble is there, marked pending.
    expect(find.text('در راه'), findsOneWidget);
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    expect(find.byIcon(Icons.done), findsNothing);

    unawaited(ackGate.release()); // the ack lands -> delivery event fires
    await tester.pump();

    expect(find.byIcon(Icons.done), findsOneWidget);
    expect(find.byIcon(Icons.schedule), findsNothing);

    controller.dispose();
    unawaited(remoteHuman.close());
    await tester.pump();
  });

  testWidgets('a failed delivery renders the error marker', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatScreen(
            entries: [ChatEntry(message: _msg('me', 0, 'lost'))],
            localSenderId: 'me',
            onSend: (_) {},
            deliveryStates: const {'me-0': DeliveryState.failed},
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.bySemanticsLabel('You: lost, failed'), findsOneWidget);
  });

  testWidgets('attachment bubble shows a determinate progress bar while the '
      'transfer is underway, none once complete', (tester) async {
    final attachment = Attachment(
      id: 'up1',
      kind: MediaKind.file,
      contentType: 'application/pdf',
      bytes: List<int>.filled(2048, 0),
    );
    Widget build(Map<String, double> progress) => MaterialApp(
      home: Scaffold(
        body: ChatScreen(
          entries: [
            ChatEntry(message: _msg('me', 0, '[file]'), attachment: attachment),
          ],
          localSenderId: 'me',
          onSend: (_) {},
          attachmentProgress: progress,
        ),
      ),
    );

    await tester.pumpWidget(build(const {'up1': 0.4}));
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, 0.4);

    await tester.pumpWidget(build(const {'up1': 1.0}));
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('attach button is hidden without a handler, shown with one, '
      'and tap invokes it', (tester) async {
    var picks = 0;
    Widget build(VoidCallback? onPick) => MaterialApp(
      home: Scaffold(
        body: ChatScreen(
          entries: const [],
          localSenderId: 'me',
          onSend: (_) {},
          onPickAttachment: onPick,
        ),
      ),
    );

    await tester.pumpWidget(build(null));
    expect(find.byIcon(Icons.attach_file), findsNothing);

    await tester.pumpWidget(build(() => picks++));
    await tester.tap(find.bySemanticsLabel('Attach file'));
    expect(picks, 1);
  });

  testWidgets('tapping attach runs the injected picker: the picked file '
      'lands as an attachment bubble and its transfer completes', (
    tester,
  ) async {
    final (callPort, _) = pairLoopbackPorts();
    final controller = ChatDemoController(
      callChannelPort: callPort,
      attachmentPicker: () async => Attachment(
        id: 'picked-1',
        kind: MediaKind.file,
        contentType: 'text/plain',
        bytes: List<int>.filled(5 * 1024, 7),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (_, _) => ChatScreen(
              entries: controller.entries,
              localSenderId: controller.localSenderId,
              onSend: controller.sendText,
              attachmentProgress: controller.attachmentProgress,
              onPickAttachment: () =>
                  unawaited(controller.pickAndSendAttachment()),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Attach file'));
    await tester.pump(); // picker resolves, bubble added
    await tester.pump(); // chunk handed to the messenger, progress -> 1.0

    expect(find.byIcon(Icons.insert_drive_file), findsOneWidget);
    expect(find.textContaining('text/plain'), findsOneWidget);
    expect(controller.attachmentProgress['picked-1'], 1.0);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    controller.dispose();
    await tester.pump();
  });

  testWidgets('caption strip shows the viewer-language text; hidden when '
      'empty', (tester) async {
    Caption cap(String id, String en, String fa) => Caption(
      segment: TranscriptSegment(
        id: id,
        seq: 0,
        lang: 'en',
        text: en,
        isFinal: true,
        startMs: 0,
      ),
      translations: {'fa': fa},
    );
    Widget build(List<Caption> captions) => MaterialApp(
      home: Scaffold(
        body: ChatScreen(
          entries: const [],
          localSenderId: 'me',
          onSend: (_) {},
          captions: captions,
          captionLanguage: 'fa',
        ),
      ),
    );

    await tester.pumpWidget(build(const []));
    expect(find.bySemanticsLabel('Live captions'), findsNothing);

    await tester.pumpWidget(
      build([
        cap('c1', 'first line', 'خط اول'),
        cap('c2', 'second line', 'خط دوم'),
        cap('c3', 'third line', 'خط سوم'),
      ]),
    );

    expect(find.bySemanticsLabel('Live captions'), findsOneWidget);
    // Only the LAST TWO captions render, in the viewer's language.
    expect(find.text('خط اول'), findsNothing);
    expect(find.text('خط دوم'), findsOneWidget);
    expect(find.text('خط سوم'), findsOneWidget);
    expect(find.text('third line'), findsNothing);
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
