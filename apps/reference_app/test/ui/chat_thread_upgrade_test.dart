/// Coverage for the chat-thread visual upgrade: consecutive-sender grouping
/// logic, delivery-tick mapping, entrance-animation gating, the composer
/// mic↔send morph with the recorder overlay, and thread goldens.
///
/// Icon vocabulary note (deliberate): the pre-existing chat tests pin
/// `Icons.schedule` / `Icons.done` / `Icons.error_outline` for text ticks
/// and `Icons.verified_outlined` for the sha pill. The restyle keeps that
/// exact vocabulary green (recolored from tokens), so these tests pin the
/// SAME icons rather than the MessageStatusBadge set.
library;

@Tags(['golden'])
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:messaging/messaging.dart';
import 'package:reference_app/src/chat_screen.dart';
import 'package:reference_app/src/ui/tokens.dart';
import 'package:reference_app/src/ui/voice_note.dart';

ChatMessage _msg(String senderId, int seq, String text) => ChatMessage(
  id: '$senderId-$seq',
  senderId: senderId,
  seq: seq,
  sentAtMs: 0,
  text: text,
);

/// A tiny hand-built 2x2 24-bit BMP — real decodable bytes so Image.memory
/// never fails (mirrors the pre-existing chat_screen_test helper).
Uint8List _tinyBmp(int r, int g, int b) {
  const w = 2, h = 2, rowBytes = 8, dataSize = rowBytes * h;
  const fileSize = 54 + dataSize;
  final bytes = Uint8List(fileSize);
  final d = ByteData.view(bytes.buffer);
  bytes[0] = 0x42;
  bytes[1] = 0x4D;
  d.setUint32(2, fileSize, Endian.little);
  d.setUint32(10, 54, Endian.little);
  d.setUint32(14, 40, Endian.little);
  d.setInt32(18, w, Endian.little);
  d.setInt32(22, h, Endian.little);
  d.setUint16(26, 1, Endian.little);
  d.setUint16(28, 24, Endian.little);
  d.setUint32(34, dataSize, Endian.little);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final o = 54 + y * rowBytes + x * 3;
      bytes[o] = b;
      bytes[o + 1] = g;
      bytes[o + 2] = r;
    }
  }
  return bytes;
}

Uint8List _testThumbHash() {
  final rgba = Uint8List(16 * 16 * 4);
  for (var i = 0; i < 16 * 16; i++) {
    rgba[i * 4] = (i * 255) ~/ 256;
    rgba[i * 4 + 1] = 90;
    rgba[i * 4 + 2] = 160;
    rgba[i * 4 + 3] = 255;
  }
  return ThumbHash.encodeRgba(16, 16, rgba);
}

Future<void> pumpChat(
  WidgetTester tester, {
  required Widget home,
  Brightness brightness = Brightness.light,
  bool rtl = false,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppThemeData(brightness),
      home: rtl
          ? Directionality(textDirection: TextDirection.rtl, child: home)
          : home,
    ),
  );
}

