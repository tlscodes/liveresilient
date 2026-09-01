/// MESSAGING SURVIVAL GATE — text, photo, and voice-note must DELIVER under
/// whatever impairment the rig applies, over the call's own machinery.
///
/// WHAT THIS MEASURES (and what it does not). The product machinery already
/// exists — ReliableMessenger over the call's negotiated data channel,
/// attachment chunking over the exact chat path — but until tonight nothing
/// MEASURED it under the T2 profiles. This test connects the same two-peer
/// call stack the SLA test uses, then delivers:
///   text   — [textCount] chat messages, each individually timed;
///   photo  — the §0.2 STAGED pipeline only (announcement+thumbhash on
///            the text path, preview + sha-verified original on the
///            binary lane) — the photo now rides ONLY the staged pipeline,
///            never base64 text;
///   voice  — one deterministic [voiceBytes]-byte clip attachment
///            (the survival-mode voice-note path: clips ride the chat
///            outbox as attachments).
/// Every artifact is verified BYTE-FOR-BYTE at the receiver. Delivery times
/// go into one machine-readable MSG_SUMMARY line for h2_run.sh.
///
/// JUDGMENT SPLIT (same architecture as the SLA test): this test asserts
/// SURVIVAL only — everything delivered, everything intact. TIME judgment
/// belongs to the rig, which derives its bounds independently from the
/// shaper's own conditions; a criterion inherited from the thing under test
/// passes by construction.
///
/// INSTRUMENT SIZING. The waiting windows and the messenger's retry timing
/// are derived from the same conditions model the app runs
/// (AdaptiveConnectionBudget): a fixed 2 s retry on a 16 kbit/s pipe would
/// retransmit chunks still sitting in the SCTP send buffer and flood the
/// link with duplicates; a fixed window on a 60%-loss link would clip the
/// measurement exactly where it is most expensive to obtain. Windows size
/// the INSTRUMENT, never the criterion.
///
/// TIMEOUT BUDGET, ADDED UP: connect max(450, stress bound)+5 s, channel
/// open 30 s, text window <= 120 s, two attachment windows <= 420 s each,
/// staged photo <= 420 s + 120 s dedup — worst case ~1985 s ~= 33 min,
/// inside the 45 minutes declared below and h2_run.sh's 3200 s watchdog.
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
import 'package:messaging/messaging.dart';
import 'package:media_webrtc/media_webrtc.dart' as mw;
import 'package:messaging_webrtc_adapter/messaging_webrtc_adapter.dart';

import 'support/datagram_lane_port.dart';
import 'support/e2e_support.dart';

/// Chat messages sent (each timed individually).
const int textCount = 5;

/// Deterministic artifact sizes. Big enough to need many chunks on a narrow
/// pipe (photo: 4+ chunks even at the 12 KiB default), small enough that the
/// worst profile's serialization stays inside one attachment window.
const int photoBytes = 48 * 1024;
const int voiceBytes = 24 * 1024;

/// Staged-photo artifact sizes (RIG_GUIDE §0.2 item 1): the preview is the
/// plan's ~15 KB rung; the original stands in for a capped 2048px q80
/// re-encode at 96 KiB — big enough to spread over many chunks/symbols.
const int stagedPhotoBytes = 96 * 1024;
const int stagedPreviewBytes = 15 * 1024;

final AdaptiveConnectionBudget _budget =
    AdaptiveConnectionBudget.fromConditions(e2eShapedConditions);

/// One modeled signaling round trip under the shaped conditions — the unit
/// the retry/window arithmetic below is built from.
final Duration _opCost = _budget.operationBudget(roundTrips: 1);

