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

  test('the mode-6 bitrate ladder for 30 s in ten letters', () {
    // 500 packets: 40670 - 4 - 500 = 40166 B -> 10711 bit/s x 0.93 = 9961
    // -> rounds to 10000, then 12 % steps to 6000 (Fable 5.1, 2026-09-21).
    expect(opusBitrateLadder(30, 10 * 4067), [10000, 8800, 7700, 6800, 6000]);
    // Short takes are capped at 16 k; long takes fall to the fixed ladder.
    expect(opusBitrateLadder(5, 10 * 4067).first, 16000);
    expect(opusBitrateLadder(60, 10 * 4067), isEmpty);
    expect(opusBitrateLadder(0, 10 * 4067), isEmpty);
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
