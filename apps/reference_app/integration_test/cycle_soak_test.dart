/// 100-cycle setup/teardown soak of the FULL stack (real signaling client
/// over the in-process TLS relay + real `FlutterWebRtcPeerConnectionPort`)
/// against one long-lived relay server.
///
/// After every cycle: both controllers are terminal, both media ports are
/// closed (further use throws), and the relay room count is back to 0.
///
/// Leak check (honest under a JIT VM where absolute RSS is noisy): the
/// steady-state two-run comparison proven in
/// `server/signaling_server/test/load_soak_test.dart` — RSS after the
/// second half of identical cycles must not grow more than a fixed bound
/// over RSS after the first half. Object-level signals (ports closed,
/// rooms drained) back the number. One machine-readable JSON summary line
/// is printed at the end.
library;

// Evidence numbers are deliberately printed to the test log.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:call_core/call_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e_support.dart';

/// Same steady-state bound as the relay's own G8 soak suite.
const int maxSteadyStateRssGrowthBytes = 64 * 1024 * 1024;

const int totalCycles = 100;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    '100 full-stack setup/teardown cycles: terminal controllers, closed '
    'ports, drained rooms, steady-state RSS',
    (tester) async {
      final mode = await resolveMediaMode();
      final relay = await LoopbackRelay.start();
      addTearDown(relay.close);

      final errors = <String>[];
      final rssStart = ProcessInfo.currentRss;
      var rssMid = 0;
      final started = DateTime.now();

      for (var i = 0; i < totalCycles; i++) {
        final callId = 'e2e-soak-call-$i';
        final initiator = E2eCallStack.build(
          endpoint: relay.endpoint,
          callId: callId,
          role: CallRole.initiator,
          mode: mode,
        );
        final receiver = E2eCallStack.build(
          endpoint: relay.endpoint,
          callId: callId,
          role: CallRole.receiver,
          mode: mode,
        );

        try {
          final connected = await Future.wait([
            initiator.controller.start().then(
              (_) => initiator.waitForConnected(),
            ),
            receiver.controller.start().then(
              (_) => receiver.waitForConnected(),
            ),
          ]).timeout(const Duration(seconds: 30));
          if (connected[0].phase != CallPhase.connected ||
              connected[1].phase != CallPhase.connected) {
            errors.add(
              'cycle $i: did not connect '
              '(${connected[0].phase.name}/${connected[1].phase.name})',
            );
          }

          final receiverDone = receiver.controller.done;
          await initiator.controller.hangUp().timeout(
            const Duration(seconds: 10),
          );
          await receiverDone.timeout(const Duration(seconds: 10));
        } catch (error) {
          errors.add('cycle $i failed: $error');
        } finally {
          await initiator.dispose();
          await receiver.dispose();
        }

        // Object-level teardown evidence, every cycle.
        if (!initiator.controller.state.isTerminal) {
          errors.add(
            'cycle $i: initiator not terminal '
            '(${initiator.controller.state.phase.name})',
          );
        }
        if (!receiver.controller.state.isTerminal) {
          errors.add(
            'cycle $i: receiver not terminal '
            '(${receiver.controller.state.phase.name})',
          );
        }
        for (final (side, port) in [
          ('initiator', initiator.port),
          ('receiver', receiver.port),
        ]) {
          if (port == null) {
            errors.add('cycle $i: $side port was never created');
            continue;
          }
          try {
            await port.readStatsCounters();
            errors.add(
              'cycle $i: $side port still usable after teardown '
              '(not closed)',
            );
          } on StateError {
            // Expected: the port is closed.
          }
        }

        await waitForActiveRooms(relay.server, 0);
        final localServer = relay.server;
        if (localServer != null && localServer.activeRooms != 0) {
          errors.add(
            'cycle $i: relay room leaked '
            '(activeRooms=${localServer.activeRooms})',
          );
        }

        if (i == (totalCycles ~/ 2) - 1) {
          rssMid = ProcessInfo.currentRss;
        }
        if ((i + 1) % 10 == 0) {
          print(
            'soak: ${i + 1}/$totalCycles cycles, '
            'errors=${errors.length}, '
            'rss=${ProcessInfo.currentRss} bytes, '
            'elapsed=${DateTime.now().difference(started).inSeconds}s',
          );
        }
      }

      final rssEnd = ProcessInfo.currentRss;
      final steadyStateGrowth = rssEnd - rssMid;
      final elapsedMs = DateTime.now().difference(started).inMilliseconds;

      final summary = <String, Object>{
        'cycles': totalCycles,
        'errors': errors.length,
        'errorMessages': errors,
        'mediaMode': mode.name,
        'rssStartBytes': rssStart,
        'rssAfterFirstHalfBytes': rssMid,
        'rssAfterSecondHalfBytes': rssEnd,
        'steadyStateRssGrowthBytes': steadyStateGrowth,
        'rssTotalDeltaBytes': rssEnd - rssStart,
        'elapsedMs': elapsedMs,
        'avgCycleMs': (elapsedMs / totalCycles).round(),
      };
      print('SOAK_SUMMARY ${jsonEncode(summary)}');

      expect(errors, isEmpty, reason: 'soak cycles reported errors: $errors');
      expect(
        steadyStateGrowth,
        lessThan(maxSteadyStateRssGrowthBytes),
        reason:
            'steady-state RSS grew $steadyStateGrowth bytes between '
            'identical halves (bound $maxSteadyStateRssGrowthBytes)',
      );
    },
    timeout: const Timeout(Duration(minutes: 25)),
  );
}
