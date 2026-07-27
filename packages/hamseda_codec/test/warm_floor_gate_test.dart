import 'dart:math';

import 'package:hamseda_codec/hamseda_codec.dart';
import 'package:test/test.dart';

/// EnCodec column cadence used throughout the project: 75 frames/second
/// (raw 2-row stream = 2 * 10 bits * 75 = 1500 bps, matching
/// docs/RECORD_hamseda_token_voice.md).
const int framesPerSecond = 75;

List<List<int>> speechLike(int frames, int nRows, int seed) {
  final rng = Random(seed);
  final alphabet = [
    for (var i = 0; i < 40; i++)
      [for (var r = 0; r < nRows; r++) rng.nextInt(rawSymbols)]
  ];
  return [
    for (var i = 0; i < frames; i++)
      rng.nextDouble() < 0.7
          ? List.of(alphabet[rng.nextInt(alphabet.length)])
          : [for (var r = 0; r < nRows; r++) rng.nextInt(rawSymbols)]
  ];
}

void main() {
  test(
      'warm-state re-encode of previously-seen speech stays under the '
      'ultra-low-bandwidth ceiling (CI gate for the warm floor)', () {
    // 40 seconds of deterministic speech-like columns.
    final cols = speechLike(40 * framesPerSecond, 2, 5);
    final st = HamsedaState(2);

    // Cold pass converges the dictionary on this speech.
    final cold = encodeColumns(cols, st);

    // Warm pass: the same speech re-encoded through the converged state —
    // the "fully-warm re-encode" condition of the 31.8 bps record.
    final warm = encodeColumns(cols, st);

    final seconds = cols.length / framesPerSecond;
    final coldBps = cold.length * 8 / seconds;
    final warmBps = warm.length * 8 / seconds;
    // ignore: avoid_print
    print('warm-floor gate: cold=${coldBps.toStringAsFixed(1)} bps '
        'warm=${warmBps.toStringAsFixed(1)} bps over ${seconds}s');

    // Bit-exactness is non-negotiable at any rate.
    final dec = HamsedaState(2);
    decodeColumns(cold, cols.length, dec);
    expect(decodeColumns(warm, cols.length, dec), equals(cols));

    // The gate: warm re-encode must stay in the ultra-low regime.
    // The real-recording record is 31.8 bps (docs/RECORD_hamseda_token_voice
    // .md); this synthetic fixture carries more novelty than a converged
    // real call, so the CI ceiling is set from the measured value of this
    // fixture, not the record. It exists to catch regressions that destroy
    // the warm path (e.g. dictionary reset between calls).
    expect(warmBps, lessThan(coldBps / 4),
        reason: 'warm re-encode must compress ≥4x below the cold pass');
    // Measured on this exact fixture: 42.8 bps (2026-07-27). 60 bps gives
    // regression headroom while staying in the ~4-8 B/s regime the 31.8 bps
    // real-recording record lives in.
    expect(warmBps, lessThan(60),
        reason: 'warm re-encode left the ultra-low-bandwidth regime '
            '(measured baseline 42.8 bps on this fixture)');
  });
}
