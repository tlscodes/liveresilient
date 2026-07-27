/// Burst (clustered) packet loss, modeled with the standard 2-state
/// Gilbert-Elliott Markov chain, against the real codec and the real
/// sliding-window wire format. Real networks fail in contiguous bursts
/// of dropped packets (outages of hundreds of ms to seconds), not in
/// uniformly random single drops — the uniform-loss numbers in
/// `hostile_path_voice_test.dart` are necessary but not sufficient.
///
/// Model: two states with independent loss rates.
///   Good: low loss (0-5%);  Bad/Burst: near-total loss (90-100%).
///   Per packet, Good->Bad with probability `p`, Bad->Good with
///   probability `r`; mean burst length = 1/r packets.
///
/// Asserted:
///   1. no unhandled exception across every run;
///   2. every recovered block is bit-exact (mismatches == 0);
///   3. speech coverage >= 90% under mean-10-packet bursts;
///   4. delivery resumes after every burst (no permanently dead call).
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:hamseda_codec/hamseda_codec.dart';
import 'package:test/test.dart';

/// Same warm-contact speech-like token stream as the hostile-path test.
/// (`GilbertElliottLossSimulator` itself now lives in the library:
/// `src/gilbert_elliott_loss.dart`.)
List<List<int>> speechStream(int frames, int seed) {
  final rng = Random(seed);
  const n = 45;
  final alphabet = [
    for (var i = 0; i < n; i++) [rng.nextInt(1024), rng.nextInt(1024)],
  ];
  final successors = [
    for (var i = 0; i < n; i++)
      [rng.nextInt(n), rng.nextInt(n), rng.nextInt(n)],
  ];
  final silence = [rng.nextInt(1024), rng.nextInt(1024)];
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

void main() {
  test('Gilbert-Elliott chain produces contiguous 5-15 packet bursts', () {
    // p tuned for frequent bursts, r = 0.1 -> mean burst of 10 packets.
    final sim = GilbertElliottLossSimulator(p: 0.02, r: 0.1, seed: 9);
    for (var i = 0; i < 100000; i++) {
      sim.shouldDrop();
    }
    expect(sim.burstLengths, isNotEmpty);
    final mean =
        sim.burstLengths.reduce((a, b) => a + b) / sim.burstLengths.length;
    expect(
      mean,
      closeTo(10, 2),
      reason: 'r=0.1 must give a mean burst near 10 packets',
    );
    // Burst lengths are geometric with mean 1/r: P(5 <= L <= 15) at
    // r=0.1 is 0.9^4 - 0.9^15 ~= 45%, the largest mass of any band of
    // that width.
    expect(
      sim.burstLengths.where((l) => l >= 5 && l <= 15).length,
      greaterThan((sim.burstLengths.length * 0.40).round()),
      reason: 'the 5-15 packet band must carry its geometric share',
    );
  });

  test('voice through mean-10-packet burst loss: no exception, bit-exact, '
      'coverage >= 90%, delivery resumes after every burst', () {
    const maxDatagramBytes = 60;
    const budgetBytesPerSecond = 600;
    const framesPerSecond = 75;
    const talkSeconds = 60;
    const blockFrames = 75; // 1 s per block
    const ticksPerSecond = 10; // datagram rate
    const window = 5;

    final speech = speechStream(framesPerSecond * talkSeconds, 2026);
    final warmSrc = HamsedaState(2);
    encodeColumns(speech.sublist(0, 1500), warmSrc);
    final warm = HamsedaState.fromJson(warmSrc.toJson());
    final warmDec = HamsedaState.fromJson(warmSrc.toJson());

    // p=0.04: a burst starts every ~25 packets (~every 2.5 s);
    // r=0.1: bursts average 10 packets (~1 s outage at 10 dg/s).
    final sim = GilbertElliottLossSimulator(p: 0.04, r: 0.1, seed: 7);
    final packer = SlidingWindowPacker(
      maxDatagramBytes: maxDatagramBytes,
      windowBlocks: window,
    );
    final unpacker = SlidingWindowUnpacker();

    var sentBytes = 0, blockSeq = 0, mismatches = 0, playedFrames = 0;
    final recoveredSeqs = <int>{};
    final sourceBlocks = <int, List<List<int>>>{};
    Uint8List? latestDatagram;

    final ticks = talkSeconds * ticksPerSecond;
    for (var tick = 0; tick < ticks; tick++) {
      if (tick % ticksPerSecond == 0) {
        final at = (tick ~/ ticksPerSecond) * blockFrames;
        final block = speech.sublist(at, at + blockFrames);
        sourceBlocks[blockSeq] = block;
        final data = encodeColumns(block, warm.clone());
        latestDatagram = packer.addBlock(blockSeq, data);
        blockSeq++;
      }
      final dg = latestDatagram;
      if (dg == null) continue;
      // Budget-filling sender, same as the hostile-path test.
      final byteBudgetSoFar =
          (tick + 1) * budgetBytesPerSecond ~/ ticksPerSecond;
      while (sentBytes + dg.length <= byteBudgetSoFar) {
        sentBytes += dg.length;
        if (sim.shouldDrop()) continue;
        for (final (seq, bytes) in unpacker.offer(dg)) {
          final src = sourceBlocks[seq];
          if (src == null) continue;
          final cols = decodeColumns(bytes, blockFrames, warmDec.clone());
          for (var f = 0; f < cols.length; f++) {
            if (cols[f][0] != src[f][0] || cols[f][1] != src[f][1]) {
              mismatches++;
            }
          }
          playedFrames += cols.length;
          recoveredSeqs.add(seq);
        }
      }
    }

    final coverage = playedFrames / (framesPerSecond * talkSeconds);
    final meanBurst = sim.burstLengths.isEmpty
        ? 0.0
        : sim.burstLengths.reduce((a, b) => a + b) / sim.burstLengths.length;
    // Longest run of consecutive lost blocks — "did the call ever die".
    var worstGap = 0, gap = 0;
    for (var s = 0; s < blockSeq; s++) {
      gap = recoveredSeqs.contains(s) ? 0 : gap + 1;
      if (gap > worstGap) worstGap = gap;
    }

    // ignore: avoid_print
    print(
      'BURST DIAG: bursts=${sim.burstLengths.length} '
      'meanBurst=${meanBurst.toStringAsFixed(1)} pkts '
      'blocks=${recoveredSeqs.length}/$blockSeq '
      'coverage=${(coverage * 100).toStringAsFixed(1)}% '
      'worstConsecutiveLostBlocks=$worstGap '
      'bytes/s=${(sentBytes / talkSeconds).toStringAsFixed(0)}',
    );

    expect(mismatches, 0, reason: 'recovered speech must be bit-exact');
    expect(
      sim.burstLengths.length,
      greaterThan(10),
      reason: 'the run must actually contain many bursts',
    );
    expect(
      coverage,
      greaterThanOrEqualTo(0.90),
      reason: 'conversation must stay continuous under clustered loss',
    );
    expect(
      worstGap,
      lessThanOrEqualTo(window),
      reason:
          'a burst may cost at most the window depth in blocks — '
          'delivery must resume after every burst',
    );
  });
}
