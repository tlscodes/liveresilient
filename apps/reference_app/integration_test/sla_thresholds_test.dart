/// The test that produces NUMBERS instead of a pass/fail on connectivity.
///
/// WHY THIS EXISTS. The H2 matrix shapes the network and then runs
/// `loopback_call_test.dart`, which proves the call connects, RTP flows, ICE
/// restart recovers, and hangup is clean. Those are real properties, and none
/// of them is a threshold. A row reading `latency PASS` at 1800 ms RTT means
/// "it still connected" — it says nothing about whether a message arrived under
/// 500 ms, which is what threshold #4 actually asks.
///
/// So this test measures, and prints one machine-readable line:
///
///   SLA_SUMMARY {"ackRttP50Ms":…,"ackRttP95Ms":…,"recoveryMs":…,…}
///
/// `tools/t2/h2_run.sh` parses that line into the results table, so the table
/// stops being connectivity verdicts and starts being measurements taken under
/// a verified impairment.
///
/// WHAT IT DELIBERATELY DOES NOT DO
///
/// It does not assert the thresholds. The same number means different things
/// under different profiles — 400 ms is poor on a clean link and excellent at
/// 1800 ms RTT — so a hard-coded bar would either fail correct builds or pass
/// everything. Measuring belongs here; judging belongs to the harness that
/// knows which impairment is applied.
///
/// It does not claim audio quality. There is no audio analysis on this path, so
/// nothing here reports MOS or intelligibility. Timing and continuity are what
/// can honestly be measured, and they are what is measured.
///
/// NAMING IS PRECISE ON PURPOSE. The latency figure is `ackRtt`: the time for a
/// `callControl` frame to be sent and acknowledged over the real signalling
/// socket. WHICH PATH that socket takes depends on the rig, and the previous
/// version of this comment got that wrong: with the default in-process relay
/// the frame never leaves the app process, so ackRtt is process-loopback time
/// and says NOTHING about any shaped interface. Only when `E2E_RELAY_URI`
/// points at an off-device relay (h2_run.sh hosts one on the Mac) does the
/// ack round trip cross the bridge — and even then it is TCP, so it is only
/// impaired if the harness shapes the relay's TCP port too (h2_run.sh does,
/// via T2_SHAPE_TCP_PORT). It is NOT chat latency — the app's chat runs over
/// a WebRTC data channel this harness does not expose — and calling it that
/// would be the kind of small lie that makes a whole table untrustworthy.
/// TIMEOUT BUDGET, ADDED UP RATHER THAN GUESSED. The probe count comes from
/// the harness (`--dart-define=E2E_ACK_PROBES`, default 20); h2_run.sh sends
/// 40 on the >= 900 ms-delay profiles, where 20 probes end the call before
/// enough media has crossed the shaped bridge to satisfy its packet guard.
/// Worst case at the default (unshaped: probeAckTimeout floors at 15 s,
/// probeSpacing at 250 ms): connect 120 s + 20 probes x 15.25 s = 305 s +
/// restart 30 s + recovery deadline 60 s ~= 515 s ~= 8.6 min. Worst case at
/// the maximum the harness sends (the STRESS tier, loss60/extreme: connect
/// window max(E2E_CONNECT_BUDGET_S <= 450 s, E2E_STRESS_CONNECT_S ~432 s on
/// loss60 with the measured TCP-stall term) + 5 s, 40 probes at the DERIVED
/// ceilings — probeAckTimeout capped 30 s, probeSpacing capped 3 s —
/// restart send and recovery wait each raised to E2E_STRESS_RECOVERY_S
/// ~447 s): 455 + 40 x 33 + 447 + 447 = 2669 s ~= 44.5 min — inside the
/// 50 minutes declared below and h2_run.sh's 3200 s watchdog. (Measured, not just summed: the latency profile at 20
/// probes ran 134 s wall-clock, so the real per-probe cost is ~2 s, far
/// under the ceiling; the ceiling exists for the run where nothing answers.)
/// Any harness value above 40 probes, a connect budget above 300 s, bigger
/// stress windows, or bigger derived probe ceilings needs this sum redone
/// and a bigger @Timeout + watchdog, in the same change. The first version
/// declared 8 minutes, so on precisely the hostile profiles this file exists
/// to measure it would die at the timeout and print NO `SLA_SUMMARY` line at
/// all — losing the measurement exactly where it is most expensive to
/// obtain.
@Timeout(Duration(minutes: 50))
library;

