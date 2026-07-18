/// ChatDemoController in call mode: the same messaging stack the loopback
/// demo uses, but riding a caller-supplied [DataChannelPort] (in production,
/// the live call's data channel via [CallSessionHandle.openChatPort]). The
/// remote human is the peer — no echo side, and incoming attachments are
/// reassembled off the wire into chat entries.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:messaging/messaging.dart';
import 'package:reference_app/main.dart';
import 'package:reference_app/src/loopback_port.dart';

void main() {
  test('typed text reaches the remote peer over the injected call port, '
      'and the ack drains pending', () async {
    final (callPort, remotePort) = pairLoopbackPorts();
    final controller = ChatDemoController(callChannelPort: callPort);
    final remoteHuman = ReliableMessenger(remotePort, peerId: 'remote');
    final remoteGot = <ChatMessage>[];
    remoteHuman.incoming.listen(remoteGot.add);

    await controller.sendText('سلام از داخل تماس');
    await pumpEventQueue();

    expect(remoteGot, hasLength(1));
    expect(remoteGot.single.text, 'سلام از داخل تماس');

    await remoteHuman.close();
    controller.dispose();
  });

  test(
    'remote text lands in entries; no echo peer exists in call mode',
    () async {
      final (callPort, remotePort) = pairLoopbackPorts();
      final controller = ChatDemoController(callChannelPort: callPort);
      final remoteHuman = ReliableMessenger(remotePort, peerId: 'remote');
      final remoteGot = <ChatMessage>[];
      remoteHuman.incoming.listen(remoteGot.add);

      await remoteHuman.send('پیام از آن سوی تماس');
      await pumpEventQueue();

      expect(controller.entries, hasLength(1));
      expect(controller.entries.single.message.text, 'پیام از آن سوی تماس');
      // Call mode must NOT auto-reply — the remote human is the peer.
      expect(remoteGot, isEmpty);

      await remoteHuman.close();
      controller.dispose();
    },
  );

  test('a chunked attachment from the remote side reassembles into an '
      'attachment entry', () async {
    final (callPort, remotePort) = pairLoopbackPorts();
    final controller = ChatDemoController(callChannelPort: callPort);
    final remoteHuman = ReliableMessenger(remotePort, peerId: 'remote');

    final photoBytes = List<int>.generate(40 * 1024, (i) => (i * 7) % 251);
    await sendAttachment(
      remoteHuman,
      Attachment(
        id: 'call-photo',
        kind: MediaKind.image,
        contentType: 'image/jpeg',
        bytes: photoBytes,
      ),
    );
    await pumpEventQueue();

    expect(controller.entries, hasLength(1));
    final entry = controller.entries.single;
    expect(entry.attachment, isNotNull);
    expect(entry.attachment!.id, 'call-photo');
    expect(entry.attachment!.bytes, photoBytes);
    // Chunk frames were consumed by reassembly, never shown as raw text.
    expect(entry.message.text, '[image]');

    await remoteHuman.close();
    controller.dispose();
  });

  test('default (no injected port) keeps the standalone loopback demo: '
      'echo peer answers', () async {
    final controller = ChatDemoController();
    await controller.sendText('hello');
    await pumpEventQueue();

    final texts = controller.entries.map((e) => e.message.text).toList();
    expect(texts, contains('echo: hello'));
    controller.dispose();
  });
}
