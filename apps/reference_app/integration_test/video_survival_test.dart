/// VIDEO SURVIVAL GATE — a camera-quality recording must DELIVER intact
/// over the call's own transport, on the video lane.
///
/// THE LANE (2026-08-08): BinaryStreamTransfer on a SECOND negotiated data
/// channel (own SCTP stream — a stalled video chunk never blocks chat):
/// raw binary frames (no base64 tax), windowed ack-paced streaming,
/// drain-aware retransmits, content-addressed resume (sha-256 id + HAVE
/// bitmap), crc32 per chunk and whole-object sha-256 at the end.
///
/// ARTIFACT SIZING, stated honestly. The reference recording is a 3-minute
/// iPhone 11 Pro clip (1080p60 HEVC ~= 350-450 MB). Holding sender copy +
/// receiver reassembly of the full clip in ONE process (both peers live on
/// the phone in this rig) costs ~1 GB of RAM, so this gate streams a
/// DETERMINISTIC PROXY sized per profile and records measured throughput —
/// the full-size single-buffer run needs a streaming source seam and is
/// recorded as the lane's next step, not silently skipped:
///   unshaped fast rows (clean/normal):        64 MiB
///   shaped but loss-free (latency/bandwidth/
///   narrow):                                   8 MiB
///   lossy rows (loss10/loss60/extreme):        4 MiB
/// VID_SUMMARY carries sizeBytes/ms/throughputKbps/sha256Ok so every row
/// states exactly what it measured and the extrapolation is arithmetic,
/// not faith.
///
/// TIMEOUT BUDGET: connect <= 455 s + renegotiation + transfer window
/// (<= 25 min on the slowest shaped row at its derived floor) — inside the
/// 45 minutes declared below and h2_run.sh's 3200 s watchdog.
@Timeout(Duration(minutes: 45))
library;

// Evidence numbers are deliberately printed to the test log.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:call_core/call_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_webrtc/media_webrtc.dart' as mw;
import 'package:messaging/messaging.dart';
import 'package:messaging_webrtc_adapter/messaging_webrtc_adapter.dart';

import 'support/datagram_lane_port.dart';
import 'support/e2e_support.dart';

/// Proxy size per the header's honesty note.
int videoBytesForConditions() {
  final c = e2eShapedConditions;
  if (c.bandwidthBps == null && c.loss == 0 && c.rtt.inMilliseconds < 500) {
    return 64 * 1024 * 1024;
  }
  // Bandwidth-shaped rows: the proxy must FIT the physics — what the video
  // lane's 30% share moves in ~12 minutes (measured 2026-08-08: a fixed
  // 8 MiB proxy on the 32 kbit/s row needs ~111 min of wire time and the
  // window cap correctly refused to pretend otherwise). Floor 512 KiB so
  // the row still proves a real multi-chunk transfer.
  final bw = c.bandwidthBps;
  if (bw != null && bw > 0) {
    final fits = (0.3 * bw * 720 / 8).round();
    return fits.clamp(512 * 1024, 8 * 1024 * 1024);
  }
  if (c.loss == 0) return 8 * 1024 * 1024;
  return 4 * 1024 * 1024;
}

/// Retransmit pacing: at least one chunk's drain time on constrained
/// links (the attachment lane's burned lesson), else a few op costs.
Duration videoRetransmitAfter(int chunkBytes) {
  final budget = AdaptiveConnectionBudget.fromConditions(e2eShapedConditions);
  var pace = budget.operationBudget(roundTrips: 1) ~/ 2;
  if (pace < const Duration(seconds: 2)) pace = const Duration(seconds: 2);
  // The deadline must OUTLIVE a healthy ack round trip, or every fresh
  // chunk is resent exactly once and Karn's rule can never obtain a
  // clean RTT sample to adapt from (measured 2026-08-08 latency row:
  // srtt=0 after 580 s, 391 resends for 367 acks, ~1 chunk per RTT).
  final rtt = e2eShapedConditions.rtt;
  if (rtt * 2 > pace) pace = rtt * 2;
  final bw = e2eShapedConditions.bandwidthBps;
  if (bw != null && bw > 0) {
    final drain = Duration(
      milliseconds: (chunkBytes * 8 * 1000 / (0.3 * bw) * 1.5).round(),
    );
    if (drain > pace) pace = drain;
  }
  return pace;
}

