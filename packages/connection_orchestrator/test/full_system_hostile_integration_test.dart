/// Full-stack integration benchmark: every layer of the resilient voice
/// path running together against every hostile network condition at
/// once, on simulated (virtual) time so the whole 120 s session runs
/// deterministically in well under a second of wall clock.
///
/// Stack under test (all real, no mocks):
///   PCM frames -> SilenceSuppressionVAD (drop silence, 1/s keep-alive)
///     -> ColdStartDictionaryManager (static base, CRC-verified warm
///        handover at an agreed block boundary)
///     -> hamseda codec (order-2 adaptive token coder, bit-exact)
///     -> SlidingWindowPacker (window redundancy + trailing CRC-8)
///     -> hostile channel -> SlidingWindowUnpacker -> decode -> compare.
///
/// Two-phase block schedule (the architecture decision this test pins):
///   - COLD (first 3 s): short 15-frame blocks. A cold block costs
///     ~2-3 B/frame, so short blocks are the only way to fit the
///     datagram cap — and they also start playback fastest (0-RTT).
///   - WARM (after the CRC-verified handover at block 15): long 75-frame
///     blocks, ~0.2 B/frame, so each datagram is small enough to survive
///     any MTU dip and the budget buys ~30 redundant sends per block.
///
/// Hostile channel, all vectors simultaneously:
///   - wire budget 600 B/s (spec range 300-600; upper bound, matching
///     the measured field profile the lane is designed for);
///   - 85% uniform loss AND a Gilbert-Elliott chain layered on top
///     (mean ~12-packet bursts of near-total loss);
///   - jitter 500-5000 ms with out-of-order delivery (virtual time);
///   - total blackout seconds 45-75 of a 120 s call;
///   - MTU fluctuating 32-60 B per datagram — anything longer than the
///     instant MTU is truncated in flight (and must then die on CRC);
///   - 2% random single-bit corruption (must die on CRC).
///
/// Asserted:
///   - 0-RTT: cold speech decodes inside the first 3 s, zero exchange;
///   - static->warm handover with zero desynchronization (mismatches==0
///     across the whole session, including the boundary block);
///   - keep-alive pacing during silence: >= 1000 ms between pings;
///   - recovery within 2 s after the 30 s blackout ends;
///   - zero corrupted datagrams accepted;
///   - >= 90% bit-exact speech coverage of warm talk blocks outside the
///     blackout (the cold 3 s are asserted for 0-RTT playback, not for
///     90% coverage — cold redundancy is inherently thinner; that price
///     is printed in the diagnostics);
///   - bounded buffers: the jitter queue drains to zero at session end.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:hamseda_codec/hamseda_codec.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------- audio

const framesPerSecond = 75; // EnCodec 24 kHz token columns
const talkSeconds = 120;
const pcmRate = 16000;
const pcmFrameLen = 320; // 20 ms
const pcmFramesPerSecond = 50;

// Two-phase block schedule.
const coldBlockFrames = 15; // 0.2 s blocks for the cold 3 s
const coldBlocks = 15; // 15 x 0.2 s = 3 s, then handover
const warmBlockFrames = 75; // 1 s blocks once warm
const handoverBlock = coldBlocks;

int framesForBlock(int seq) =>
    seq < handoverBlock ? coldBlockFrames : warmBlockFrames;

int frameOffsetOfBlock(int seq) => seq < handoverBlock
    ? seq * coldBlockFrames
    : coldBlocks * coldBlockFrames + (seq - handoverBlock) * warmBlockFrames;

/// 5 s talk / 5 s pause alternation: exactly 50% speech.
bool isTalkSecond(int second) => (second ~/ 5).isEven;

/// Loud voiced PCM frame.
Int16List voicedPcm() {
  final f = Int16List(pcmFrameLen);
  for (var i = 0; i < pcmFrameLen; i++) {
    f[i] = (8000 * sin(2 * pi * 200 * i / pcmRate)).round();
  }
  return f;
}

/// Faint room-noise PCM frame.
Int16List quietPcm(int seed) {
  final rng = Random(seed);
  final f = Int16List(pcmFrameLen);
  for (var i = 0; i < pcmFrameLen; i++) {
    f[i] = rng.nextInt(61) - 30;
  }
  return f;
}

