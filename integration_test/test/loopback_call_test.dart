/// End-to-end loopback: two `CallController`s, one initiator and one
/// receiver, negotiating over a real `wss://` relay on real sockets — no
/// fakes below `HandshakingFakeMedia`, no `fake_async`.
library;

import 'dart:io';

import 'package:call_core/call_core.dart';
import 'package:signaling_server/signaling_server.dart';
import 'package:test/test.dart';

import 'support/call_stack.dart';

void main() {
  late Directory certDir;
  late SignalingRelayServer server;

  setUp(() async {
    certDir = await Directory.systemTemp.createTemp(
      'loopback_call_test_certs_',
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

  test(
    'both peers reach connected over the real wire, then hang up cleanly',
    () async {
      const callId = 'loopback-call-1';
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

      // Both peers must start concurrently: the initiator's start() only
      // resolves once its offer is acknowledged, which requires the
      // receiver to have already joined the relay room.
      final connected = await Future.wait([
        initiator.controller.start().then((_) => initiator.waitForConnected()),
        receiver.controller.start().then((_) => receiver.waitForConnected()),
      ]).timeout(const Duration(seconds: 10));

      expect(connected[0].phase, CallPhase.connected);
      expect(connected[1].phase, CallPhase.connected);

      final receiverDone = receiver.controller.done;
      final initiatorDone = initiator.controller.done;

      await initiator.controller.hangUp();

      final initiatorEnd = await initiatorDone.timeout(
        const Duration(seconds: 10),
      );
      final receiverEnd = await receiverDone.timeout(
        const Duration(seconds: 10),
      );

      expect(initiatorEnd.phase, CallPhase.ended);
      expect(initiatorEnd.endReason, CallEndReason.localHangup);
      expect(receiverEnd.phase, CallPhase.ended);
      expect(receiverEnd.endReason, CallEndReason.remoteHangup);

      await initiator.dispose();
      await receiver.dispose();

      await waitForActiveRooms(server, 0);
      expect(server.activeRooms, 0);
    },
  );
}
