/// G3 gate — REAL media loopback E2E on one machine, one app process:
/// two full call stacks (real `SignalingClient` over an in-process TLS
/// relay, real `FlutterWebRtcPeerConnectionPort` over the platform WebRTC
/// engine) drive invite -> accept -> connected, prove RTP actually flows
/// (inbound packetsReceived strictly increasing on BOTH peers), survive a
/// mid-call ICE restart, and hang up cleanly.
///
/// Every claim below is printed as a measured number; the media source that
/// actually ran (real capture vs documented no-capture fallback) is
/// reported by `resolveMediaMode`.
///
/// The library-level @Timeout mirrors the survival gates: flutter_test's
/// default 5-minute per-test cap silently undercut the stress connect
/// budget (455 s) — measured 2026-08-09, loss60: the draw died at 05:00
/// with the budget still open.
@Timeout(Duration(minutes: 45))
library;

// Evidence numbers are deliberately printed to the test log.
// ignore_for_file: avoid_print

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_webrtc/media_webrtc.dart' as mw;

import 'support/e2e_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late LoopbackRelay relay;

  setUp(() async {
    relay = await LoopbackRelay.start();
  });

  tearDown(() async {
    await relay.close();
  });

  testWidgets(
    'real-media loopback: connected both sides, RTP flows, ICE restart '
    'recovers, clean hangup',
    (tester) async {
      final mode = await resolveMediaMode();

      const callId = 'e2e-loopback-call-1';
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
        // Both peers start concurrently: the initiator's offer is only
        // deliverable once the receiver has joined the relay room.
        // Connect gets the same budget the survival gates honor
        // (E2E_CONNECT_BUDGET_S / E2E_STRESS_CONNECT_S): under heavy loss
        // the whole point of the draw is the retry window, and a flat 30s
        // cap here silently discarded the budget the harness granted.
        const appConnectBudget = Duration(
          seconds: int.fromEnvironment(
            'E2E_CONNECT_BUDGET_S',
            defaultValue: 30,
          ),
        );
        const stressConnectWindow = Duration(
          seconds: int.fromEnvironment('E2E_STRESS_CONNECT_S'),
        );
        final connectBudget = stressConnectWindow > appConnectBudget
            ? stressConnectWindow
            : appConnectBudget;
        final connected =
            await Future.wait([
              initiator.controller.start().then(
                (_) => initiator.waitForConnected(timeout: connectBudget),
              ),
              receiver.controller.start().then(
                (_) => receiver.waitForConnected(timeout: connectBudget),
              ),
            ]).timeout(
              connectBudget + const Duration(seconds: 5),
              onTimeout: () => throw TimeoutException(
                'connect budget (${connectBudget.inSeconds}s + 5s) exhausted',
              ),
            );

        expect(connected[0].phase, CallPhase.connected);
        expect(connected[1].phase, CallPhase.connected);
        print('e2e: both peers connected (real signaling + real WebRTC)');

        final initiatorPort = initiator.port!;
        final receiverPort = receiver.port!;

        // ------------------------------------------------------------------
        // Packet-flow evidence (only claimable with real captured audio).
        // ------------------------------------------------------------------
        if (mode == MediaMode.realAudio) {
          final samples = await Future.wait([
            samplePacketsReceivedStrictlyIncreasing(
              initiatorPort,
              label: 'initiator (pre-restart)',
            ),
            samplePacketsReceivedStrictlyIncreasing(
              receiverPort,
              label: 'receiver (pre-restart)',
            ),
          ]);
          print(
            'e2e evidence pre-restart: '
            'initiator packetsReceived samples=${samples[0]} '
            'receiver packetsReceived samples=${samples[1]}',
          );
        } else {
          print(
            'e2e DEFERRED: packet-flow criteria skipped — '
            'no local audio source ($mediaModeReason); '
            'proved: ICE/DTLS connected over real signaling only.',
          );
        }

        // ------------------------------------------------------------------
        // ICE restart mid-call: the receiver asks for a restart over the
        // real signaling wire; the initiator renegotiates with
        // iceRestart=true. Evidence a new ICE generation really started:
        // fresh local candidates are gathered and emitted by the
        // initiator's port (gathering had already completed).
        // ------------------------------------------------------------------
        final restartCandidates = <mw.IceCandidate>[];
        final candidateSub = initiatorPort.localCandidates.listen(
          restartCandidates.add,
        );
        final statusLog = <String>[];
        final statusSub = initiatorPort.connectionStatus.listen(
          (status) => statusLog.add(status.name),
        );

        await receiver.signalingAdapter
            .send(const SendRestartRequestCommand())
            .timeout(const Duration(seconds: 10));

        final restartDeadline = DateTime.now().add(const Duration(seconds: 15));
        while (restartCandidates.isEmpty &&
            DateTime.now().isBefore(restartDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          restartCandidates,
          isNotEmpty,
          reason:
              'ICE restart produced no new local candidates '
              '(no new ICE generation observed)',
        );

        // Negotiation settled: the initiator's tracked signaling state is
        // back to stable (offer sent -> answer applied).
        while (initiator.media.signalingState != MediaSignalingState.stable &&
            DateTime.now().isBefore(restartDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          initiator.media.signalingState,
          MediaSignalingState.stable,
          reason: 'ICE restart negotiation did not settle',
        );

        expect(
          initiator.controller.state.phase,
          CallPhase.connected,
          reason:
              'initiator left connected after ICE restart; '
              'status transitions: $statusLog',
        );
        expect(
          receiver.controller.state.phase,
          CallPhase.connected,
          reason: 'receiver left connected after ICE restart',
        );
        print(
          'e2e evidence restart: newLocalCandidates='
          '${restartCandidates.length} '
          'initiatorStatusTransitions=$statusLog '
          'bothPhases=connected',
        );

        if (mode == MediaMode.realAudio) {
          final postSamples = await Future.wait([
            samplePacketsReceivedStrictlyIncreasing(
              initiatorPort,
              label: 'initiator (post-restart)',
            ),
            samplePacketsReceivedStrictlyIncreasing(
              receiverPort,
              label: 'receiver (post-restart)',
            ),
          ]);
          print(
            'e2e evidence post-restart: '
            'initiator packetsReceived samples=${postSamples[0]} '
            'receiver packetsReceived samples=${postSamples[1]}',
          );
        }

        await candidateSub.cancel();
        await statusSub.cancel();

        // ------------------------------------------------------------------
        // Clean hangup: both controllers reach terminal `ended` with the
        // correct reasons, then the relay room drains.
        // ------------------------------------------------------------------
        final initiatorDone = initiator.controller.done;
        final receiverDone = receiver.controller.done;

        await initiator.controller.hangUp().timeout(
          const Duration(seconds: 10),
        );

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
        print(
          'e2e: clean hangup — initiator=localHangup, '
          'receiver=remoteHangup',
        );
      } finally {
        await initiator.dispose();
        await receiver.dispose();
      }

      await waitForActiveRooms(relay.server, 0);
      final localServer = relay.server;
      if (localServer != null) {
        expect(localServer.activeRooms, 0);
        print('e2e: relay rooms drained to 0 after teardown');
      } else {
        print('e2e: remote relay — room drain not observable from here');
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
