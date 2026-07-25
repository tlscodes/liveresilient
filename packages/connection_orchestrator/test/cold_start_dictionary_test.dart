import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:hamseda_codec/hamseda_codec.dart';
import 'package:test/test.dart';

/// Real-conversation speech-like stream (same family as the other lane
/// tests): personal alphabet + successor structure + silence runs.
List<List<int>> speechStream(int frames, int seed) {
  final rng = Random(seed);
  const n = 45;
  final alphabet = [
    for (var i = 0; i < n; i++) [rng.nextInt(1024), rng.nextInt(1024)]
  ];
  final successors = [
    for (var i = 0; i < n; i++)
      [rng.nextInt(n), rng.nextInt(n), rng.nextInt(n)]
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
  const framesPerSecond = 75;
  const blockFrames = 75; // 1 s blocks

  test('static base dictionary is deterministic and CRC-verified', () {
    final a = ColdStartDictionaryManager.staticBaseDict;
    expect(a.last, crc8(a, a.length - 1),
        reason: 'embedded base dict must carry a valid trailing CRC-8');
    // Both call ends derive the identical table with zero exchange.
    final s1 = ColdStartDictionaryManager.baseState();
    final s2 = ColdStartDictionaryManager.baseState();
    final probe = speechStream(150, 11);
    expect(encodeColumns(probe, s1.clone()),
        equals(encodeColumns(probe, s2.clone())));
  });

  test('0-RTT: the very first cold block encodes and decodes bit-exact '
      'with no exchange — zero playback delay', () {
    final sender = ColdStartDictionaryManager();
    final receiver = ColdStartDictionaryManager();
    final speech = speechStream(blockFrames, 2027);
    final wire = encodeColumns(speech, sender.snapshot());
    final decoded = decodeColumns(wire, blockFrames, receiver.snapshot());
    expect(decoded, equals(speech),
        reason: 'frame 0 of a cold call must decode with zero setup bytes');
  });

  test('first 3 seconds of a cold call cost fewer bytes with the base '
      'dictionary than from an empty state', () {
    // A cold caller's tokens overlap the pre-agreed base alphabet to the
    // extent EnCodec tokens are speaker-independent; model that overlap
    // by drawing most columns from the base training stream and the rest
    // from a personal alphabet. (With ZERO overlap the base dict is
    // measured to be slightly counterproductive — that anti-case is
    // documented on `baseTrainingStream`.)
    final baseCols = ColdStartDictionaryManager.baseTrainingStream(1500);
    final personal = speechStream(3 * framesPerSecond, 2028);
    final rng = Random(13);
    final speech = [
      for (final col in personal)
        rng.nextDouble() < 0.7
            ? List.of(baseCols[rng.nextInt(baseCols.length)])
            : col
    ];
    var withBase = 0, withoutBase = 0;
    final base = ColdStartDictionaryManager();
    final empty = HamsedaState(ColdStartDictionaryManager.rows);
    for (var b = 0; b < 3; b++) {
      final block =
          speech.sublist(b * blockFrames, (b + 1) * blockFrames);
      withBase += encodeColumns(block, base.snapshot()).length;
      withoutBase += encodeColumns(block, empty.clone()).length;
    }
    // ignore: avoid_print
    print('COLD-START DIAG: first 3 s = $withBase B with base dict, '
        '$withoutBase B from empty state');
    expect(withBase, lessThan(withoutBase),
        reason: 'the pre-agreed base dictionary must make the opening '
            'seconds cheaper than a fully raw start');
  });

  test('static-to-dynamic transition: every block before and after the '
      'CRC-verified handover decodes bit-exact', () {
    final sender = ColdStartDictionaryManager();
    final receiver = ColdStartDictionaryManager();
    expect(sender.phase, DictionaryPhase.staticBase);

    // A warm per-contact state from earlier calls, shared out-of-band
    // via the contact store on each end.
    final warmTraining = speechStream(1500, 2026);
    final warmState = HamsedaState(ColdStartDictionaryManager.rows);
    encodeColumns(warmTraining, warmState);
    final warmPayload = ColdStartDictionaryManager.packWarmState(warmState);

    final speech = speechStream(6 * blockFrames, 2029);
    const handoverAtBlock = 3; // both ends flip at the same boundary
    for (var b = 0; b < 6; b++) {
      if (b == handoverAtBlock) {
        expect(sender.adoptWarmState(warmPayload), isTrue);
        expect(receiver.adoptWarmState(warmPayload), isTrue);
        expect(sender.phase, DictionaryPhase.dynamicWarm);
        expect(receiver.phase, DictionaryPhase.dynamicWarm);
      }
      final block =
          speech.sublist(b * blockFrames, (b + 1) * blockFrames);
      final wire = encodeColumns(block, sender.snapshot());
      final decoded = decodeColumns(wire, blockFrames, receiver.snapshot());
      expect(decoded, equals(block),
          reason: 'block $b must be bit-exact across the transition');
    }
  });

  test('corrupted or malformed warm payload is rejected and the current '
      'state stays intact', () {
    final mgr = ColdStartDictionaryManager();
    final warm = HamsedaState(ColdStartDictionaryManager.rows);
    encodeColumns(speechStream(300, 5), warm);
    final good = ColdStartDictionaryManager.packWarmState(warm);

    final flipped = Uint8List.fromList(good)..[10] ^= 0xFF;
    expect(mgr.adoptWarmState(flipped), isFalse);
    expect(mgr.adoptWarmState(Uint8List.fromList([0x01])), isFalse);
    expect(mgr.phase, DictionaryPhase.staticBase,
        reason: 'a bad payload must never disturb the working state');

    // The static state still round-trips after the rejected attempts.
    final speech = speechStream(blockFrames, 2030);
    final wire = encodeColumns(speech, mgr.snapshot());
    expect(decodeColumns(wire, blockFrames, mgr.snapshot()), equals(speech));

    expect(mgr.adoptWarmState(good), isTrue,
        reason: 'the intact payload still verifies after bad attempts');
  });
}
