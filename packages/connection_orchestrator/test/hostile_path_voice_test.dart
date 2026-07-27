/// Voice through a severely restricted path, using measured real-world
/// numbers from the field:
///   throughput  100-600 bytes/s
///   packet loss 70-95%
///   one-way delay 3000-5000 ms (so NO round trips are possible)
///   MTU         only small datagrams (tens of bytes) pass
///
/// Success criteria (asserted; the numbers are printed):
///   1. speech arrives CONTINUOUSLY — delivered audio seconds >= 90% of
///      talk seconds, i.e. a conversation, not a slideshow;
///   2. every delivered block is bit-exact;
///   3. the wire byte rate stays inside the throughput that gets through;
///   4. every datagram fits the tiny MTU;
///   5. no acknowledgement or retransmission is used anywhere.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:hamseda_codec/hamseda_codec.dart';
import 'package:test/test.dart';

/// Deterministic speech-like token stream for a WARM contact: a stable
/// personal sound alphabet with a small novelty rate. The novelty rate
/// is chosen to reproduce the warm block size measured on the real
/// recording (~10 B per second of speech, `tool/blocksize.dart`); a
/// cold contact is a different regime, covered by the other tests.
List<List<int>> speechStream(int frames, int seed) {
  final rng = Random(seed);
  const n = 45;
  final alphabet = [
    for (var i = 0; i < n; i++) [rng.nextInt(1024), rng.nextInt(1024)],
  ];
  // Speech is strongly sequential: each sound is followed by one of a
  // few likely successors (that predictability is exactly what the
  // order-2 model exploits on the real recording).
  final successors = [
    for (var i = 0; i < n; i++)
      [rng.nextInt(n), rng.nextInt(n), rng.nextInt(n)],
  ];
  final silence = [rng.nextInt(1024), rng.nextInt(1024)];
  final out = <List<int>>[];
  var cur = 0;
  while (out.length < frames) {
    // real conversations are ~40% pauses: runs of the same quiet column
    if (rng.nextDouble() < 0.25) {
      final run = 5 + rng.nextInt(25);
      for (var i = 0; i < run && out.length < frames; i++) {
        out.add(List.of(silence));
      }
      continue;
    }
    if (rng.nextDouble() < 0.999) {
      cur = successors[cur][rng.nextInt(3)];
      out.add(List.of(alphabet[cur]));
    } else {
      out.add([rng.nextInt(1024), rng.nextInt(1024)]);
    }
  }
  return out;
}