// Evidence numbers are deliberately printed to the test log.
// ignore_for_file: avoid_print

// `TimeoutException` is caught by name in the probe loop, and it lives in
// dart:async. `Future.timeout` is available without importing anything, so the
// throw compiled while the `on TimeoutException` clause did not — the SDK
// hands you the exception but not the name for it. The same lesson as the
// `signaling` import below: what a file USES and what a file can NAME are
// separate questions in Dart.
import 'dart:async';
import 'dart:convert';

import 'package:call_core/call_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_webrtc/media_webrtc.dart' as mw;
// SignalType and OutboxOutcome live here, not in call_core. Importing
// e2e_support does NOT bring them along — Dart imports are not transitive, and
// a support file that happens to use a type does not re-export it.
import 'package:signaling/signaling.dart';

import 'support/e2e_support.dart';

/// Round trips in the latency sample. Enough for a p95 to carry meaning, few
/// enough that a 1800 ms link finishes inside the timeout. The harness raises
/// it per profile (see the timeout-budget dartdoc above): the probe window is
/// also the call-hold window, so on high-delay profiles more probes are what
/// puts enough media packets across the shaped bridge for h2_run.sh's
/// routing guard — the guard's floor never moves to meet the test.
const int ackProbes = int.fromEnvironment('E2E_ACK_PROBES', defaultValue: 20);

/// Space between probes, so the sample measures the link rather than a burst
/// queued behind itself.
///
/// On a bandwidth-shaped link the spacing itself is derived, because the
/// probe stream is a tenant of the same 30% control-plane margin the wire
/// budget reserves: one probe round is ~600 B of WSS frames (~4800 wire
/// bits), and the probes may claim at most a tenth of the link. At the
/// historic fixed 250 ms on the 16 kbit/s `narrow` profile the serially
/// acked probes alone outran the whole control margin, queued behind
/// themselves, and reported their own backlog as 55% "link" loss with a
/// 5 s p95 (measured 2026-08-06) — the instrument was measuring itself.
final Duration probeSpacing = () {
  final bw = e2eShapedConditions.bandwidthBps;
  if (bw == null || bw <= 0) return const Duration(milliseconds: 250);
  const probeWireBits = 4800;
  final ms = (probeWireBits * 1000 / (0.1 * bw)).round();
  return Duration(milliseconds: ms.clamp(250, 3000));
}();

/// How long one probe waits for its ack before being counted lost.
///
/// Fixed 15 s undercounts on the hostile profiles: signaling is TCP, so at
/// 60% loss an ack is usually LATE (retransmit doubling ladder), not gone —
/// a fixed window converts that delay into false "loss". Derived from the
/// same conditions model (one signaling round trip), floored at the
/// historic 15 s, capped at 30 s so a truly dead probe cannot stall the
/// phase unboundedly; the cap is part of the timeout-budget arithmetic
/// above the @Timeout annotation.
final Duration probeAckTimeout = () {
  final modelled = AdaptiveConnectionBudget.fromConditions(
    e2eShapedConditions,
  ).operationBudget(roundTrips: 1);
  return Duration(milliseconds: modelled.inMilliseconds.clamp(15000, 30000));
}();

/// STRESS-TIER MEASUREMENT WINDOWS (set by h2_run.sh on loss60/extreme
/// only; 0 = SLA tier, keep the historic windows). These size the
/// INSTRUMENT, never the criterion: h2_run.sh judges connectMs and
/// recoveryConnectedMs against bounds it derives INDEPENDENTLY from the
/// shaper's own rtt/loss/bandwidth, and a window smaller than those bounds
/// would clip the measurement to null exactly where it is most expensive
/// to obtain. Deliberately NOT derived from E2E_CONNECT_BUDGET_S: a
/// criterion inherited from the thing under test passes by construction.
const int stressConnectWindowS = int.fromEnvironment('E2E_STRESS_CONNECT_S');
const int stressRecoveryWindowS = int.fromEnvironment('E2E_STRESS_RECOVERY_S');