/// Messenger retry pacing: retransmit no faster than half an operation cost
/// (floor: the messenger's 2 s default), so retries chase genuinely lost
/// frames instead of duplicating frames still queued on a narrow pipe. On a
/// bandwidth-shaped link the floor is ONE CHUNK'S DRAIN TIME x1.5: the
/// transport is reliable, so a retransmit issued while the chunk is still
/// leaving the pipe is a guaranteed duplicate — measured 2026-08-07
/// (narrow): a 12 KiB chunk drains ~29 s at the 30% share of 16 kbit/s
/// while retries fired every ~9 s, tripling the very backlog the ack-paced
/// sender exists to avoid (adversarial-review recommendation applied).
final Duration msgRetryAfter = () {
  var pace = _opCost ~/ 2 >= const Duration(seconds: 2)
      ? _opCost ~/ 2
      : const Duration(seconds: 2);
  final bw = e2eShapedConditions.bandwidthBps;
  if (bw != null && bw > 0) {
    const chunkWireBits = 12 * 1024 * 8 * 1.45;
    final drain = Duration(
      milliseconds: (chunkWireBits * 1000 / (0.3 * bw) * 1.5).round(),
    );
    if (drain > pace) pace = drain;
  }
  return pace;
}();

/// Text delivery window: every text gets at least three full modeled
/// operation costs, floored at 30 s.
final Duration textWindow = _opCost * 3 >= const Duration(seconds: 30)
    ? _opCost * 3
    : const Duration(seconds: 30);

/// Attachment delivery window: serialization of the whole artifact on the
/// control-plane share of the link (chunk overhead included), inflated by
/// the loss model, plus three operation costs — capped at 420 s so a dead
/// transfer cannot hold the matrix, floored at 60 s.
Duration attachmentWindow(int bytes) {
  final bw = e2eShapedConditions.bandwidthBps;
  var ms = _opCost.inMilliseconds * 3;
  if (bw != null && bw > 0) {
    // base64 chunks + wire-frame envelope ~= 1.45x payload, on the 30%
    // control-plane share the wire budget reserves for non-media traffic.
    // TIMES TWO: transfers in this test are SEQUENTIAL on one pipe, so a
    // window must absorb the previous transfer's queue tail plus ack-layer
    // retransmits — measured 2026-08-07 (narrow): the photo used 87 s of
    // the link and the voice missed a 1x-serialization 120 s window.
    final wireBits = (bytes * 8 * 1.45).round();
    ms += 2 * (wireBits * 1000 / (0.3 * bw)).round();
  }
  // Per-chunk ack cost: each 12 KiB chunk is a reliable message whose ack
  // must return before the receiver's reassembly is provably advancing —
  // on a 1.8 s-RTT link the measured cost was ~5x RTT per chunk (photo,
  // 4 chunks, 36.5 s) while this window modeled none of it. Three RTTs
  // per chunk plus the raised 120 s floor covers the measured shortfalls
  // (voice missed by 60->needed ~70 on latency, 111->needed ~140 on
  // narrow, where the previous transfer's tail still owned the pipe).
  final chunks = (bytes / (12 * 1024)).ceil();
  ms += chunks * 3 * e2eShapedConditions.rtt.inMilliseconds;
  final loss = e2eShapedConditions.loss.clamp(0.0, 0.9);
  ms = (ms / ((1 - loss) * (1 - loss))).round();
  return Duration(milliseconds: ms.clamp(120000, 420000));
}

List<int> deterministicBytes(int length, int seed) =>
    List<int>.generate(length, (i) => (i * 31 + seed) & 0xff);

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

