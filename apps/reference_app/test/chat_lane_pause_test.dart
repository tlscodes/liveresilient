/// While the call's path is not live, the binary lanes freeze and resume
/// from their ack state — a clip sent during a recovery episode lands once
/// the path is back, verified, without a retry from the user.
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
  test(
    'a video sent while the path is down waits, then verifies on resume',
    () async {
      final (chatLocal, chatRemote) = pairLoopbackPorts();
      final (videoLocal, videoRemote) = pairLoopbackPorts();
      final clip = _clip(20000, 0xBEEF);
      final controller = ChatDemoController(
        callChannelPort: chatLocal,
        videoLanePort: videoLocal,
        attachmentPicker: () async => Attachment(
          id: 'video-paused',
          kind: MediaKind.video,
          contentType: 'video/mp4',
          bytes: clip,
        ),
      );
      addTearDown(controller.dispose);
      final remote = ReliableMessenger(chatRemote, peerId: 'remote');
      addTearDown(remote.close);
      final receiver = VideoNoteReceiver(videoRemote);
      addTearDown(receiver.close);
      final stages = <VideoNoteStage>[];
      receiver.updates.listen((u) => stages.add(u.stage));
      remote.incoming.listen((m) => receiver.offerText(m.text));

      controller.setPathLive(false);
      expect(controller.pathLive, isFalse);
      final send = controller.pickAndSendAttachment();
      await _settle(10);
      expect(
        stages,
        isNot(contains(VideoNoteStage.verified)),
        reason: 'the lane is frozen while the path is down',
      );

      controller.setPathLive(true);
      await send.timeout(const Duration(seconds: 10));
      await _settle();
      expect(stages, contains(VideoNoteStage.verified));
      expect(receiver.notes[contentAddressHex(clip)]!.bytes, clip);
    },
  );
}
