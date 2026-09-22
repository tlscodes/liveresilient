// The speech gate and the normalizer, without a microphone: a synthetic
// voiced burst inside room noise is found and lifted, room noise alone is
// refused, and nothing clips.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/voice_letter_recorder.dart';

/// 8 kHz mono: [seconds] of noise at [noiseRms], with a 200 Hz "voiced"
/// tone of amplitude [toneAmp] from second 1 to second 2 when [withTone].
Int16List take({
  double seconds = 3,
  double noiseRms = 300,
  double toneAmp = 6000,
  bool withTone = true,
}) {
  final r = Random(7);
  final n = (seconds * 8000).round();
  final out = Int16List(n);
  for (var i = 0; i < n; i++) {
    var v = (r.nextDouble() * 2 - 1) * noiseRms * 1.7;
    if (withTone && i >= 8000 && i < 16000) {
      v += toneAmp * sin(2 * pi * 200 * i / 8000);
    }
    out[i] = v.round().clamp(-32768, 32767);
  }
  return out;
}

double rmsOf(Int16List x, int from, int to) {
  var e = 0.0;
  for (var i = from; i < to; i++) {
    e += x[i] * x[i].toDouble();
  }
  return sqrt(e / (to - from));
}

void main() {
  test('room noise alone is refused as no speech', () {
    expect(hasSpeech(take(withTone: false)), isFalse);
  });

  test('a voiced burst in noise is found: the mask covers the burst', () {
    final mask = speechMask(take());
    expect(mask, hasLength(150));
    final voiced = mask.where((m) => m).length;
    // The burst is frames 50..99 plus pre-roll/hangover; nothing else.
    expect(voiced, inInclusiveRange(50, 64));
    expect(mask.sublist(52, 98).every((m) => m), isTrue);
    expect(mask.sublist(0, 40).any((m) => m), isFalse);
    expect(hasSpeech(take()), isTrue);
  });

  test('gain comes from the speech, noise is pushed down, nothing clips', () {
    final x = take(toneAmp: 2000);
    final y = normalizeSpeech(x, sampleRate: 8000);
    final speech = rmsOf(y, 8400, 15600);
    final noise = rmsOf(y, 0, 7000);
    // Speech lands near -20 dBFS (3277; the mask also holds pre-roll and
    // hangover frames, so the burst itself comes out a little above).
    expect(speech, inInclusiveRange(2200, 4200));
    // Non-speech sits -15 dB under the speech (x0.178), ramped, not gated.
    expect(noise, lessThan(speech / 4));
    var peak = 0;
    for (final s in y) {
      if (s.abs() > peak) peak = s.abs();
    }
    expect(peak, lessThanOrEqualTo((0.9 * 32767).round() + 1));
  });

  test('the ladder stops at the quality floor, never under it', () {
    // Twenty letters (frozen 2026-09-22): 81340 - 4 - 500 = 80836 B ->
    // 21556 bit/s x 0.93 = 20047 -> 20000, then 12 % steps down to the
    // floor (10600) and no further. The first three rungs are hybrid.
    expect(opusBitrateLadder(30, voiceLetterBudgetBytes), [
      20000,
      17600,
      15500,
      13700,
      12000,
      10600,
    ]);
    expect(
      opusBitrateLadder(
        30,
        voiceLetterBudgetBytes,
      ).where((b) => b >= opusHybridFloorBitrate).length,
      3,
    );
    for (final rung in opusBitrateLadder(30, voiceLetterBudgetBytes)) {
      expect(rung, greaterThanOrEqualTo(opusQualityFloorBitrate));
    }
    // Short takes are capped at 24 k; a budget that cannot reach the floor
    // yields nothing, and the recorder refuses (ten letters at 30 s allow
    // only 9961 bit/s, under the floor).
    expect(opusBitrateLadder(5, voiceLetterBudgetBytes).first, 24000);
    expect(opusBitrateLadder(30, 10 * 4067), isEmpty);
    expect(opusBitrateLadder(0, voiceLetterBudgetBytes), isEmpty);
  });

  test('the frozen caps: fifty seconds of voice in twenty letters', () {
    // 2026-09-22, the owner's decision: twenty letters, fifty seconds, and
    // a refusal past the rung he accepted — never a quieter codec.
    expect(voiceLetterMaxLength, const Duration(seconds: 50));
    expect(voiceLetterBudgetBytes, 20 * 4067);
    final atCap = opusBitrateLadder(50, voiceLetterBudgetBytes);
    expect(atCap.first, greaterThanOrEqualTo(opusQualityFloorBitrate));
    expect(atCap.first, inInclusiveRange(11000, 12500));
    expect(atCap.last, greaterThanOrEqualTo(opusQualityFloorBitrate));
    // A take past the cap cannot reach the floor, so the ladder is empty
    // and the encoder refuses (VoiceLetterTooLong) instead of degrading.
    expect(opusBitrateLadder(75, voiceLetterBudgetBytes), isEmpty);
    expect(opusBitrateLadder(120, voiceLetterBudgetBytes), isEmpty);
  });

  test('decimate 48 -> 16 keeps a 1 kHz tone and drops a 10 kHz one', () {
    final x = Int16List(48000);
    for (var i = 0; i < x.length; i++) {
      x[i] =
          (6000 * sin(2 * pi * 1000 * i / 48000) +
                  6000 * sin(2 * pi * 10000 * i / 48000))
              .round();
    }
    final y = decimate(x, 3, cutoffHz: 7000);
    expect(y, hasLength(16000));
    // 1 kHz alone is RMS 4243; the 10 kHz half must be gone (aliased
    // energy would push the RMS toward 6000).
    expect(rmsOf(y, 1000, 15000), closeTo(4243, 400));
  });

  test('downsample2x keeps a 300 Hz tone and halves the length', () {
    final x = Int16List(16000);
    for (var i = 0; i < x.length; i++) {
      x[i] = (8000 * sin(2 * pi * 300 * i / 16000)).round();
    }
    final y = downsample2x(x);
    expect(y, hasLength(8000));
    final rmsIn = rmsOf(x, 1000, 15000);
    final rmsOut = rmsOf(y, 500, 7500);
    expect(rmsOut / rmsIn, closeTo(1.0, 0.05));
  });

  test('normalizeSpeech at 16 kHz never clips and ramps the floor', () {
    final x = Int16List(48000);
    final r = Random(3);
    for (var i = 0; i < x.length; i++) {
      var v = (r.nextDouble() * 2 - 1) * 200;
      if (i >= 16000 && i < 32000) v += 12000 * sin(2 * pi * 200 * i / 16000);
      x[i] = v.round().clamp(-32768, 32767);
    }
    final y = normalizeSpeech(x);
    var peak = 0;
    for (final s in y) {
      if (s.abs() > peak) peak = s.abs();
    }
    expect(peak, lessThanOrEqualTo(32767));
    expect(rmsOf(y, 17000, 31000), inInclusiveRange(2200, 4500));
    expect(rmsOf(y, 0, 14000), lessThan(rmsOf(y, 17000, 31000) / 4));
  });

  test('a quiet room-noise take is not lifted into clipping', () {
    // The exact failure of 2026-09-21: -38 dBFS noise, gain x8, clipped.
    final x = take(noiseRms: 400, withTone: false);
    final y = normalizeSpeech(x, sampleRate: 8000);
    var peak = 0;
    for (final s in y) {
      if (s.abs() > peak) peak = s.abs();
    }
    expect(peak, lessThan(32767));
    expect(rmsOf(y, 0, y.length), lessThan(2000));
  });
}