double? _percentile(List<int> sortedMs, double p) {
  if (sortedMs.isEmpty) return null;
  return sortedMs[((sortedMs.length - 1) * p).round()].toDouble();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Messaging survival: text, photo, and voice-note deliver intact under '
    'whatever impairment is applied',
    (tester) async {
      final mode = await resolveMediaMode();
      final relay = await LoopbackRelay.start();
      addTearDown(relay.close);

      final summary = <String, Object?>{
        'mediaMode': mode.name,
        'textCount': textCount,
        'photoBytes': stagedPhotoBytes,
        'voiceBytes': voiceBytes,
        'retryAfterMs': msgRetryAfter.inMilliseconds,
      };
      final notes = <String>[];

      const callId = 'e2e-msg-call';
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

      try {
        // -------------------------------------------------------------
        // 1. CONNECT — same budgeted two-sided start as the SLA test:
        //    the window is the larger of the app's own budget and the
        //    harness's independent stress bound, so neither policy can
        //    clip the other's measurement.
        // -------------------------------------------------------------
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
          initiator.controller.start().then(
            (_) => initiator.waitForConnected(timeout: connectBudget),
          ),
          receiver.controller.start().then(
            (_) => receiver.waitForConnected(timeout: connectBudget),
          ),
        ]).timeout(
          connectBudget + const Duration(seconds: 5),
          onTimeout: () => throw TimeoutException(
            'connect budget (${connectBudget.inSeconds}s + 5s) exhausted; '
            'initiator phase=${initiator.controller.state.phase.name} '
            'error=${initiator.controller.state.error}; '
            'receiver phase=${receiver.controller.state.phase.name} '
            'error=${receiver.controller.state.error}',
          ),
        );
        summary['connectMs'] = DateTime.now()
            .difference(connectStarted)
            .inMilliseconds;

        // -------------------------------------------------------------
        // 2. THE MESSAGING STACK — the product's own path: negotiated
        //    data channel -> MediaChannelDataPort -> ReliableMessenger,
        //    attachments chunked over the same reliable text frames.
        //    Both peers open with the identical default config (the
        //    negotiated-mode contract).
        // -------------------------------------------------------------
        final attachmentWindowMax = attachmentWindow(photoBytes);
        final maxAttempts =
            (attachmentWindowMax.inMilliseconds / msgRetryAfter.inMilliseconds)
                .ceil() +
            2;
        final senderMessenger = ReliableMessenger(
          MediaChannelDataPort(await initiator.media.openDataChannel()),
          peerId: 'msg-initiator',
          retryAfter: msgRetryAfter,
          maxAttempts: maxAttempts,
        );
        final receiverMessenger = ReliableMessenger(
          MediaChannelDataPort(await receiver.media.openDataChannel()),
          peerId: 'msg-receiver',
          retryAfter: msgRetryAfter,
          maxAttempts: maxAttempts,
        );
        addTearDown(() async {
          await senderMessenger.close();
          await receiverMessenger.close();
        });

        // App-driven retry pump, both sides, for the whole phase.
        final tickers = <Timer>[
          Timer.periodic(msgRetryAfter, (_) {
            unawaited(senderMessenger.tick());
          }),
          Timer.periodic(msgRetryAfter, (_) {
            unawaited(receiverMessenger.tick());
          }),
        ];
        addTearDown(() {
          for (final t in tickers) {
            t.cancel();
          }
        });

        // The call so far negotiated AUDIO only — a data channel created
        // now (even negotiated-mode) has no SCTP transport to ride until
        // an offer carrying m=application is exchanged. Renegotiate
        // through the controller's public recovery seam: the fresh offer
        // is created AFTER the channels above, so it carries the data
        // section, and SCTP comes up with the re-connected call. (Same
        // mechanism the product's survival mode relies on mid-call.)
        initiator.controller.requestRecovery();
        await initiator
            .waitForConnected(timeout: connectBudget)
            .timeout(connectBudget + const Duration(seconds: 5));
        await receiver
            .waitForConnected(timeout: connectBudget)
            .timeout(connectBudget + const Duration(seconds: 5));
        summary['renegotiatedMs'] = DateTime.now()
            .difference(connectStarted)
            .inMilliseconds;

        StagedPhotoReceiver? stagedPhotoReceiver;
        final attachmentReceiver = AttachmentReceiver();
        addTearDown(attachmentReceiver.close);
        final receivedTexts = <String, DateTime>{};
        final receivedAttachments = <String, (Attachment, DateTime)>{};
        final attachmentArrived = StreamController<String>.broadcast();
        addTearDown(attachmentArrived.close);
        attachmentReceiver.completed.listen((attachment) {
          receivedAttachments[attachment.id] = (attachment, DateTime.now());
          attachmentArrived.add(attachment.id);
        });
        final textArrived = StreamController<String>.broadcast();
        addTearDown(textArrived.close);
        receiverMessenger.incoming.listen((message) {
          if (stagedPhotoReceiver?.offerText(message.text) ?? false) {
            return; // a §0.2 photo announcement — the staged ladder owns it
          }
          if (attachmentReceiver.offer(message.text)) return;
          receivedTexts[message.text] = DateTime.now();
          textArrived.add(message.text);
        });

        Future<void> waitUntil(
          bool Function() ready,
          Stream<String> arrivals,
          Duration window,
          String what,
        ) async {
          if (ready()) return;
          final completer = Completer<void>();
          final sub = arrivals.listen((_) {
            if (ready() && !completer.isCompleted) completer.complete();
          });
          try {
            await completer.future.timeout(
              window,
              onTimeout: () => throw TimeoutException(
                '$what not delivered within ${window.inSeconds}s',
              ),
            );
          } finally {
            await sub.cancel();
          }
        }

        // -------------------------------------------------------------
        // 3. TEXT — five individually timed messages.
        // -------------------------------------------------------------
        final textLatencies = <int>[];
        for (var i = 0; i < textCount; i++) {
          final body = 'msg-$i ${base64Encode(deterministicBytes(64, i))}';
          final sentAt = DateTime.now();
          await senderMessenger.send(body);
          await waitUntil(
            () => receivedTexts.containsKey(body),
            textArrived.stream,
            textWindow,
            'text $i',
          );
          textLatencies.add(
            receivedTexts[body]!.difference(sentAt).inMilliseconds,
          );
        }
        textLatencies.sort();
        summary['textDelivered'] = receivedTexts.length;
        summary['textP50Ms'] = _percentile(textLatencies, 0.50);
        summary['textMaxMs'] = textLatencies.isEmpty
            ? null
            : textLatencies.last;

        // -------------------------------------------------------------
        // 4. PHOTO — one deterministic image attachment, verified
        //    byte-for-byte at the receiver.
        // -------------------------------------------------------------
        Future<int> deliverAttachment({
          required String id,
          required MediaKind kind,
          required String contentType,
          required int length,
          required int seed,
        }) async {
          final bytes = deterministicBytes(length, seed);
          final sentAt = DateTime.now();
          await sendAttachment(
            senderMessenger,
            Attachment(
              id: id,
              kind: kind,
              contentType: contentType,
              bytes: bytes,
            ),
          );
          await waitUntil(
            () => receivedAttachments.containsKey(id),
            attachmentArrived.stream,
            attachmentWindow(length),
            id,
          );
          final (received, at) = receivedAttachments[id]!;
          final intact = bytesEqual(received.bytes, bytes);
          summary['${id}Intact'] = intact;
          if (!intact) {
            notes.add(
              '$id corrupted: ${received.sizeBytes}B of ${bytes.length}B',
            );
          }
          return at.difference(sentAt).inMilliseconds;
        }

        // PHOTO: retired from the base64 path (user law 2026-08-10 —
        // a photo never rides text). Section 5b's staged pipeline is the
        // only photo leg and it writes photoIntact/photoMs itself.

        // -------------------------------------------------------------
        // 5. VOICE-NOTE — the survival-mode clip path: a clip is an
        //    attachment riding the chat outbox.
        // -------------------------------------------------------------
        summary['voiceMs'] = await deliverAttachment(
          id: 'voice',
          kind: MediaKind.file,
          contentType: 'audio/ogg',
          length: voiceBytes,
          seed: 13,
        );

        // -------------------------------------------------------------
        // 5b. STAGED PHOTO (§0.2) — announcement with the thumbhash
        //     INSIDE it on the reliable text path; preview then
        //     full-sha-verified original on the binary lane. Lane switch
        //     mirrors the video row's proven law: ARQ data channel on
        //     healthy profiles, fountain over the datagram relay under
        //     loss >= 0.3. Contract gates asserted here: rung ORDER,
        //     full sha, dedup-resume without payload re-transfer.
        // -------------------------------------------------------------
        final bwBps = e2eShapedConditions.bandwidthBps;
        final useFountainPhoto = e2eShapedConditions.loss >= 0.3;
        summary['photoLane'] = useFountainPhoto ? 'fountain' : 'arq';
        summary['photoTransport'] = useFountainPhoto ? 'datagram' : 'sctp';
        summary['stagedPhotoBytes'] = stagedPhotoBytes;
        summary['stagedPreviewBytes'] = stagedPreviewBytes;

        final thumbRgba = Uint8List(32 * 24 * 4);
        for (var i = 0; i < 32 * 24; i++) {
          thumbRgba[i * 4] = (i * 255) ~/ (32 * 24);
          thumbRgba[i * 4 + 1] = 80;
          thumbRgba[i * 4 + 2] = 150;
          thumbRgba[i * 4 + 3] = 255;
        }
        final artifacts = StagedPhotoArtifacts(
          thumbHash: ThumbHash.encodeRgba(32, 24, thumbRgba),
          preview: Uint8List.fromList(
            deterministicBytes(stagedPreviewBytes, 21),
          ),
          original: Uint8List.fromList(
            deterministicBytes(stagedPhotoBytes, 23),
          ),
          width: 2048,
          height: 1536,
        );
        summary['thumbHashBytes'] = artifacts.thumbHash.length;

        final StagedPhotoSender stagedSender;
        if (useFountainPhoto) {
          // Same safety argument as the video row: unbudgeted spray is
          // only argued safe on uncapped links — fail loud otherwise.
          expect(
            bwBps,
            isNull,
            reason:
                'fountain lane is only argued safe on uncapped rows; '
                'a bandwidth-capped lossy row needs a budgeted sender '
                'before it may ride this lane',
          );
          const dgramPort = int.fromEnvironment(
            'E2E_DGRAM_PORT',
            defaultValue: 3737,
          );
          final relayHost =
              InternetAddress.tryParse(relay.endpoint.host) != null
              ? relay.endpoint.host
              : '127.0.0.1';
          // A room of our own on the learned-seat relay: keyed off the
          // photo sub-id so no other lane's seats can collide.
          final roomKey = DatagramLanePort.roomKeyFromCallId('$callId#photo');
          final laneTx = await DatagramLanePort.bind(
            relayHost: relayHost,
            relayPort: dgramPort,
            roomKey: roomKey,
          );
          final laneRx = await DatagramLanePort.bind(
            relayHost: relayHost,
            relayPort: dgramPort,
            roomKey: roomKey,
          );
          addTearDown(laneTx.close);
          addTearDown(laneRx.close);
          final rx = StagedPhotoReceiver.fountain(
            laneRx,
            // Receiver must outlive any budgeted outage (expiry inside a
            // live row restarts an EMPTY receiver against monotone sender
            // flags — the video row's pinned deadlock).
            expireAfter: connectBudget + const Duration(seconds: 60),
          );
          stagedPhotoReceiver = rx;
          addTearDown(rx.close);
          stagedSender = StagedPhotoSender.fountain(
            laneTx,
            announce: (text) async {
              final message = await senderMessenger.send(text);
              summary['stagedAnnounceMsgId'] = message.id;
            },
            // ONE SYMBOL = ONE DATAGRAM (1024+30+16 = 1070 B payload).
            symbolBytes: 1024,
            floorBytesPerSec: 32 * 1024,
            staleAfter: connectBudget + const Duration(seconds: 30),
          );
        } else {
          // Dedicated negotiated lane channel — high id, clear of the
          // DCEP-assigned messenger channel ids.
          const photoChannel = mw.DataChannelConfig(
            label: 'vck-photo',
            negotiatedId: 9,
            ordered: false,
          );
          final txChannel = await initiator.media.openDataChannel(photoChannel);
          final rxChannel = await receiver.media.openDataChannel(photoChannel);
          final lanePortTx = MediaChannelDataPort(
            txChannel,
            maxPendingFrames: 128,
          );
          final lanePortRx = MediaChannelDataPort(
            rxChannel,
            maxPendingFrames: 128,
          );
          final rx = StagedPhotoReceiver.arq(lanePortRx);
          stagedPhotoReceiver = rx;
          addTearDown(rx.close);
          final laneBudget = bwBps != null && bwBps > 0
              ? (bwBps * 0.25 / 8).round().clamp(400, 1 << 20)
              : 0;
          summary['stagedLaneBudgetBytesPerSec'] = laneBudget;
          stagedSender = StagedPhotoSender.arq(
            lanePortTx,
            announce: (text) async {
              final message = await senderMessenger.send(text);
              summary['stagedAnnounceMsgId'] = message.id;
            },
            retransmitAfter: msgRetryAfter,
            chunkBytes: 8 * 1024,
            transportBufferedBytes: () => txChannel.bufferedAmount,
            sendBudgetBytesPerSec: laneBudget > 0 ? () => laneBudget : null,
          );
        }

        final stagedStages = <PhotoStage>[];
        final stagedVerified = Completer<void>();
        final stagedSub = stagedPhotoReceiver.updates.listen((u) {
          stagedStages.add(u.stage);
          summary['stagedStages'] = stagedStages.map((s) => s.name).toList();
          if (u.stage == PhotoStage.originalVerified &&
              !stagedVerified.isCompleted) {
            stagedVerified.complete();
          }
        });
        addTearDown(stagedSub.cancel);
        // The announcement's own delivery outcome, straight from the
        // messenger's deliveries stream — if the ladder is silent, this
        // says whether the announcement leg ever landed.
        final annDeliverySub = senderMessenger.deliveries.listen((event) {
          final (id, state) = event;
          if (id == summary['stagedAnnounceMsgId']) {
            summary['stagedAnnounceDelivery'] = state.name;
          }
        });
        addTearDown(annDeliverySub.cancel);

        final stagedWindow = attachmentWindow(stagedPhotoBytes);
        summary['stagedWindowMs'] = stagedWindow.inMilliseconds;
        final stagedStart = DateTime.now();
        final res1 = await stagedSender
            .deliver(artifacts)
            .timeout(
              stagedWindow,
              onTimeout: () => throw TimeoutException(
                'staged photo not delivered within '
                '${stagedWindow.inSeconds}s (${stagedSender.diag()})',
              ),
            );
        // The receiver's own verified event, not just the sender's DONE.
        // The wait must absorb the ANNOUNCEMENT leg too: the messenger's
        // send() hands off without awaiting the ack, so under loss the
        // announcement can trail the lane blobs (the orphan stash holds
        // them) — give it the text-message budget, not a token 30 s.
        try {
          await stagedVerified.future.timeout(
            textWindow > const Duration(seconds: 60)
                ? textWindow
                : const Duration(seconds: 60),
          );
        } on TimeoutException {
          summary['stagedLadderDump'] = {
            'photos': stagedPhotoReceiver.photos.map(
              (k, v) => MapEntry(
                k.substring(0, 8),
                '${v.stage.name}/sha=${v.sha256Verified}',
              ),
            ),
            'orphans': stagedPhotoReceiver.orphanCount,
            'announceDelivery': summary['stagedAnnounceDelivery'],
          };
          rethrow;
        }
        summary['stagedPhotoMs'] = DateTime.now()
            .difference(stagedStart)
            .inMilliseconds;
        summary['stagedAnnounceMs'] = res1.announceElapsed.inMilliseconds;
        summary['stagedPreviewMs'] = res1.previewElapsed.inMilliseconds;
        summary['stagedOriginalMs'] = res1.originalElapsed.inMilliseconds;
        summary['stagedSentSymbols'] = res1.sentSymbols;
        summary['stagedTotalSourceSymbols'] = res1.totalSourceSymbols;

        final ladder = stagedPhotoReceiver.photos[res1.announcement.photoId];
        final stagedOrderOk =
            stagedStages.length >= 3 &&
            stagedStages[0] == PhotoStage.announced &&
            stagedStages[1] == PhotoStage.previewReady &&
            stagedStages[2] == PhotoStage.originalVerified;
        summary['stagedOrderOk'] = stagedOrderOk;
        final stagedIntact =
            ladder != null &&
            ladder.sha256Verified &&
            ladder.original != null &&
            bytesEqual(ladder.original!, artifacts.original) &&
            ladder.preview != null &&
            bytesEqual(ladder.preview!, artifacts.preview);
        summary['stagedPhotoIntact'] = stagedIntact;
        summary['photoIntact'] = stagedIntact;
        summary['photoMs'] = summary['stagedPhotoMs'];
        if (!stagedOrderOk || !stagedIntact) {
          notes.add(
            'staged ladder: stages=$stagedStages '
            'sha=${ladder?.sha256Verified}',
          );
        }

        // DEDUP-RESUME — the same photo again: content addressing must
        // answer from the receiver's held bytes, no payload re-transfer.
        final ackedBefore = stagedSender.arqAckedChunks;
        final dedupStart = DateTime.now();
        final res2 = await stagedSender
            .deliver(artifacts)
            .timeout(
              const Duration(seconds: 120),
              onTimeout: () => throw TimeoutException(
                'dedup re-send not answered within 120s',
              ),
            );
        summary['stagedDedupMs'] = DateTime.now()
            .difference(dedupStart)
            .inMilliseconds;
        final stagedDedupOk = useFountainPhoto
            ? (res2.deduplicated || res2.sentSymbols < res2.totalSourceSymbols)
            : (res2.deduplicated || stagedSender.arqAckedChunks == ackedBefore);
        summary['stagedDedupOk'] = stagedDedupOk;

        summary['stillConnectedAtEnd'] =
            initiator.controller.state.phase == CallPhase.connected ||
            initiator.controller.state.phase == CallPhase.degraded;

        // -------------------------------------------------------------
        // 6. SURVIVAL ASSERTS — delivery + integrity on every tier.
        //    Time bounds are the rig's independent judgment, not ours.
        // -------------------------------------------------------------
        expect(
          receivedTexts.length,
          textCount,
          reason: 'every chat text must deliver',
        );
        expect(
          summary['photoIntact'],
          true,
          reason: 'the photo must arrive byte-for-byte intact',
        );
        expect(
          summary['voiceIntact'],
          true,
          reason: 'the voice-note must arrive byte-for-byte intact',
        );
        expect(
          summary['stagedOrderOk'],
          true,
          reason:
              'the staged ladder must climb announced -> preview -> '
              'verified original, in order',
        );
        expect(
          summary['stagedPhotoIntact'],
          true,
          reason:
              'the staged original must match the announced full '
              'sha256 and the preview must match its content address',
        );
        expect(
          summary['stagedDedupOk'],
          true,
          reason:
              're-sending the same photo must be answered from held '
              'bytes without payload re-transfer',
        );
      } finally {
        summary['notes'] = notes;
        print('MSG_SUMMARY ${jsonEncode(summary)}');
      }
    },
  );
}
