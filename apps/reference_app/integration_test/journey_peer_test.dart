/// The far side of the app journey: a headless REAL call stack on the phone,
/// placing the call as initiator under a fixed key, over the shaped link.
///
/// The Mac reference app joins this key through its own "Join with key"
/// dialog (integration_test/journey_driver_test.dart); tools/t2/journey_run.sh
/// runs both and shapes bridge100 in between. This side prints one
/// `JOURNEY_PEER` line per event so the orchestrator can read connect time,
/// counters and the end reason off the log.
///
/// Defines:
///   E2E_RELAY_URI        `wss://192.168.2.1:4443/`, the Mac's bridge address (required)
///   JOURNEY_CALL_KEY     the relay session id both sides use  (required)
///   JOURNEY_HOLD_S       seconds to hold the call once connected (45)
///   E2E_CONNECT_BUDGET_S connect + reconnect budget in seconds (300)
@Timeout(Duration(minutes: 15))
library;

// Evidence lines are deliberately printed to the test log.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:call_core/call_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e_support.dart';

const String journeyCallKey = String.fromEnvironment(
  'JOURNEY_CALL_KEY',
  defaultValue: '',
);
const int journeyHoldS = int.fromEnvironment(
  'JOURNEY_HOLD_S',
  defaultValue: 45,
);
const int journeyConnectBudgetS = int.fromEnvironment(
  'E2E_CONNECT_BUDGET_S',
  defaultValue: 300,
);

/// Plain HTTP on the Mac's bridge address, served by the orchestrator from
/// its run directory; dart:io's HttpClient is not subject to App Transport
/// Security, so no plist change is needed for the phone to poll it.
const String journeyGoUrl = String.fromEnvironment(
  'JOURNEY_GO_URL',
  defaultValue: '',
);

Future<void> _waitForGo() async {
  if (journeyGoUrl.isEmpty) return;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  final deadline = DateTime.now().add(const Duration(minutes: 10));
  try {
    while (DateTime.now().isBefore(deadline)) {
      try {
        final response = await client
            .getUrl(Uri.parse(journeyGoUrl))
            .then((request) => request.close())
            .timeout(const Duration(seconds: 5));
        await response.drain<void>();
        if (response.statusCode == 200) return;
      } on Object {
        // Not raised yet, or the server is not up: poll again.
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw TimeoutException('GO was never raised at $journeyGoUrl');
  } finally {
    client.close(force: true);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('journey peer: the phone places the call under the shaped link', (
    tester,
  ) async {
    expect(
      e2eUsesRemoteRelay,
      isTrue,
      reason: 'E2E_RELAY_URI must name the relay on the Mac',
    );
    expect(journeyCallKey, isNotEmpty, reason: 'JOURNEY_CALL_KEY is required');

    final relay = await LoopbackRelay.start(); // remote: no in-process server
    final mode = await resolveMediaMode();
    final stack = E2eCallStack.build(
      endpoint: relay.endpoint,
      callId: journeyCallKey,
      role: CallRole.initiator,
      mode: mode,
    );
    print(
      'JOURNEY_PEER key=$journeyCallKey relay=${relay.endpoint} '
      'media=${mode.name} hold=${journeyHoldS}s budget=${journeyConnectBudgetS}s',
    );
    // Do not offer into an empty room. The first run (normal profile,
    // 2026-09-03) sent the offer at 0 s, the Mac app joined ~3 s later, the
    // relay does not buffer, and neither side ever saw the other: the phone
    // re-offered only at its 196 s watchdog, by which time the app had given
    // up at 61 s. So the orchestrator raises GO only once the app has joined.
    await _waitForGo();
    final startedAt = DateTime.now();
    print('JOURNEY_PEER go: starting the call');
    unawaited(stack.controller.start());
    try {
      final connected = await stack.waitForConnected(
        timeout: Duration(seconds: journeyConnectBudgetS),
      );
      final connectMs = DateTime.now().difference(startedAt).inMilliseconds;
      print(
        'JOURNEY_PEER connected phase=${connected.phase.name} '
        'connect_ms=$connectMs',
      );

      final holdUntil = DateTime.now().add(Duration(seconds: journeyHoldS));
      while (DateTime.now().isBefore(holdUntil)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final port = stack.port;
        final counters = port == null
            ? null
            : await port.readStatsCounters().timeout(
                const Duration(seconds: 5),
                onTimeout: () => null,
              );
        final elapsed = DateTime.now().difference(startedAt).inSeconds;
        print(
          'JOURNEY_PEER sample t=${elapsed}s '
          'phase=${stack.controller.state.phase.name} '
          'rx=${counters?.packetsReceived} lost=${counters?.packetsLost} '
          'tx=${counters?.packetsSent}',
        );
        if (stack.controller.state.isTerminal) break;
      }

      if (!stack.controller.state.isTerminal) {
        await stack.controller.hangUp();
      }
      final done = await stack.controller.done.timeout(
        const Duration(seconds: 30),
      );
      print(
        'JOURNEY_PEER ended phase=${done.phase.name} '
        'reason=${done.endReason?.name} phases=${stack.recentPhases()}',
      );
    } on Object catch (error) {
      print(
        'JOURNEY_PEER failed error=$error '
        'last_phase=${stack.controller.state.phase.name} '
        'phases=${stack.recentPhases()}',
      );
      rethrow;
    } finally {
      await stack.dispose();
      await relay.close();
    }
  });
}