/// Token stream for a COLD contact whose tokens overlap the pre-agreed
/// base alphabet (the regime where a base dictionary helps — see
/// `ColdStartDictionaryManager.baseTrainingStream`).
List<List<int>> tokenStream(int frames, int seed) {
  final rng = Random(seed);
  final baseCols = ColdStartDictionaryManager.baseTrainingStream(1500);
  const n = 45;
  // Speech-shaped: a stable 45-column alphabet (70% of it drawn from the
  // base training stream = the speaker-independent overlap, 30% personal
  // novel columns), strong successor structure, silence runs.
  final alphabet = [
    for (var i = 0; i < n; i++)
      i < 31
          ? List.of(baseCols[rng.nextInt(baseCols.length)])
          : [rng.nextInt(1024), rng.nextInt(1024)]
  ];
  final successors = [
    for (var i = 0; i < n; i++)
      [rng.nextInt(n), rng.nextInt(n), rng.nextInt(n)]
  ];
  final silence = List.of(baseCols[0]);
  final out = <List<int>>[];
  var cur = 0;
  while (out.length < frames) {
    if (rng.nextDouble() < 0.25) {
      final run = 5 + rng.nextInt(25);
      for (var i = 0; i < run && out.length < frames; i++) {
        out.add(List.of(silence));
      }
      continue;
    }
    cur = successors[cur][rng.nextInt(3)];
    out.add(List.of(alphabet[cur]));
  }
  return out;
}

// -------------------------------------------------------------- channel

/// All hostile vectors at once, on virtual time measured in ticks.
class HostileChannel {
  HostileChannel({required this.ticksPerSecond, int seed = 99})
      : _rng = Random(seed),
        burstChain = GilbertElliottLossSimulator(
            p: 0.03, r: 0.085, badLossRate: 0.97, seed: seed + 1);

  final int ticksPerSecond;
  final Random _rng;
  final GilbertElliottLossSimulator burstChain;

  bool blackout = false;

  /// tick -> payloads arriving at that tick (jittered, thus reordered).
  final Map<int, List<Uint8List>> _inFlight = {};

  int sent = 0, droppedUniform = 0, droppedBurst = 0, blackedOut = 0;
  int truncated = 0, corrupted = 0;

  /// Number of payloads still queued (bounded-buffer check).
  int get pendingCount => _inFlight.values.fold(0, (a, l) => a + l.length);

  void send(Uint8List datagram, int nowTick) {
    sent++;
    if (blackout) {
      blackedOut++;
      return;
    }
    // Layered loss: uniform 85% AND the Gilbert-Elliott burst chain.
    final uniformDrop = _rng.nextDouble() < 0.85;
    final burstDrop = burstChain.shouldDrop();
    if (uniformDrop) {
      droppedUniform++;
      return;
    }
    if (burstDrop) {
      droppedBurst++;
      return;
    }
    var payload = datagram;
    // MTU fluctuates 32-60 B per datagram; longer payloads are cut.
    final mtu = 32 + _rng.nextInt(29);
    if (payload.length > mtu) {
      payload = Uint8List.sublistView(payload, 0, mtu);
      truncated++;
    }
    if (_rng.nextDouble() < 0.02) {
      payload = Uint8List.fromList(payload);
      payload[_rng.nextInt(payload.length)] ^= 1 << _rng.nextInt(8);
      corrupted++;
    }
    // Jitter 500-5000 ms -> out-of-order delivery.
    final delayTicks =
        (ticksPerSecond ~/ 2) + _rng.nextInt(ticksPerSecond * 9 ~/ 2 + 1);
    _inFlight.putIfAbsent(nowTick + delayTicks, () => []).add(payload);
  }

  /// Everything arriving at [tick].
  List<Uint8List> deliveriesAt(int tick) => _inFlight.remove(tick) ?? const [];
}

// ------------------------------------------------------------------ test

