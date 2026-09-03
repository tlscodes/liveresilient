/// Video notes through ChatDemoController: announcement on the chat
/// messenger, content-addressed blob on the video lane, delivery tick only
/// on the far side's sha256-verified receipt — in call mode against a remote
/// receiver, and in the loopback demo where the peer end verifies.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:messaging/messaging.dart';
import 'package:reference_app/main.dart';
import 'package:reference_app/src/loopback_port.dart';

Uint8List _clip(int length, int seed) {
  final out = Uint8List(length);
  var x = seed;
  for (var i = 0; i < length; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    out[i] = (x >> 16) & 0xff;
  }
  return out;
}

Future<void> _settle([int rounds = 20]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  test('call mode: a picked video rides the video lane and the bubble is '
      'delivered only when the remote verified the sha256', () async {
    final (chatLocal, chatRemote) = pairLoopbackPorts();
    final (videoLocal, videoRemote) = pairLoopbackPorts();
    final clip = _clip(30000, 0xC11F);
    final controller = ChatDemoController(
      callChannelPort: chatLocal,
      videoLanePort: videoLocal,
      attachmentPicker: () async => Attachment(
        id: 'video-1',
        kind: MediaKind.video,
        contentType: 'video/mp4',
        bytes: clip,
      ),
    );
    addTearDown(controller.dispose);
    expect(controller.canSendVideo, isTrue);

    // The remote human: a messenger for the announcement, a receiver on the
    // lane, wired the way the phone-side journey peer wires them.
    final remote = ReliableMessenger(chatRemote, peerId: 'remote');
    addTearDown(remote.close);
    final receiver = VideoNoteReceiver(videoRemote);
    addTearDown(receiver.close);
    final stages = <VideoNoteStage>[];
    receiver.updates.listen((u) => stages.add(u.stage));
    remote.incoming.listen((message) => receiver.offerText(message.text));

    await controller.pickAndSendAttachment();
    await _settle();

    expect(stages, contains(VideoNoteStage.verified));
    final mine = controller.entries.last;
    expect(mine.message.text, '[video]');
    expect(mine.attachment?.kind, MediaKind.video);
    expect(controller.deliveryStates[mine.message.id], DeliveryState.delivered);
    expect(controller.sentSha256['video-1'], contentSha256Hex(clip));
    final status = controller.outgoingVideos[contentAddressHex(clip)];
    expect(status?.done, isTrue);
    expect(status?.failed, isFalse);
    final received = receiver.notes[contentAddressHex(clip)]!;
    expect(received.stage, VideoNoteStage.verified);
    expect(received.bytes, clip);
  });

  test('loopback demo: a picked video is verified by the peer end and shows '
      'as an incoming video bubble', () async {
    final clip = _clip(12000, 0xD1D0);
    final controller = ChatDemoController(
      attachmentPicker: () async => Attachment(
        id: 'video-2',
        kind: MediaKind.video,
        contentType: 'video/webm',
        bytes: clip,
      ),
    );
    addTearDown(controller.dispose);

    await controller.pickAndSendAttachment();
    await _settle();

    final incoming = controller.entries.where(
      (e) =>
          e.message.senderId != controller.localSenderId &&
          e.attachment?.kind == MediaKind.video,
    );
    expect(incoming, hasLength(1));
    expect(incoming.single.attachment!.bytes, clip);
    expect(
      controller.incomingVideos.values.single.stage,
      VideoNoteStage.verified,
    );
  });

  test('without a video lane a picked video takes the chunked path and '
      'still records its sha256', () async {
    final (chatLocal, chatRemote) = pairLoopbackPorts();
    final clip = _clip(3000, 0xABCD);
    final controller = ChatDemoController(
      callChannelPort: chatLocal,
      attachmentPicker: () async => Attachment(
        id: 'video-3',
        kind: MediaKind.video,
        contentType: 'video/mp4',
        bytes: clip,
      ),
    );
    addTearDown(controller.dispose);
    expect(controller.canSendVideo, isFalse);
    final remote = ReliableMessenger(chatRemote, peerId: 'remote');
    addTearDown(remote.close);
    final attachments = AttachmentReceiver();
    final got = <Attachment>[];
    attachments.completed.listen(got.add);
    remote.incoming.listen((m) => attachments.offer(m.text));

    await controller.pickAndSendAttachment();
    await _settle();

    expect(got, hasLength(1));
    expect(got.single.bytes, clip);
    expect(controller.sentSha256['video-3'], contentSha256Hex(clip));
  });
}