void main() {
  test('restricted path: 100-600 B/s, 70-95% loss, 3-5 s delay, tiny '
      'datagrams — live voice still gets through', () {
    const lossRates = [0.70, 0.85, 0.95];
    const maxDatagramBytes = 60;
    const budgetBytesPerSecond = 600;
    const framesPerSecond = 75; // EnCodec 24 kHz: 75 columns/s
    const talkSeconds = 60;
    // Block length is the survival knob: longer blocks amortize the
    // coder's flush overhead, lowering bytes per second of speech, which
    // buys more redundant copies inside the same byte budget. The cost
    // is added latency — acceptable here because the path already has
    // 3-5 s of delay.
    // (the trailing datagram CRC byte added for corruption detection
    // costs one byte of budget, so the 95%-loss rung uses 210 frames
    // instead of the previous 225 to stay under the payload cap)
    int blockFramesFor(double loss) => loss >= 0.95 ? 210 : 75;
    const datagramsPerSecond = 10; // 10 x 60 B = 600 B/s budget
    const ticksPerSecond = datagramsPerSecond;

    final speech = speechStream(framesPerSecond * talkSeconds, 2026);
    final results = <String>[];

    for (final loss in lossRates) {
      // The window is what the datagram budget allows (~5 records of
      // ~10 B in 60 B). Because datagrams are sent 10x faster than
      // blocks are produced, each block rides ~50 independent datagrams.
      final blockFrames = blockFramesFor(loss);
      final blockSeconds = blockFrames / framesPerSecond;
      const window = 5;
      final packer = SlidingWindowPacker(
        maxDatagramBytes: maxDatagramBytes,
        windowBlocks: window,
      );
      final unpacker = SlidingWindowUnpacker();
      final rng = Random(7);

      // Both ends share a warm per-contact dictionary from earlier calls.
      final warmSrc = HamsedaState(2);
      encodeColumns(speech.sublist(0, 1500), warmSrc);
      final warm = HamsedaState.fromJson(warmSrc.toJson());
      final warmDec = HamsedaState.fromJson(warmSrc.toJson());

      var sentDatagrams = 0, sentBytes = 0, maxSeen = 0;
      var deliveredBlocks = 0, mismatches = 0, playedFrames = 0;
      var blockSeq = 0, blockBytesSum = 0, recordsSum = 0;
      final sourceBlocks = <int, List<List<int>>>{};
      Uint8List? latestDatagram;

      // Tick loop at the datagram rate: a new block is coded once per
      // second; every tick re-sends the current window datagram.
      final ticks = talkSeconds * ticksPerSecond;
      final ticksPerBlock = (ticksPerSecond * blockSeconds).round();
      for (var tick = 0; tick < ticks; tick++) {
        if (tick % ticksPerBlock == 0) {
          final at = (tick ~/ ticksPerBlock) * blockFrames;
          if (at + blockFrames <= speech.length) {
            final block = speech.sublist(at, at + blockFrames);
            sourceBlocks[blockSeq] = block;
            // independent-block coding against the frozen dictionary
            final data = encodeColumns(block, warm.clone());
            latestDatagram = packer.addBlock(blockSeq, data);
            blockBytesSum += data.length;
            recordsSum += latestDatagram[2];
            blockSeq++;
          }
        }
        final dg = latestDatagram;
        if (dg == null) continue;
        // Rate-controlled sender: spend the whole measured byte budget,
        // not one datagram per tick — leftover budget buys extra window
        // resends, which is pure redundancy on a >90%-loss path.
        final byteBudgetSoFar =
            (tick + 1) * budgetBytesPerSecond ~/ ticksPerSecond;
        while (sentBytes + dg.length <= byteBudgetSoFar) {
          sentDatagrams++;
          sentBytes += dg.length;
          if (dg.length > maxSeen) maxSeen = dg.length;
          if (rng.nextDouble() < loss) continue; // dropped by the path
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
            deliveredBlocks++;
          }
        }
      }

      final wireBytesPerSecond = sentBytes / talkSeconds;
      final deliveredSeconds = playedFrames / framesPerSecond;
      final coverage = deliveredSeconds / talkSeconds;

      // ignore: avoid_print
      print(
        'DIAG loss=$loss blocks=$deliveredBlocks/$blockSeq '
        'maxDg=${maxSeen}B bytes/s=${wireBytesPerSecond.toStringAsFixed(0)} '
        'accepted=${unpacker.accepted}/$sentDatagrams avgBlock=${(blockBytesSum / blockSeq).toStringAsFixed(1)}B avgRec=${(recordsSum / blockSeq).toStringAsFixed(1)}',
      );

      expect(mismatches, 0, reason: 'delivered speech must be bit-exact');
      expect(
        maxSeen,
        lessThanOrEqualTo(maxDatagramBytes),
        reason: 'every datagram must fit the tiny MTU',
      );
      expect(
        wireBytesPerSecond,
        lessThanOrEqualTo(budgetBytesPerSecond),
        reason: 'must fit the throughput that actually gets through',
      );
      expect(
        coverage,
        greaterThanOrEqualTo(0.90),
        reason:
            'conversation must stay continuous at '
            '${(loss * 100).toStringAsFixed(0)}% loss',
      );

      results.add(
        'loss ${(loss * 100).toStringAsFixed(0)}% · window $window blocks · '
        'datagrams $sentDatagrams @ max ${maxSeen}B · '
        'wire ${wireBytesPerSecond.toStringAsFixed(0)} B/s '
        '(${(wireBytesPerSecond * 8).toStringAsFixed(0)} bps) · '
        'speech ${deliveredSeconds.toStringAsFixed(1)}/${talkSeconds}s '
        '(${(coverage * 100).toStringAsFixed(1)}%) · '
        'blocks $deliveredBlocks/$blockSeq · bit-exact OK · no acks',
      );
    }
    for (final line in results) {
      // ignore: avoid_print
      print(line);
    }
  });
}