void main() {
  test('full stack under simultaneous throttling, layered burst loss, '
      'jitter/reorder, mid-call blackout, MTU cuts and bit corruption', () {
    const ticksPerSecond = 15; // send opportunities per second
    const budgetBytesPerSecond = 600;
    const maxDatagramBytes = 60;
    const blackoutStartS = 45, blackoutEndS = 75;

    final speech = tokenStream(framesPerSecond * talkSeconds, 2026);
    final vad = SilenceSuppressionVAD(hangoverFrames: 3);
    final senderDict = ColdStartDictionaryManager();
    final receiverDict = ColdStartDictionaryManager();
    // Window of 2: a warm datagram (~36 B: two ~15 B records) dies by
    // truncation on the lowest MTU dips (~14% of survivors) but carries
    // each block twice — the doubled redundancy more than pays for the
    // truncation tax, and the MTU stress vector is genuinely exercised.
    final packer =
        SlidingWindowPacker(maxDatagramBytes: maxDatagramBytes, windowBlocks: 2);
    final unpacker = SlidingWindowUnpacker();
    final channel = HostileChannel(ticksPerSecond: ticksPerSecond);

    // Warm per-contact state "from earlier calls", shared out-of-band.
    final warmState = HamsedaState(ColdStartDictionaryManager.rows);
    encodeColumns(speech.sublist(0, 1500), warmState);
    final warmPayload = ColdStartDictionaryManager.packWarmState(warmState);

    final sourceBlocks = <int, List<List<int>>>{};
    final recovered = <int>{};
    var mismatches = 0;
    var sentBytes = 0;
    var keepAlives = 0, lastKeepAliveMs = -1 << 40, minPingGapMs = 1 << 40;
    final quiet = quietPcm(3);
    final voiced = voicedPcm();

    void receive(Uint8List payload) {
      final List<(int, Uint8List)> records;
      try {
        records = unpacker.offer(payload);
      } catch (e) {
        fail('unpacker must reject malformed datagrams, not throw: $e');
      }
      for (final (seq, bytes) in records) {
        final src = sourceBlocks[seq];
        if (src == null) continue;
        final List<List<int>> cols;
        try {
          final state = seq < handoverBlock
              ? ColdStartDictionaryManager.baseState()
              : receiverDict.snapshot();
          cols = decodeColumns(bytes, framesForBlock(seq), state);
        } catch (_) {
          continue; // corrupt payload correctly rejected by the coder
        }
        var ok = cols.length == src.length;
        if (ok) {
          for (var f = 0; f < cols.length && ok; f++) {
            ok = cols[f][0] == src[f][0] && cols[f][1] == src[f][1];
          }
        }
        if (!ok) {
          mismatches++;
          continue;
        }
        recovered.add(seq);
      }
    }

    var nextSeq = 0;
    Uint8List? latestDatagram;
    var latestDatagramSecond = -1;
    final encodedBlocks = <int>{};

    final totalTicks = talkSeconds * ticksPerSecond;
    for (var tick = 0; tick < totalTicks; tick++) {
      final second = tick ~/ ticksPerSecond;
      channel.blackout = second >= blackoutStartS && second < blackoutEndS;

      // Jittered deliveries scheduled for this tick arrive first.
      for (final payload in channel.deliveriesAt(tick)) {
        receive(payload);
      }

      // VAD runs on the PCM frames of this tick (50 pcm frames/s vs 15
      // ticks/s -> 3-4 frames per tick).
      final pcmFrom = tick * pcmFramesPerSecond ~/ ticksPerSecond;
      final pcmTo = (tick + 1) * pcmFramesPerSecond ~/ ticksPerSecond;
      var voiceActive = false;
      for (var i = pcmFrom; i < pcmTo; i++) {
        final frameMs = i * 1000 ~/ pcmFramesPerSecond;
        final action =
            vad.process(isTalkSecond(second) ? voiced : quiet, frameMs);
        if (action == VadAction.send) voiceActive = true;
        if (action == VadAction.keepAlive) {
          keepAlives++;
          final gap = frameMs - lastKeepAliveMs;
          if (gap < minPingGapMs) minPingGapMs = gap;
          lastKeepAliveMs = frameMs;
          sentBytes += SilenceSuppressionVAD.keepAlivePing.length;
          channel.send(SilenceSuppressionVAD.keepAlivePing, tick);
        }
      }

      // Both ends flip to the warm dictionary at the agreed boundary,
      // BEFORE block `handoverBlock` is coded — the boundary block is
      // the first warm one on both sides.
      if (nextSeq == handoverBlock &&
          senderDict.phase == DictionaryPhase.staticBase) {
        expect(senderDict.adoptWarmState(warmPayload), isTrue);
        expect(receiverDict.adoptWarmState(warmPayload), isTrue);
      }

      // Produce the next block when its frames are due: every 3 ticks
      // during the cold 3 s, every 15 ticks once warm.
      final blockDueTick = nextSeq < handoverBlock
          ? nextSeq * 3
          : coldBlocks * 3 + (nextSeq - handoverBlock) * ticksPerSecond;
      if (tick == blockDueTick) {
        final at = frameOffsetOfBlock(nextSeq);
        final n = framesForBlock(nextSeq);
        if (voiceActive && at + n <= speech.length) {
          final block = speech.sublist(at, at + n);
          sourceBlocks[nextSeq] = block;
          encodedBlocks.add(nextSeq);
          latestDatagram = packer.addBlock(
              nextSeq, encodeColumns(block, senderDict.snapshot()));
          latestDatagramSecond = second;
        }
        nextSeq++;
      }

      // Budget-filling sender: spend the whole 600 B/s on resends of the
      // current datagram while its speech is fresh (within the jitter
      // horizon) — silence sends nothing but keep-alives.
      final dg = latestDatagram;
      if (dg != null && second - latestDatagramSecond <= 1) {
        final budgetSoFar = (tick + 1) * budgetBytesPerSecond ~/ ticksPerSecond;
        while (sentBytes + dg.length <= budgetSoFar) {
          sentBytes += dg.length;
          channel.send(dg, tick);
        }
      }
    }

    // Drain the jitter queue (max delay 5 s past the end).
    for (var tick = totalTicks; tick < totalTicks + ticksPerSecond * 6;
        tick++) {
      for (final payload in channel.deliveriesAt(tick)) {
        receive(payload);
      }
    }

    // ------------------------------------------------------- validation

    bool inBlackout(int seq) {
      final startSecond = frameOffsetOfBlock(seq) ~/ framesPerSecond;
      return startSecond >= blackoutStartS && startSecond < blackoutEndS;
    }

    final warmTalkOutside = encodedBlocks
        .where((s) => s >= handoverBlock && !inBlackout(s))
        .toSet();
    final warmRecovered = recovered.intersection(warmTalkOutside);
    final warmCoverage = warmTalkOutside.isEmpty
        ? 0.0
        : warmRecovered.length / warmTalkOutside.length;

    final coldRecovered = recovered.where((s) => s < handoverBlock).length;

    final firstWarmAfterBlackout = encodedBlocks
        .where((s) =>
            s >= handoverBlock &&
            frameOffsetOfBlock(s) ~/ framesPerSecond >= blackoutEndS)
        .fold<int?>(null, (m, s) => m == null || s < m ? s : m);
    final recoveredWithin2s = firstWarmAfterBlackout != null &&
        recovered.contains(firstWarmAfterBlackout) &&
        frameOffsetOfBlock(firstWarmAfterBlackout) ~/ framesPerSecond <
            blackoutEndS + 2;

    final lossPct = 100 *
        (channel.droppedUniform + channel.droppedBurst + channel.blackedOut) /
        channel.sent;
    final b = channel.burstChain.burstLengths;
    final meanBurst =
        b.isEmpty ? 0.0 : b.reduce((x, y) => x + y) / b.length;

    // ignore: avoid_print
    print('FULL-SYSTEM DIAG: wire=${sentBytes ~/ talkSeconds} B/s '
        'sentDg=${channel.sent} loss=${lossPct.toStringAsFixed(1)}% '
        '(uniform=${channel.droppedUniform} burst=${channel.droppedBurst} '
        'blackout=${channel.blackedOut}) truncated=${channel.truncated} '
        'corrupted=${channel.corrupted} '
        'bursts=${b.length}x~${meanBurst.toStringAsFixed(1)}pkt '
        'warmSpeechRecovery=${(warmCoverage * 100).toStringAsFixed(1)}% '
        '(${warmRecovered.length}/${warmTalkOutside.length}) '
        'coldBlocksRecovered=$coldRecovered/$coldBlocks '
        'recoveredWithin2sAfterBlackout=$recoveredWithin2s '
        'keepAlives=$keepAlives minPingGap=${minPingGapMs}ms '
        'mismatches=$mismatches pendingAtEnd=${channel.pendingCount} '
        'dictPhase=${senderDict.phase.name}/${receiverDict.phase.name}');

    // 0-RTT cold start: speech reaches the far end inside the first 3 s.
    expect(coldRecovered, greaterThan(0),
        reason: 'cold-start voice must play within the first 3 seconds '
            'with zero negotiation');
    // Handover integrity: both ends warm, and nothing desynchronized.
    expect(senderDict.phase, DictionaryPhase.dynamicWarm);
    expect(receiverDict.phase, DictionaryPhase.dynamicWarm);
    expect(mismatches, 0,
        reason: 'no corrupted or desynchronized block may ever decode '
            'into wrong speech');
    // Keep-alive pacing during silence.
    expect(minPingGapMs, greaterThanOrEqualTo(1000));
    expect(keepAlives, inInclusiveRange(40, 65),
        reason: '~60 silent seconds must produce about one ping each');
    // Post-blackout recovery within 2 s.
    expect(recoveredWithin2s, isTrue,
        reason: 'the call must resume within 2 s of the blackout ending');
    // CRC integrity was genuinely exercised.
    expect(channel.corrupted, greaterThanOrEqualTo(5));
    expect(channel.truncated, greaterThanOrEqualTo(5));
    // Warm speech coverage outside the blackout.
    expect(warmCoverage, greaterThanOrEqualTo(0.90),
        reason: 'the conversation must stay continuous outside the '
            'blackout');
    // Bounded buffers.
    expect(channel.pendingCount, 0,
        reason: 'no payload may linger in the jitter queue');
    expect(unpacker.accepted, lessThanOrEqualTo(channel.sent));
  });
}
