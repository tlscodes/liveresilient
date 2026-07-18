/// Chat over a live call, end to end: two full stacks (real
/// `SignalingClient`s over real TLS sockets, real `CallController`s) reach
/// connected through the relay, then reliable text and a chunked photo ride
/// the call's data channel — messaging, bridge adapter, and both call
/// engines all genuine; only the platform SCTP pipe is substituted (see
/// support/in_memory_media_channel.dart for why that boundary).
library;

import 'dart:io';

import 'package:call_core/call_core.dart';
import 'package:messaging/messaging.dart';
import 'package:messaging_webrtc_adapter/messaging_webrtc_adapter.dart';
import 'package:signaling_server/signaling_server.dart';
import 'package:test/test.dart';

import 'support/call_stack.dart';
import 'support/in_memory_media_channel.dart';

void main() {
  late Directory certDir;
  late SignalingRelayServer server;

  setUp(() async {
    certDir = await Directory.systemTemp.createTemp(
      'chat_over_call_test_certs_',
    );
    final certificate = await ensureDevCertificate(directoryPath: certDir.path);
    final security = SecurityContext()
      ..useCertificateChain(certificate.certificatePath)
      ..usePrivateKey(certificate.privateKeyPath);
    server = await SignalingRelayServer.bind(security: security, port: 0);
  });

  tearDown(() async {
    await server.close();
    await certDir.delete(recursive: true);
  });

  test('text both directions and a chunked photo ride the connected call; '
      'hang-up tears everything down cleanly', () async {
    const callId = 'chat-over-call-1';
    final initiator = CallStack.build(
      port: server.port,
      callId: callId,
      role: CallRole.initiator,
    );
    final receiver = CallStack.build(
      port: server.port,
      callId: callId,
      role: CallRole.receiver,
    );

    final connected = await Future.wait([
      initiator.controller.start().then((_) => initiator.waitForConnected()),
      receiver.controller.start().then((_) => receiver.waitForConnected()),
    ]).timeout(const Duration(seconds: 10));
    expect(connected[0].phase, CallPhase.connected);
    expect(connected[1].phase, CallPhase.connected);

    // Call is up: open the negotiated chat channel on both ends (models
    // the platform opening the SCTP stream once DTLS is up).
    final (channelA, channelB) = InMemoryMediaChannel.pair();
    final portA = MediaChannelDataPort(channelA);
    final portB = MediaChannelDataPort(channelB);
    channelA.open();
    channelB.open();

    final alice = ReliableMessenger(portA, peerId: 'alice');
    final bob = ReliableMessenger(portB, peerId: 'bob');
    final aliceGot = <ChatMessage>[];
    final bobGot = <ChatMessage>[];
    final bobAttachments = <Attachment>[];
    final bobReceiver = AttachmentReceiver();
    bobReceiver.completed.listen(bobAttachments.add);
    alice.incoming.listen(aliceGot.add);
    bob.incoming.listen((message) {
      if (bobReceiver.offer(message.text)) return;
      bobGot.add(message);
    });

    await alice.send('سلام از سمت تماس‌گیرنده');
    await bob.send('و پاسخ از سمت گیرنده');
    final photoBytes = List<int>.generate(48 * 1024, (i) => (i * 13) % 251);
    await sendAttachment(
      alice,
      Attachment(
        id: 'call-photo-1',
        kind: MediaKind.image,
        contentType: 'image/jpeg',
        bytes: photoBytes,
      ),
    );
    await pumpEventQueue();

    expect(bobGot.map((m) => m.text), ['سلام از سمت تماس‌گیرنده']);
    expect(aliceGot.map((m) => m.text), ['و پاسخ از سمت گیرنده']);
    expect(bobAttachments, hasLength(1));
    expect(bobAttachments.single.bytes, photoBytes);
    // Acks drained both outboxes over the same channel.
    expect(alice.pendingCount, 0);
    expect(bob.pendingCount, 0);

    // Hang up the real call, then close the chat stack.
    final receiverDone = receiver.controller.done;
    await initiator.controller.hangUp().timeout(testOperationTimeout);
    await receiverDone.timeout(const Duration(seconds: 10));

    await alice.close();
    await bob.close();
    await portA.close();
    await portB.close();
    await initiator.dispose();
    await receiver.dispose();
    await waitForActiveRooms(server, 0);
    expect(server.activeRooms, 0);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