/// Transfer window: serialization on the link share x2 (sequential-queue
/// margin) + connect-scale slack, floored generously; capped at the
/// @Timeout's transfer allowance.
Duration videoWindow(int bytes) {
  final bw = e2eShapedConditions.bandwidthBps;
  var ms = 120000;
  if (bw != null && bw > 0) {
    ms += 2 * (bytes * 8 * 1000 / (0.3 * bw)).round();
  } else {
    // No bandwidth cap: throughput is BDP-limited — the window carries at
    // most windowSize x chunk per round trip (measured 2026-08-08: the
    // latency row got a 152 s window while 8 MiB at rtt 1.8 s needs
    // ~240 s at 4x16 KiB per round trip). x2 margin for ack jitter.
    final rttMs = e2eShapedConditions.rtt.inMilliseconds.clamp(50, 5000);
    final perRoundBytes = 4 * 16 * 1024;
    ms += 2 * (bytes / perRoundBytes * rttMs).round();
  }
  final loss = e2eShapedConditions.loss.clamp(0.0, 0.9);
  ms = (ms / ((1 - loss) * (1 - loss))).round();
  return Duration(milliseconds: ms.clamp(120000, 1500000));
}

Uint8List deterministicVideo(int length) {
  final bytes = Uint8List(length);
  var x = 0x2545F491;
  for (var i = 0; i < length; i++) {
    // xorshift — fast, deterministic, incompressible-ish like real video.
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    bytes[i] = x & 0xff;
  }
  return bytes;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Video survival: a camera-quality proxy clip delivers intact on the '
    'binary lane under whatever impairment is applied',
    (tester) async {
      final mode = await resolveMediaMode();
      final relay = await LoopbackRelay.start();
      addTearDown(relay.close);

      final sizeBytes = videoBytesForConditions();
      // Chunk size from link physics: one chunk's serialization must stay
      // ~2 s of wire time on a bandwidth-capped link, or every queued
      // chunk starves the call's heartbeats (measured 2026-08-08 narrow,
      // 16 KiB on 16 kbit/s = 8 s per chunk: the call died twice
      // mid-transfer). Unshaped links keep the full 16 KiB.
      final bwBps = e2eShapedConditions.bandwidthBps;
      final chunkBytes = bwBps != null && bwBps > 0
          ? (bwBps / 8 * 2).round().clamp(2 * 1024, 16 * 1024)
          : 16 * 1024;
      final summary = <String, Object?>{
        'mediaMode': mode.name,
        'sizeBytes': sizeBytes,
        'chunkBytes': chunkBytes,
      };

      const callId = 'e2e-video-call';
      final initiator = E2eCallStack.build(
        endpoint: relay.endpoint,
        callId: callId,
        role: CallRole.initiator,
        mode: mode,
      );
      // RECEIVER AUDIO OFF on bandwidth-capped links (2026-08-08, pcap-
      // measured): four audio stream-crossings share one shaped pipe, and
      // even the Opus floor (6k @ 120ms = 8.7k wire) x4 = 34.7k exceeds
      // the 32k narrow pipe — duplex continuous audio is PHYSICALLY
      // impossible there, and the rig's open mic defeats DTX. A quiet
      // listener (what DTX yields with a real headset) is the honest
      // model: the sender talks, the receiver listens, x2 crossings fit.
      final receiverMode = e2eShapedConditions.bandwidthBps != null &&
              mode == MediaMode.realAudio
          ? MediaMode.noLocalAudio
          : mode;
      summary['receiverMediaMode'] = receiverMode.name;
      final receiver = E2eCallStack.build(
        endpoint: relay.endpoint,
        callId: callId,
        role: CallRole.receiver,
        mode: receiverMode,
      );
      addTearDown(() async {
        await initiator.dispose();
        await receiver.dispose();
      });

      try {
        // 1. CONNECT (same budgeted start as the other gates).
        const appConnectBudget = Duration(
          seconds: int.fromEnvironment(
            'E2E_CONNECT_BUDGET_S',
            defaultValue: 120,
          ),
        );
        const stressConnectWindow = Duration(
          seconds: int.fromEnvironment('E2E_STRESS_CONNECT_S'),
        );
        final connectBudget = stressConnectWindow > appConnectBudget
            ? stressConnectWindow
            : appConnectBudget;
        final connectStarted = DateTime.now();
        await Future.wait([
          initiator.controller
              .start()
              .then((_) => initiator.waitForConnected(timeout: connectBudget)),
          receiver.controller
              .start()
              .then((_) => receiver.waitForConnected(timeout: connectBudget)),
        ]).timeout(
          connectBudget + const Duration(seconds: 5),
          onTimeout: () => throw TimeoutException(
            'connect budget (${connectBudget.inSeconds}s + 5s) exhausted; '
            'initiator: ${initiator.recentPhases()}; '
            'receiver: ${receiver.recentPhases()}',
          ),
        );
        summary['connectMs'] =
            DateTime.now().difference(connectStarted).inMilliseconds;

        // 2. THE VIDEO LANE — second negotiated channel, own SCTP stream,
        //    then one renegotiation so the SDP carries m=application.
        // UNORDERED, deliberately: the lane carries its own chunk index and
        // per-chunk acks, so SCTP-level ordering buys nothing — and on a
        // shaped link it LIVELOCKS: one dropped chunk stalls the ordered
        // stream at the receiver, acks for every later chunk stop, and the
        // counters flatline (measured 2026-08-08: latency froze at 167/512,
        // bandwidth at 45/53, both with generous windows left).
        // LANE CHOICE (rig guide §0.3, 2026-08-10): at loss >= 0.3 the
        // rateless fountain lane rides a PURE-UDP datagram path via the
        // rig's dumb relay. Two measured official runs proved the SCTP
        // data channel itself — not the lane — is the ceiling under 60%
        // bidirectional loss: ~2 packets/s regardless of maxRetransmits:0
        // (bufMax=605KB genuinely queued, 84% of reads over a 64 KiB
        // gate, pcap ~2.2 large pkt/s — the transport's own recovery
        // clocking). No loss-reactive control may sit under the lane; its
        // delivery-clocked pacing is the only governor. Lossless and
        // mildly lossy rows keep the ARQ data-channel lane byte-identical.
        final useFountain = e2eShapedConditions.loss >= 0.3;
        summary['lane'] = useFountain ? 'fountain' : 'arq';

        if (useFountain) {
          // Row-specific safety argument: on an uncapped link the lane's
          // spray cannot queue behind signaling. A future capped+lossy row
          // must not silently inherit an unbudgeted sender — fail loud.
          expect(bwBps, isNull,
              reason: 'fountain lane is only argued safe on uncapped rows; '
                  'a bandwidth-capped lossy row needs a budgeted sender '
                  'before it may ride this lane');
          summary['transport'] = 'datagram';
          // ONE SYMBOL = ONE DATAGRAM: 1024 B + 30 B lane header + 16 B
          // room key = 1070 B UDP payload — single packet, zero
          // fragmentation (§0.3 sizing decision).
          const symbolBytes = 1024;
          summary['symbolBytes'] = symbolBytes;
          const dgramPort =
              int.fromEnvironment('E2E_DGRAM_PORT', defaultValue: 3737);
          // The rig passes an IP-literal relay host (E2E_RELAY_URI); the
          // in-process fallback endpoint says "localhost", which the port
          // refuses (no DNS per send) — map it to the loopback literal.
          final relayHost =
              InternetAddress.tryParse(relay.endpoint.host) != null
                  ? relay.endpoint.host
                  : '127.0.0.1';
          final roomKey = DatagramLanePort.roomKeyFromCallId(callId);
          final senderPort = await DatagramLanePort.bind(
            relayHost: relayHost,
            relayPort: dgramPort,
            roomKey: roomKey,
          );
          final receiverPort = await DatagramLanePort.bind(
            relayHost: relayHost,
            relayPort: dgramPort,
            roomKey: roomKey,
          );
          addTearDown(senderPort.close);
          addTearDown(receiverPort.close);

          final done = Completer<Uint8List>();
          final rx = FountainStreamReceiver(
            receiverPort,
            // Expiry inside a live row deadlocks it: a re-registered
            // receiver restarts EMPTY while the sender's completed flags
            // only rise (monotone by design) — so the receiver must
            // outlive any budgeted outage, and the sender's staleAfter
            // below stays the one terminal condition.
            expireAfter: connectBudget + const Duration(seconds: 60),
            onCompleted: (content) {
              if (!done.isCompleted) done.complete(content);
            },
          );
          addTearDown(rx.dispose);
          var recoveryFreezes = 0;
          final freezeSub = initiator.controller.states.listen((s) {
            final live = s.phase == CallPhase.connected ||
                s.phase == CallPhase.degraded;
            // Evidence only — no pause: the datagram path is stateless
            // (no channel to die with the call), and during an outage the
            // sender's per-generation debt caps park it within ~one
            // loss-headroom of un-STATEd symbols. Phase churn on record.
            if (!live) recoveryFreezes++;
          });
          addTearDown(freezeSub.cancel);
          final sender = FountainStreamSender(
            senderPort,
            symbolBytes: symbolBytes,
            // No transport backpressure signal: UDP keeps no meaningful
            // local backlog, and the lane's delivery-clocked bucket is
            // the governor (Mac gate 2026-08-10: 4 MiB @ 60% i.i.d.
            // through the real relay binary, overhead 2.57x, zero local
            // drops, 301 s). Floor sized so the full spray fits the
            // window on sparse feedback: ~4 k source symbols x2.5
            // overhead x1070 B ~= 11 MB, ~350 s at 32 KiB/s.
            floorBytesPerSec: 32 * 1024,
            // A mid-transfer outage can silence the reverse STATE path —
            // recovery-scale patience; the outer window timeout still
            // bounds total progress.
            staleAfter: connectBudget + const Duration(seconds: 30),
          );

          // 3. TRANSFER + VERDICT EVIDENCE (fountain lane, datagram path).
          final clip = deterministicVideo(sizeBytes);
          final sentAt = DateTime.now();
          final window = videoWindow(sizeBytes);
          summary['windowMs'] = window.inMilliseconds;
          final resultF = sender.send(clip);
          // A sender-side abort (STATE silence) must surface at the
          // awaited completer, not as an unhandled zone error mid-wait.
          unawaited(resultF.then<void>(
            (_) {},
            onError: (Object e, StackTrace st) {
              if (!done.isCompleted) done.completeError(e, st);
            },
          ));
          final received = await done.future.timeout(
            window,
            onTimeout: () {
              summary['helloAcked'] = sender.helloAcked;
              summary['senderDiag'] = sender.diag();
              summary['senderDatagrams'] = senderPort.sentDatagrams;
              summary['senderLocalDrops'] = senderPort.localSendDrops;
              summary['receiverDatagrams'] = receiverPort.receivedDatagrams;
              summary['initiatorPhase'] =
                  initiator.controller.state.phase.name;
              summary['receiverPhase'] = receiver.controller.state.phase.name;
              throw TimeoutException(
                'video (fountain/datagram) not delivered within '
                '${window.inSeconds}s (${sender.diag()}, '
                'tx=${senderPort.sentDatagrams} '
                'txDrops=${senderPort.localSendDrops} '
                'rx=${receiverPort.receivedDatagrams}, '
                'phases=${initiator.controller.state.phase.name}/'
                '${receiver.controller.state.phase.name})',
              );
            },
          );
          final ms = DateTime.now().difference(sentAt).inMilliseconds;
          summary['videoMs'] = ms;
          summary['throughputKbps'] = (sizeBytes * 8 / ms).round();
          // Delivery is verified; the sender's DONE handshake is
          // best-effort under loss — grace it, then record rather than
          // fail a row whose mission already succeeded.
          FountainSendResult? result;
          try {
            result = await resultF.timeout(const Duration(seconds: 30));
          } on Object catch (e) {
            summary['senderTermination'] = 'unterminated after delivery: $e';
          }
          summary['sentSymbols'] = result?.sentSymbols ?? sender.sentSymbols;
          summary['totalSourceSymbols'] =
              result?.totalSourceSymbols ?? (sizeBytes / symbolBytes).ceil();
          summary['resumedGenerations'] = result?.resumedGenerations;
          summary['totalGenerations'] = result?.totalGenerations;
          summary['recoveryFreezes'] = recoveryFreezes;
          summary['senderDatagrams'] = senderPort.sentDatagrams;
          summary['senderLocalDrops'] = senderPort.localSendDrops;
          summary['receiverDatagrams'] = receiverPort.receivedDatagrams;
          summary['deliveryKbps'] =
              (sender.deliveryBytesPerSec * 8 / 1000).round();
          // The sender's decode-miss estimate, NOT shaped ground truth.
          summary['senderLossEstimatePct'] =
              (sender.lossEstimate * 100).round();

          // The receiver sha-verified content against the transfer id
          // (sha-256 prefix + exact size) before onCompleted; the gate
          // re-proves identity directly anyway.
          var intact = received.length == clip.length;
          if (intact) {
            for (var i = 0; i < clip.length; i++) {
              if (received[i] != clip[i]) {
                intact = false;
                break;
              }
            }
          }
          summary['sha256Ok'] = intact;
          expect(intact, true,
              reason: 'the clip must arrive verified intact');
          expect(received.length, sizeBytes);
          return;
        }

        const videoChannel = mw.DataChannelConfig(
          label: 'vck-video',
          negotiatedId: 1,
          ordered: false,
        );
        final senderChannel =
            await initiator.media.openDataChannel(videoChannel);
        final receiverChannel =
            await receiver.media.openDataChannel(videoChannel);
        // Channel lifecycle evidence: the port drops sends into a dead
        // channel silently BY DESIGN, so a mid-transfer channel death is
        // invisible to the lane — the flatlined counters of 2026-08-08
        // (45/53 and ~165/512, twice each) demand the states on record.
        final senderStates = <String>[];
        final receiverStates = <String>[];
        senderChannel.state.listen((s) => senderStates.add(s.name));
        receiverChannel.state.listen((s) => receiverStates.add(s.name));
        final senderPort = MediaChannelDataPort(
          senderChannel,
          maxPendingFrames: 128,
        );
        final receiverPort = MediaChannelDataPort(
          receiverChannel,
          maxPendingFrames: 128,
        );
        initiator.controller.requestRecovery();
        await initiator
            .waitForConnected(timeout: connectBudget)
            .timeout(connectBudget + const Duration(seconds: 5));
        await receiver
            .waitForConnected(timeout: connectBudget)
            .timeout(connectBudget + const Duration(seconds: 5));

        final rx = BinaryStreamReceiver(receiverPort);
        addTearDown(rx.close);
        var recoveryFreezes = 0;
        final retransmitAfter = videoRetransmitAfter(chunkBytes);
        summary['retransmitAfterMs'] = retransmitAfter.inMilliseconds;
        // LANE QUOTA (2026-08-08, run-4 lesson): on a bandwidth-capped
        // link the lane gets a FIXED share (~25% per crossing) and its
        // token bucket locks injection to it. Without this the AIMD
        // window fills whatever audio leaves free, the shared queue
        // grows to tens of seconds, and liveness dies with the channels
        // still open — audio fit alone did not save the call.
        final laneBudgetBytesPerSec = bwBps != null && bwBps > 0
            ? (bwBps * 0.25 / 8).round().clamp(400, 1 << 20)
            : 0;
        summary['laneBudgetBytesPerSec'] = laneBudgetBytesPerSec;
        final sender = BinaryStreamSender(
          senderPort,
          retransmitAfter: retransmitAfter,
          windowSize: 4,
          chunkBytes: chunkBytes,
          // The definitive backpressure signal, straight from the channel.
          transportBufferedBytes: () => senderChannel.bufferedAmount,
          sendBudgetBytesPerSec:
              laneBudgetBytesPerSec > 0 ? () => laneBudgetBytesPerSec : null,
        );
        // ADAPTIVE STREAM PAUSE (accepted design, 2026-08-08): the moment
        // the call leaves its live phases the video stream freezes, handing
        // the whole link to signaling's survival work; on reconnection it
        // resumes from the exact ack/HAVE state (content addressing makes
        // the freeze free). Without this, recovery heartbeats queue behind
        // video chunks on precisely the links where recovery matters.
        final freezeSub = initiator.controller.states.listen((s) {
          final live = s.phase == CallPhase.connected ||
              s.phase == CallPhase.degraded;
          if (live) {
            sender.resume();
          } else {
            sender.pause();
            recoveryFreezes++;
          }
        });
        addTearDown(freezeSub.cancel);

        // 3. TRANSFER + VERDICT EVIDENCE.
        final clip = deterministicVideo(sizeBytes);
        final sentAt = DateTime.now();
        final window = videoWindow(sizeBytes);
        summary['windowMs'] = window.inMilliseconds;
        final resultF = sender.send(clip);
        final received = await rx.completed.first.timeout(
          window,
          onTimeout: () {
            // The lane confesses its counters so a dead row names the
            // starving leg instead of restarting the guesswork.
            summary['helloAcked'] = sender.helloAcked;
            summary['ackedChunks'] = sender.ackedChunks;
            summary['senderDiag'] = sender.diag();
            summary['senderChannelStates'] = senderStates;
            summary['receiverChannelStates'] = receiverStates;
            summary['initiatorPhase'] = initiator.controller.state.phase.name;
            summary['receiverPhase'] = receiver.controller.state.phase.name;
            throw TimeoutException(
              'video not delivered within ${window.inSeconds}s '
              '(helloAcked=${sender.helloAcked}, '
              'ackedChunks=${sender.ackedChunks}, ${sender.diag()}, '
              'senderCh=$senderStates, receiverCh=$receiverStates, '
              'phases=${initiator.controller.state.phase.name}/'
              '${receiver.controller.state.phase.name})',
            );
          },
        );
        final result = await resultF;
        final ms = DateTime.now().difference(sentAt).inMilliseconds;
        summary['videoMs'] = ms;
        summary['throughputKbps'] = (sizeBytes * 8 / ms).round();
        summary['sha256Ok'] = received.sha256Ok;
        summary['resumedChunks'] = result.resumedChunks;
        summary['totalChunks'] = result.totalChunks;
        summary['recoveryFreezes'] = recoveryFreezes;
        summary['srttMs'] = sender.srttMs.round();
        summary['deliveryKbps'] = (sender.deliveryBytesPerSec * 8 / 1000).round();

        expect(received.sha256Ok, true,
            reason: 'the clip must arrive hash-verified intact');
        expect(received.bytes.length, sizeBytes);
      } finally {
        print('VID_SUMMARY ${jsonEncode(summary)}');
      }
    },
  );
}