/// Window for the ICE-restart recovery wait (and the restart send, which is
/// part of the timed recovery): the historic 60 s / 30 s on the SLA tier,
/// the harness's independent recovery window on the stress tier.
const Duration recoveryWindow = stressRecoveryWindowS > 0
    ? Duration(seconds: stressRecoveryWindowS)
    : Duration(seconds: 60);
const Duration restartSendWindow = stressRecoveryWindowS > 0
    ? Duration(seconds: stressRecoveryWindowS)
    : Duration(seconds: 30);

double? _percentile(List<int> sortedMs, double p) {
  if (sortedMs.isEmpty) return null;
  return sortedMs[((sortedMs.length - 1) * p).round()].toDouble();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'SLA thresholds: connect time, signalling round trip, and ICE-restart '
    'recovery, measured under whatever impairment is applied',
    (tester) async {
      final mode = await resolveMediaMode();
      final relay = await LoopbackRelay.start();
      addTearDown(relay.close);

      final summary = <String, Object?>{
        'mediaMode': mode.name,
        'ackProbes': ackProbes,
      };
      final notes = <String>[];

      const callId = 'e2e-sla-call';
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
      addTearDown(() async {
        await initiator.dispose();
        await receiver.dispose();
      });

      // ---------------------------------------------------------------
      // 1. CONNECT TIME — the number a person experiences as "how long
      //    until the call is up", timed from before start() to the first
      //    connected state rather than from an internal milestone.
      // ---------------------------------------------------------------
      final connectStarted = DateTime.now();
      // One budget for the whole connect phase. The per-role wait inside
      // waitForConnected defaults to 20 s, which on the impaired profiles
      // fired BEFORE the test's own 120 s deadline: at 2085 ms RTT a TURN
      // allocation plus DTLS with one retransmit already exceeds it, so the
      // harness aborted while negotiation was still live and the row came
      // back INVALID instead of PASS or FAIL. The per-role wait now shares
      // the test's budget; it stays only to attribute a timeout to a role
      // with its last phase. This is a measurement window, not a threshold —
      // connectMs is still measured and still judged.
      const appConnectBudget = Duration(
        seconds: int.fromEnvironment('E2E_CONNECT_BUDGET_S', defaultValue: 120),
      );
      // Stress tier: the window is the LARGER of the app's own budget and
      // the harness's independent bound, so neither policy can clip the
      // other's measurement. Judging stays in h2_run.sh.
      const stressConnectWindow = Duration(seconds: stressConnectWindowS);
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
            // Named, because this backstop is what actually fires on the hostile
            // profiles: `start()` blocks through its own recovery loop, so the
            // per-role waits above may not even have begun when the budget runs
            // out — the 2026-08-06 loss60/extreme rows died here as an anonymous
            // "Future not completed" that hid which role and phase stalled.
            onTimeout: () => throw TimeoutException(
              'connect budget (${connectBudget.inSeconds}s + 5s) exhausted; '
              'initiator phase=${initiator.controller.state.phase.name} '
              'error=${initiator.controller.state.error}; '
              'receiver phase=${receiver.controller.state.phase.name} '
              'error=${receiver.controller.state.error}; '
              'initiator timeline: ${initiator.recentPhases()}; '
              'receiver timeline: ${receiver.recentPhases()}',
            ),
          );
      summary['connectMs'] = DateTime.now()
          .difference(connectStarted)
          .inMilliseconds;
      summary['bothConnected'] = connected.every(
        (s) => s.phase == CallPhase.connected,
      );

      // Closed-loop sentinel («هوشمندی v4» pillar 2): the same trend
      // detector the fabric acts on, instrumented over the live call so
      // the row records what the prediction was WORTH (lead time, freezes
      // that never came) — and one TREND line per second for the corpus.
      SentinelProbe? sentinel;
      final initiatorPort = initiator.port;
      if (initiatorPort != null) {
        sentinel = SentinelProbe(port: initiatorPort, role: 'initiator')
          ..start();
      } else {
        notes.add('no local port: sentinel not measured');
      }

      // ---------------------------------------------------------------
      // 2. SIGNALLING ROUND TRIP. `SignalingClient.send` completes when the
      //    frame is acknowledged, so awaiting it times a real out-and-back
      //    over the shaped link. `callControl` with an unrecognised action
      //    is a documented forward-compatible no-op on the decoding side,
      //    which is exactly what a probe should be: carried and acked by
      //    the real path, without asking the app to do anything.
      // ---------------------------------------------------------------
      final rtts = <int>[];
      var lost = 0;
      var errors = 0;

      for (var i = 0; i < ackProbes; i++) {
        final sent = DateTime.now();
        try {
          final outcome = await initiator.client
              .send(
                callId: callId,
                type: SignalType.callControl,
                payload: {'action': 'slaProbe', 'seq': i},
              )
              .timeout(probeAckTimeout);
          // A frame that expired or was dropped is loss, not latency.
          // Recording it as a fast round trip would flatter every hostile
          // profile — the ones the whole exercise exists to measure.
          if (outcome == OutboxOutcome.acknowledged) {
            rtts.add(DateTime.now().difference(sent).inMilliseconds);
          } else {
            lost++;
            notes.add('probe $i outcome=${outcome.name}');
          }
        } on TimeoutException {
          // The only failure that is honestly LOSS: the frame was sent and no
          // acknowledgement came back inside the window.
          lost++;
        } on Object catch (e) {
          // Anything else is a DEFECT, not an impairment. Counting a StateError
          // as packet loss reports a code bug to the harness as a network
          // result — the one place in this file where a real bug is guaranteed
          // to be blamed on the link.
          errors++;
          if (notes.length < 5) notes.add('probe $i threw: $e');
        }
        await Future<void>.delayed(probeSpacing);
      }

      rtts.sort();
      summary['ackRttSamples'] = rtts.length;
      summary['ackRttLost'] = lost;
      summary['ackRttLossPct'] = (lost * 100 / ackProbes).round();
      // Separate on purpose: loss is a property of the link, errors are a
      // property of the build. A row with errors > 0 is not a threshold result.
      summary['ackProbeErrors'] = errors;
      summary['ackRttMinMs'] = rtts.isEmpty ? null : rtts.first;
      summary['ackRttP50Ms'] = _percentile(rtts, 0.50);
      summary['ackRttP95Ms'] = _percentile(rtts, 0.95);
      summary['ackRttMaxMs'] = rtts.isEmpty ? null : rtts.last;

      // ---------------------------------------------------------------
      // 3. RECOVERY. An ICE restart is the recovery the app actually
      //    performs when a path dies, so it is what gets timed: from the
      //    restart request to the first fresh local candidate, and on to a
      //    connected port.
      //
      //    This is a PROXY for threshold #7, not the threshold. A real
      //    outage must be DETECTED first, and detection time is not
      //    measured here. Reported under its own name so the two are never
      //    silently conflated.
      // ---------------------------------------------------------------
      final port = initiator.port;
      if (port == null) {
        notes.add('no local port: recovery not measured');
        summary['recoveryFirstCandidateMs'] = null;
        summary['recoveryConnectedMs'] = null;
      } else {
        final fresh = <mw.IceCandidate>[];
        final candidateSub = port.localCandidates.listen(fresh.add);
        final statuses = <String>[];
        final statusSub = port.connectionStatus.listen(
          (s) => statuses.add(s.name),
        );

        final restartStarted = DateTime.now();
        try {
          await receiver.signalingAdapter
              .send(const SendRestartRequestCommand())
              .timeout(restartSendWindow);

          final deadline = DateTime.now().add(recoveryWindow);
          while (fresh.isEmpty && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          summary['recoveryFirstCandidateMs'] = fresh.isEmpty
              ? null
              : DateTime.now().difference(restartStarted).inMilliseconds;

          while (initiator.controller.state.phase != CallPhase.connected &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          summary['recoveryConnectedMs'] =
              initiator.controller.state.phase == CallPhase.connected
              ? DateTime.now().difference(restartStarted).inMilliseconds
              : null;
          summary['recoveryNewCandidates'] = fresh.length;
          summary['recoveryStatusLog'] = statuses;
        } on Object catch (e) {
          notes.add('recovery not measured: $e');
          summary['recoveryFirstCandidateMs'] = null;
          summary['recoveryConnectedMs'] = null;
          // Same keys on every path. A summary whose SHAPE varies by branch
          // makes the downstream parser guess, and a parser that guesses will
          // eventually guess wrong on the row that matters.
          summary['recoveryNewCandidates'] = fresh.length;
          summary['recoveryStatusLog'] = statuses;
        } finally {
          await candidateSub.cancel();
          await statusSub.cancel();
        }
      }

      // ---------------------------------------------------------------
      // 4. STILL ALIVE? The cheapest and most important question. A run
      //    where every latency looks fine and the call has quietly died is
      //    a failure, and only this line catches it.
      // ---------------------------------------------------------------
      summary['stillConnectedAtEnd'] =
          initiator.controller.state.phase == CallPhase.connected;
      // Adaptation evidence: what the PRODUCT decided on this link, not
      // just what happened to it. Counts + final ladder position per side;
      // the decision strings ride the notes-adjacent log for forensics.
      summary['adaptationDecisions'] =
          initiator.adaptationDecisionLog.length +
          receiver.adaptationDecisionLog.length;
      summary['adaptationProfileInitiator'] =
          initiator.adaptationDriver?.profile.name;
      summary['adaptationProfileReceiver'] =
          receiver.adaptationDriver?.profile.name;
      summary['adaptationLog'] = [
        ...initiator.adaptationDecisionLog.map((d) => 'initiator: $d'),
        ...receiver.adaptationDecisionLog.map((d) => 'receiver: $d'),
      ];
      if (sentinel != null) {
        summary.addAll(sentinel.stopAndReport());
      }
      summary['notes'] = notes;

      // One line, parseable, prefixed so a log scraper cannot confuse it with
      // Flutter's own output. This is the whole point of the file.
      print('SLA_SUMMARY ${jsonEncode(summary)}');

      // The only assertions are ones that hold under EVERY profile. A threshold
      // assertion here would either fail correct builds on a hostile profile or
      // pass everything on a clean one.
      expect(
        summary['bothConnected'],
        isTrue,
        reason: 'the call never connected, so nothing above was measured',
      );
      // NOT `rtts.length + lost == ackProbes` — that was tautological: the loop
      // increments exactly one of the two per iteration, so it could never
      // fail. An assertion that cannot fail is decoration. What can actually go
      // wrong is producing no measurement at all, so that is what is asserted.
      expect(
        rtts.isNotEmpty || lost > 0,
        isTrue,
        reason: 'no probe produced either a sample or a loss',
      );

      // The line the file's own comment claimed "only this catches" — and then
      // did not check. A run whose latencies all look excellent because the
      // call quietly died is the most flattering failure available, and the
      // only one a table of green numbers cannot show.
      expect(
        summary['stillConnectedAtEnd'],
        isTrue,
        reason:
            'the call was not connected at the end: every number above '
            'describes a session that did not survive being measured',
      );

      // Percentiles must be ordered. A p95 below the p50 means the percentile
      // arithmetic is wrong, and a silently wrong statistic is worse than a
      // missing one — every threshold judgement downstream reads p95.
      final p50 = summary['ackRttP50Ms'] as double?;
      final p95 = summary['ackRttP95Ms'] as double?;
      if (p50 != null && p95 != null) {
        expect(
          p95,
          greaterThanOrEqualTo(p50),
          reason: 'p95 below p50 means the percentile computation is broken',
        );
      }

      // Recovery, when it was measured at all, must be a positive duration
      // that actually reached connected. Reporting 0 ms or a null-with-a-time
      // would flatter threshold #7 exactly where it matters most.
      final recovery = summary['recoveryConnectedMs'] as int?;
      if (recovery != null) {
        expect(
          recovery,
          greaterThan(0),
          reason: 'a recovery that took no time did not happen',
        );
        expect(
          summary['recoveryNewCandidates'],
          isNot(0),
          reason:
              'connected again without a single fresh candidate means no new '
              'ICE generation started — the restart did not really occur',
        );
      }
    },
  );
}
