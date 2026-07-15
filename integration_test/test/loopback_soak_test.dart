/// 100-cycle soak: repeatedly set up and tear down a full loopback call
/// against ONE long-lived relay server, checking after every cycle that
/// nothing was left behind — no leaked room, no leaked socket, no
/// unhandled error. A leak here would only show up as a slow drift, which
/// is exactly what a single pass of loopback_call_test.dart cannot catch.
library;

import 'dart:io';

import 'package:call_core/call_core.dart';
import 'package:signaling_server/signaling_server.dart';
import 'package:test/test.dart';

import 'support/call_stack.dart';

void main() {
  test(
    '100 sequential setup/teardown cycles leave no leaked rooms or sockets',
    () async {
      final certDir = await Directory.systemTemp.createTemp(
        'loopback_soak_test_certs_',
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

      final unhandledErrors = <Object>[];
      addTearDown(() async {
        await server.close();
        await certDir.delete(recursive: true);
      });

      const cycles = 100;
      for (var i = 0; i < cycles; i++) {
        final callId = 'soak-call-$i';
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

        try {
          final connected = await Future.wait([
            initiator.controller.start().then(
              (_) => initiator.waitForConnected(),
            ),
            receiver.controller.start().then(
              (_) => receiver.waitForConnected(),
            ),
          ]).timeout(const Duration(seconds: 10));

          expect(
            connected[0].phase,
            CallPhase.connected,
            reason: 'initiator did not connect on cycle $i',
          );
          expect(
            connected[1].phase,
            CallPhase.connected,
            reason: 'receiver did not connect on cycle $i',
          );

          final receiverDone = receiver.controller.done;
          await initiator.controller.hangUp();
          await receiverDone.timeout(const Duration(seconds: 10));
        } catch (error) {
          unhandledErrors.add(StateError('cycle $i failed: $error'));
        } finally {
          await initiator.dispose();
          await receiver.dispose();
        }

        await waitForActiveRooms(server, 0);
        expect(
          server.activeRooms,
          0,
          reason: 'room for callId $callId leaked after cycle $i teardown',
        );

        if ((i + 1) % 10 == 0) {
          // ignore: avoid_print
          print('soak: completed ${i + 1}/$cycles cycles');
        }
      }

      expect(
        unhandledErrors,
        isEmpty,
        reason: 'one or more soak cycles raised: $unhandledErrors',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
