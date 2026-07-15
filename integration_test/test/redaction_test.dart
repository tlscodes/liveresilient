/// Wires a [RedactingLogger] around one real call cycle's app-side logging
/// (state transitions plus a deliberately SDP-bearing debug line) and
/// proves the sensitive payload — the raw multi-line SDP body and the IP
/// address embedded in it — never reaches the captured log, while plain
/// control text (phase names, roles, end reasons) survives unredacted.
library;

import 'dart:io';

import 'package:call_core/call_core.dart';
import 'package:security/security.dart';
import 'package:signaling_server/signaling_server.dart';
import 'package:test/test.dart';

import 'support/call_stack.dart';

void main() {
  test(
    'call-cycle logging never leaks SDP bodies or IPs; control text survives',
    () async {
      final certDir = await Directory.systemTemp.createTemp(
        'redaction_test_certs_',
      );
      final certificate = await ensureDevCertificate(
        directoryPath: certDir.path,
      );
      final security = SecurityContext()
        ..useCertificateChain(certificate.certificatePath)
        ..usePrivateKey(certificate.privateKeyPath);
      final server = await SignalingRelayServer.bind(
        security: security,
        port: 0,
      );
      addTearDown(() async {
        await server.close();
        await certDir.delete(recursive: true);
      });

      final captured = <String>[];
      final logger = RedactingLogger(
        (level, redactedMessage) =>
            captured.add('[${level.name}] $redactedMessage'),
        minimumLevel: LogLevel.debug,
      );

      const callId = 'redaction-call-1';
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
      addTearDown(() async {
        await initiator.dispose();
        await receiver.dispose();
      });

      void logTransitions(CallStack stack) {
        stack.controller.states.listen((CallState state) {
          final endReason = state.endReason;
          logger.debug(
            'call $callId role=${stack.role.name} phase=${state.phase.name}'
            '${endReason != null ? ' endReason=${endReason.name}' : ''}',
          );
        });
      }

      logTransitions(initiator);
      logTransitions(receiver);

      // A raw SDP body, exactly as an app-layer bug might try to dump it
      // straight into a log line: begins with v=0 and carries a real IP in
      // its origin, connection, and candidate lines.
      const rawSdp =
          'v=0\r\n'
          'o=- 1 1 IN IP4 127.0.0.1\r\n'
          's=-\r\n'
          't=0 0\r\n'
          'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
          'c=IN IP4 127.0.0.1\r\n'
          'a=candidate:1 1 UDP 2122260223 127.0.0.1 51000 typ host\r\n';

      // The correct app-side pattern: run the SDP-specific redactor first,
      // then hand the result to the logger (which redacts again — defense
      // in depth) — never pass the raw body straight into a log call.
      logger.debug(
        'offer sdp for call $callId: ${LogRedactor.redactSdp(rawSdp)}',
      );

      await Future.wait([
        initiator.controller.start().then((_) => initiator.waitForConnected()),
        receiver.controller.start().then((_) => receiver.waitForConnected()),
      ]).timeout(const Duration(seconds: 10));

      final receiverDone = receiver.controller.done;
      await initiator.controller.hangUp();
      await receiverDone.timeout(const Duration(seconds: 10));

      final joined = captured.join('\n');

      // The sensitive payload never survives: neither the raw multi-line
      // SDP body nor the IP address it carries appears anywhere in the
      // captured log.
      expect(joined, isNot(contains(rawSdp)));
      expect(joined, isNot(contains('127.0.0.1')));

      // Harmless control text is untouched by redaction.
      expect(
        captured.any(
          (line) =>
              line.contains('role=initiator') &&
              line.contains('phase=connected'),
        ),
        isTrue,
        reason: 'expected an unredacted initiator connected transition line',
      );
      expect(
        captured.any(
          (line) =>
              line.contains('role=receiver') &&
              line.contains('phase=ended') &&
              line.contains('endReason=remoteHangup'),
        ),
        isTrue,
        reason: 'expected an unredacted receiver remoteHangup end line',
      );
    },
  );
}