void main() {
  group('grouping logic (pure)', () {
    final entries = [
      ChatEntry(message: _msg('me', 0, 'one')),
      ChatEntry(message: _msg('me', 1, 'two')),
      ChatEntry(message: _msg('peer', 2, 'three')),
      ChatEntry(message: _msg('me', 3, 'four')),
    ];

    test('continuesGroup only for a consecutive same-sender entry', () {
      expect(chatEntryContinuesGroup(entries, 0), isFalse);
      expect(chatEntryContinuesGroup(entries, 1), isTrue);
      expect(chatEntryContinuesGroup(entries, 2), isFalse);
      expect(chatEntryContinuesGroup(entries, 3), isFalse);
    });

    test('gap shrinks inside a group (s2 vs s8), none above the first row', () {
      expect(chatBubbleGapAbove(continuesGroup: false, isFirst: true), 0);
      expect(
        chatBubbleGapAbove(continuesGroup: true, isFirst: false),
        AppSpacing.s2,
      );
      expect(
        chatBubbleGapAbove(continuesGroup: false, isFirst: false),
        AppSpacing.s8,
      );
    });

    test('corners: tail on the sender side, adjacent corner squared inside '
        'a group; all directional', () {
      const big = Radius.circular(AppRadius.bubble);
      const tail = Radius.circular(AppRadius.bubbleTail);

      final mine = chatBubbleRadius(isMe: true, continuesGroup: false);
      expect(mine.bottomEnd, tail, reason: 'my tail sits at bottomEnd');
      expect(mine.topEnd, big);
      expect(mine.topStart, big);
      expect(mine.bottomStart, big);

      final mineGrouped = chatBubbleRadius(isMe: true, continuesGroup: true);
      expect(mineGrouped.topEnd, tail, reason: 'grouped: adjacent squared');
      expect(mineGrouped.bottomEnd, tail);

      final theirs = chatBubbleRadius(isMe: false, continuesGroup: false);
      expect(
        theirs.bottomStart,
        tail,
        reason: 'their tail sits at bottomStart',
      );
      expect(theirs.topStart, big);

      final theirsGrouped = chatBubbleRadius(isMe: false, continuesGroup: true);
      expect(theirsGrouped.topStart, tail);
    });
  });

  group('delivery tick mapping (icons pinned by the pre-existing tests)', () {
    Widget screen({Map<String, DeliveryState> deliveryStates = const {}}) {
      return Scaffold(
        body: ChatScreen(
          entries: [ChatEntry(message: _msg('me', 0, 'hello'))],
          localSenderId: 'me',
          onSend: (_) {},
          deliveryStates: deliveryStates,
        ),
      );
    }

    testWidgets('pending (no ack yet) shows the schedule tick', (tester) async {
      await pumpChat(tester, home: screen());
      expect(find.byIcon(Icons.schedule), findsOneWidget);
      expect(find.byIcon(Icons.done), findsNothing);
      expect(find.bySemanticsLabel('You: hello, pending'), findsOneWidget);
    });

    testWidgets('delivered shows the done tick', (tester) async {
      await pumpChat(
        tester,
        home: screen(deliveryStates: const {'me-0': DeliveryState.delivered}),
      );
      expect(find.byIcon(Icons.done), findsOneWidget);
      expect(find.byIcon(Icons.schedule), findsNothing);
      expect(find.bySemanticsLabel('You: hello, delivered'), findsOneWidget);
    });

    testWidgets('failed shows the error tick', (tester) async {
      await pumpChat(
        tester,
        home: screen(deliveryStates: const {'me-0': DeliveryState.failed}),
      );
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.bySemanticsLabel('You: hello, failed'), findsOneWidget);
    });
  });

  testWidgets('sha-verified incoming photo renders the verified pill with '
      'the pinned icon', (tester) async {
    final announcement = PhotoAnnouncement(
      photoId: 'a' * 32,
      sha256Hex: 'b' * 64,
      previewId: 'c' * 32,
      sizeBytes: 70,
      previewBytes: 70,
      width: 640,
      height: 480,
      contentType: 'image/bmp',
      thumbHash: _testThumbHash(),
    );
    final state = StagedPhotoState(announcement)
      ..original = _tinyBmp(200, 20, 20)
      ..sha256Verified = true
      ..stage = PhotoStage.originalVerified;

    await pumpChat(
      tester,
      home: Scaffold(
        body: ChatScreen(
          entries: [
            ChatEntry(
              message: _msg('peer', 0, '[photo]'),
              photoId: announcement.photoId,
            ),
          ],
          localSenderId: 'me',
          onSend: (_) {},
          incomingPhotos: {announcement.photoId: state},
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.verified_outlined), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('sha verified')), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('entrance animation is skipped for first-build entries and '
      'runs once for later arrivals', (tester) async {
    Widget screen(List<ChatEntry> entries) => Scaffold(
      body: ChatScreen(entries: entries, localSenderId: 'me', onSend: (_) {}),
    );
    final first = ChatEntry(message: _msg('me', 0, 'first'));

    await pumpChat(tester, home: screen([first]));
    expect(
      find.byKey(const ValueKey('bubble-entrance-me-0')),
      findsNothing,
      reason: 'entries present at first build never animate',
    );
    expect(find.byKey(const ValueKey('bubble-me-0')), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppThemeData(Brightness.light),
        home: screen([first, ChatEntry(message: _msg('me', 1, 'second'))]),
      ),
    );

    expect(
      find.byKey(const ValueKey('bubble-entrance-me-1')),
      findsOneWidget,
      reason: 'a later arrival gets the one-shot entrance',
    );
    expect(find.byKey(const ValueKey('bubble-entrance-me-0')), findsNothing);
    // Mid-flight the bubble is already discoverable...
    expect(find.text('second'), findsOneWidget);
    // ...and the one-shot settles.
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('voice bubble renders the player bar and still routes taps to '
      'onPlayAudio', (tester) async {
    final voiceNote = Attachment(
      id: 'vn1',
      kind: MediaKind.file,
      contentType: 'audio/ogg',
      bytes: List<int>.filled(64, 1),
    );
    final played = <String>[];
    await pumpChat(
      tester,
      home: Scaffold(
        body: ChatScreen(
          entries: [
            ChatEntry(
              message: _msg('peer', 0, '[voice]'),
              attachment: voiceNote,
            ),
          ],
          localSenderId: 'me',
          onSend: (_) {},
          onPlayAudio: (a) => played.add(a.id),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(VoiceNotePlayerBar), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    // The bubble keeps its single outer semantics label (pinned pattern),
    // so inner controls are reached visually: label tap and play-icon tap
    // both route to onPlayAudio, and the seekless waveform must not
    // swallow bubble taps.
    await tester.tap(find.textContaining('Voice note'));
    await tester.tap(find.byIcon(Icons.play_circle_outline));
    expect(played, ['vn1', 'vn1']);
  });

  testWidgets('composer morphs mic<->send by text state and runs the '
      'record/cancel/send flow', (tester) async {
    final amplitude = StreamController<double>.broadcast();
    addTearDown(amplitude.close);
    Duration? sentLength;
    final texts = <String>[];

    await pumpChat(
      tester,
      home: Scaffold(
        body: ChatScreen(
          entries: [ChatEntry(message: _msg('peer', 0, 'hi'))],
          localSenderId: 'me',
          onSend: texts.add,
          amplitudeSource: amplitude.stream,
          onSendVoiceNote: (length) async => sentLength = length,
        ),
      ),
    );

    // Empty input + amplitude source -> mic affordance.
    expect(find.bySemanticsLabel('Record voice note'), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsOneWidget);

    // Typing morphs to send; sending works.
    await tester.enterText(find.byType(TextField), 'salaam');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Send message'), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsNothing);
    await tester.tap(find.bySemanticsLabel('Send message'));
    await tester.pumpAndSettle();
    expect(texts, ['salaam']);

    // Cleared input -> mic again; start recording.
    expect(find.bySemanticsLabel('Record voice note'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Record voice note'));
    await tester.pump();
    expect(find.byType(VoiceNoteRecorderOverlay), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    amplitude.add(0.6);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('0:02'), findsOneWidget);

    // Cancel discards: composer returns, nothing sent.
    await tester.tap(find.bySemanticsLabel('Cancel recording'));
    await tester.pump();
    expect(find.byType(VoiceNoteRecorderOverlay), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(sentLength, isNull);

    // Record again and finish: the measured length is reported.
    await tester.tap(find.bySemanticsLabel('Record voice note'));
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.bySemanticsLabel('Send voice note'));
    await tester.pump();
    expect(sentLength, const Duration(seconds: 3));
    expect(find.byType(TextField), findsOneWidget);
  });

  group('goldens', () {
    List<ChatEntry> threadEntries() => [
      ChatEntry(message: _msg('peer', 0, 'Salaam! The new build is up.')),
      ChatEntry(message: _msg('peer', 1, 'Try the voice notes when you can.')),
      ChatEntry(message: _msg('me', 2, 'Looking now — bubbles feel right.')),
      ChatEntry(message: _msg('me', 3, 'Shipping the tokens today.')),
      ChatEntry(
        message: _msg('peer', 4, '[voice]'),
        attachment: Attachment(
          id: 'vn-golden',
          kind: MediaKind.file,
          contentType: 'audio/ogg',
          bytes: List<int>.generate(96, (i) => (i * 13) % 256),
        ),
      ),
      ChatEntry(
        message: _msg('me', 5, '[file]'),
        attachment: Attachment(
          id: 'file-golden',
          kind: MediaKind.file,
          contentType: 'application/pdf',
          bytes: List<int>.filled(2048, 0),
        ),
      ),
      ChatEntry(message: _msg('me', 6, 'This one failed to send.')),
    ];

    Widget thread() => Scaffold(
      body: ChatScreen(
        entries: threadEntries(),
        localSenderId: 'me',
        onSend: (_) {},
        deliveryStates: const {
          'me-2': DeliveryState.delivered,
          'me-6': DeliveryState.failed,
        },
        attachmentProgress: const {'file-golden': 0.62},
        onPickAttachment: () {},
        onPlayAudio: (_) {},
      ),
    );

    testWidgets('chat thread light', (tester) async {
      await pumpChat(tester, home: thread());
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(ChatScreen),
        matchesGoldenFile('goldens/chat_thread_light.png'),
      );
    });

    testWidgets('chat thread dark', (tester) async {
      await pumpChat(tester, home: thread(), brightness: Brightness.dark);
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(ChatScreen),
        matchesGoldenFile('goldens/chat_thread_dark.png'),
      );
    });

    testWidgets('chat thread rtl', (tester) async {
      await pumpChat(tester, home: thread(), rtl: true);
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(ChatScreen),
        matchesGoldenFile('goldens/chat_thread_rtl.png'),
      );
    });
  });
}
