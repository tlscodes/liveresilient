import 'dart:math';
import 'dart:typed_data';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:test/test.dart';

/// 20 ms frame at 16 kHz.
const frameLen = 320;

Int16List toneFrame({double amplitude = 8000, double hz = 200}) {
  final f = Int16List(frameLen);
  for (var i = 0; i < frameLen; i++) {
    f[i] = (amplitude * sin(2 * pi * hz * i / 16000)).round();
  }
  return f;
}

Int16List noiseFrame(int amplitude, int seed) {
  final rng = Random(seed);
  final f = Int16List(frameLen);
  for (var i = 0; i < frameLen; i++) {
    f[i] = rng.nextInt(2 * amplitude + 1) - amplitude;
  }
  return f;
}

/// Quiet but rapidly zero-crossing frame, like an unvoiced consonant.
Int16List fricativeFrame() {
  final f = Int16List(frameLen);
  for (var i = 0; i < frameLen; i++) {
    f[i] = (i.isEven ? 1 : -1) * 300;
  }
  return f;
}

void main() {
  group('isSpeech', () {
    test('loud voiced frame is speech, faint room noise is not', () {
      final vad = SilenceSuppressionVAD();
      expect(vad.isSpeech(toneFrame()), isTrue);
      expect(vad.isSpeech(noiseFrame(40, 1)), isFalse);
      expect(vad.isSpeech(Int16List(frameLen)), isFalse); // digital silence
      expect(vad.isSpeech(Int16List(0)), isFalse);
    });

    test('quiet high-ZCR frame (unvoiced consonant) is speech', () {
      final vad = SilenceSuppressionVAD();
      expect(vad.isSpeech(fricativeFrame()), isTrue);
    });

    test('sensitivity is configurable', () {
      final deaf = SilenceSuppressionVAD(rmsThreshold: 20000);
      expect(deaf.isSpeech(toneFrame()), isFalse);
      final keen = SilenceSuppressionVAD(rmsThreshold: 10);
      expect(keen.isSpeech(noiseFrame(40, 1)), isTrue);
    });
  });

  group('process', () {
    test('silence drops frames and pings exactly once per second', () {
      final vad = SilenceSuppressionVAD(
        hangoverFrames: 0,
        keepAliveIntervalMs: 1000,
      );
      final quiet = noiseFrame(30, 2);
      var sends = 0, drops = 0, pings = 0;
      // 10 s of pure silence, one 20 ms frame per tick.
      for (var ms = 0; ms < 10000; ms += 20) {
        switch (vad.process(quiet, ms)) {
          case VadAction.send:
            sends++;
          case VadAction.drop:
            drops++;
          case VadAction.keepAlive:
            pings++;
        }
      }
      expect(sends, 0, reason: 'no codec frames during silence');
      expect(pings, 10, reason: 'one keep-alive per second of silence');
      expect(drops, 500 - 10);
    });

    test('speech resumes sending and hangover covers word endings', () {
      final vad = SilenceSuppressionVAD(
        hangoverFrames: 3,
        keepAliveIntervalMs: 1000,
      );
      final quiet = noiseFrame(30, 3);
      var ms = 0;
      // lead-in silence long enough to leave keep-alive mode
      for (var i = 0; i < 100; i++, ms += 20) {
        vad.process(quiet, ms);
      }
      expect(vad.process(toneFrame(), ms), VadAction.send);
      ms += 20;
      // 3 hangover frames after speech stops are still sent
      for (var i = 0; i < 3; i++, ms += 20) {
        expect(
          vad.process(quiet, ms),
          VadAction.send,
          reason: 'hangover frame $i',
        );
      }
      expect(vad.process(quiet, ms), VadAction.drop);
    });

    test('keep-alive ping is 2 bytes and receiver-distinguishable', () {
      expect(SilenceSuppressionVAD.keepAlivePing.length, 2);
      // Sliding-window datagrams are always >= 4 bytes (header + CRC),
      // so a 2-byte ping can never be confused with one.
      final unpacker = SlidingWindowUnpacker();
      expect(unpacker.offer(SilenceSuppressionVAD.keepAlivePing), isEmpty);
    });

    test('byte budget: VAD cuts transmitted codec frames on a half-silent '
        'conversation', () {
      final vad = SilenceSuppressionVAD(
        hangoverFrames: 5,
        keepAliveIntervalMs: 1000,
      );
      final quiet = noiseFrame(30, 4);
      var framesSent = 0, framesTotal = 0;
      var ms = 0;
      // alternating 2 s talk / 2 s pause, 20 s total
      for (var second = 0; second < 20; second++) {
        final talking = (second ~/ 2).isEven;
        for (var i = 0; i < 50; i++, ms += 20) {
          framesTotal++;
          final frame = talking ? toneFrame() : quiet;
          if (vad.process(frame, ms) == VadAction.send) framesSent++;
        }
      }
      expect(
        framesSent / framesTotal,
        closeTo(0.5, 0.05),
        reason: 'roughly the talk half is sent, the pause half is not',
      );
    });
  });

  group('steady-state allocation discipline', () {
    test('keep-alive buffer is a single cached instance, never rebuilt', () {
      final a = SilenceSuppressionVAD.keepAlivePing;
      final b = SilenceSuppressionVAD.keepAlivePing;
      expect(identical(a, b), isTrue);
    });

    test('sustained processing does not degrade: 100k frames complete '
        'quickly and classification stays stable', () {
      // Dart offers no direct per-call allocation counter in unit tests;
      // this pins the observable proxies: the hot path finishes 100k
      // frames well inside a time budget (no per-call garbage churn) and
      // diagnostics counters match exactly.
      final vad = SilenceSuppressionVAD(hangoverFrames: 0);
      final voice = toneFrame();
      final quiet = noiseFrame(30, 5);
      final sw = Stopwatch()..start();
      for (var i = 0; i < 100000; i++) {
        vad.process(i.isEven ? voice : quiet, i * 20);
      }
      sw.stop();
      expect(vad.speechFrames, 50000);
      expect(vad.silenceFrames, 50000);
      expect(
        sw.elapsedMilliseconds,
        lessThan(2000),
        reason: '100k frames must stay far from allocation-churn pace',
      );
    });
  });
}
