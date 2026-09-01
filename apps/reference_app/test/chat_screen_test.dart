import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_captions/live_captions.dart';
import 'package:messaging/messaging.dart';
import 'package:reference_app/main.dart';
import 'package:reference_app/src/chat_screen.dart';
import 'package:reference_app/src/loopback_port.dart';
import 'package:reference_app/src/photo_source.dart';

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

/// A tiny hand-built 2x2 24-bit BMP — real decodable bytes so Image.memory
/// never fails, with content that differs per color (distinct sha).
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

void stagedPhotoTests() {
  testWidgets('staged photo bubble climbs thumbhash -> preview -> verified '
      'original', (tester) async {
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
    final state = StagedPhotoState(announcement);
    final entries = [
      ChatEntry(
        message: _msg('peer', 0, '[photo]'),
        photoId: announcement.photoId,
      ),
    ];
    Widget build() => MaterialApp(
      home: Scaffold(
        body: ChatScreen(
          entries: entries,
          localSenderId: 'me',
          onSend: (_) {},
          incomingPhotos: {announcement.photoId: state},
        ),
      ),
    );

    await tester.pumpWidget(build());
    await tester.pump(); // thumbhash rasterization callback
    expect(find.byType(ThumbHashPlaceholder), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('blurred preview')), findsOneWidget);

    state
      ..preview = _tinyBmp(20, 200, 20)
      ..stage = PhotoStage.previewReady;
    await tester.pumpWidget(build());
    await tester.pump();
    expect(find.byType(ThumbHashPlaceholder), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('receiving original')), findsOneWidget);

    state
      ..original = _tinyBmp(200, 20, 20)
      ..sha256Verified = true
      ..stage = PhotoStage.originalVerified;
    await tester.pumpWidget(build());
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.verified_outlined), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('sha verified')), findsOneWidget);
  });

  testWidgets('photo button opens the gallery/camera sheet and reports the '
      'chosen source', (tester) async {
    PhotoSource? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatScreen(
            entries: const [],
            localSenderId: 'me',
            onSend: (_) {},
            onSendPhoto: (source) async => chosen = source,
          ),
        ),
      ),
    );
    await tester.tap(find.bySemanticsLabel('Send photo'));
    await tester.pumpAndSettle();
    expect(find.text('Photo library'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);

    await tester.tap(find.text('Photo library'));
    await tester.pumpAndSettle();
    expect(chosen, PhotoSource.gallery);
  });

  testWidgets('loopback demo delivers a staged photo end to end: sender '
      'done + receiver sha-verified, one bubble each side', (tester) async {
    final artifacts = StagedPhotoArtifacts(
      thumbHash: _testThumbHash(),
      preview: _tinyBmp(20, 200, 20),
      original: _tinyBmp(200, 20, 20),
      width: 2,
      height: 2,
      contentType: 'image/bmp',
    );
    final photoId = PhotoAnnouncement.fromArtifacts(artifacts).photoId;
    final controller = ChatDemoController(
      photoPicker: (_) async => Uint8List.fromList(const [0]),
      photoIngest: (_) async => artifacts,
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
              onSendPhoto: controller.pickAndSendPhoto,
              outgoingPhotos: controller.outgoingPhotos,
              incomingPhotos: controller.incomingPhotos,
            ),
          ),
        ),
      ),
    );

    unawaited(controller.pickAndSendPhoto(PhotoSource.gallery));
    var settled = false;
    for (var i = 0; i < 100 && !settled; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      final out = controller.outgoingPhotos[photoId];
      final inc = controller.incomingPhotos[photoId];
      settled = (out?.done ?? false) && (inc?.sha256Verified ?? false);
    }
    expect(
      settled,
      isTrue,
      reason: 'staged delivery must complete on a clean loopback',
    );
    expect(
      find.bySemanticsLabel(RegExp('Photo from You — delivered')),
      findsOneWidget,
    );
    // The incoming bubble is the newest transcript row; ListView.builder
    // only builds visible rows, so bring the tail into view first.
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    expect(
      find.bySemanticsLabel(RegExp('Photo from peer — sha verified')),
      findsOneWidget,
    );

    controller.dispose();
    await tester.pump();
  });
}

void main() {
  stagedPhotoTests();
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

  testWidgets('caption strip renders interim speech italic with an ellipsis '
      'and final speech plain', (tester) async {
    Caption cap(String id, int seq, String text, {required bool isFinal}) =>
        Caption(
          segment: TranscriptSegment(
            id: id,
            seq: seq,
            lang: 'en',
            text: text,
            isFinal: isFinal,
            startMs: seq * 1000,
          ),
        );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatScreen(
            entries: const [],
            localSenderId: 'me',
            onSend: (_) {},
            captions: [
              cap('c1', 0, 'a committed line', isFinal: true),
              cap('c2', 1, 'still forming', isFinal: false),
            ],
          ),
        ),
      ),
    );

    expect(find.text('a committed line'), findsOneWidget);
    final interim = tester.widget<Text>(find.text('still forming…'));
    expect(interim.style?.fontStyle, FontStyle.italic);
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
    // The attachment sender is ACK-PACED (2026-08-07): each chunk waits for
    // its delivery ack, so the peer end must be a live acking messenger —
    // a discarded peer port would leave progress stuck at 0.0 forever.
    final (callPort, peerPort) = pairLoopbackPorts();
    final peerMessenger = ReliableMessenger(peerPort, peerId: 'peer');
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
    await tester.pump(); // chunk reaches the peer messenger
    await tester.pump(); // peer ack returns
    await tester.pump(); // sender marks delivered, progress -> 1.0

    expect(find.byIcon(Icons.insert_drive_file), findsOneWidget);
    expect(find.textContaining('text/plain'), findsOneWidget);
    expect(controller.attachmentProgress['picked-1'], 1.0);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    controller.dispose();
    unawaited(peerMessenger.close());
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
