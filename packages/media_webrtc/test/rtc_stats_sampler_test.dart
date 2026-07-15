import 'dart:async';

import 'package:media_webrtc/media_webrtc.dart';
import 'package:test/test.dart';

RawRtcCounters _counters({
  required int packetsReceived,
  required int packetsLost,
  required int packetsSent,
  required int bytesReceived,
  required int bytesSent,
  double jitterSeconds = 0.0,
  double? rttSeconds,
  double? availableOutgoingBitrateBps,
}) => RawRtcCounters(
  packetsReceived: packetsReceived,
  packetsLost: packetsLost,
  packetsSent: packetsSent,
  bytesReceived: bytesReceived,
  bytesSent: bytesSent,
  jitterSeconds: jitterSeconds,
  currentRoundTripTimeSeconds: rttSeconds,
  availableOutgoingBitrateBps: availableOutgoingBitrateBps,
);

void main() {
  group('RtcStatsSampler single-flight', () {
    test(
      'does not start a second poll while the first is unresolved',
      () async {
        var callCount = 0;
        Completer<RawRtcCounters?>? pending;

        Future<RawRtcCounters?> reader() {
          callCount++;
          pending = Completer<RawRtcCounters?>();
          return pending!.future;
        }

        final sampler = RtcStatsSampler(
          reader: reader,
          interval: const Duration(milliseconds: 10),
        );
        addTearDown(sampler.dispose);

        sampler.start();

        // Let several timer ticks elapse while the first poll is still
        // in flight; the single-flight guard must suppress all of them.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          callCount,
          1,
          reason: 'reader must be entered exactly once while unresolved',
        );

        // Resolve the first poll; the sampler must continue and issue a
        // second poll on a later tick.
        pending!.complete(
          _counters(
            packetsReceived: 0,
            packetsLost: 0,
            packetsSent: 0,
            bytesReceived: 0,
            bytesSent: 0,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(callCount, greaterThanOrEqualTo(2));
      },
    );

    test('two completed polls emit one sample with correct math', () async {
      final responses = <RawRtcCounters>[
        _counters(
          packetsReceived: 100,
          packetsLost: 0,
          packetsSent: 50,
          bytesReceived: 10000,
          bytesSent: 5000,
          jitterSeconds: 0.01,
          rttSeconds: 0.05,
          availableOutgoingBitrateBps: 250000,
        ),
        _counters(
          packetsReceived: 190,
          packetsLost: 10,
          packetsSent: 100,
          bytesReceived: 30000,
          bytesSent: 15000,
          jitterSeconds: 0.02,
          rttSeconds: 0.1,
          availableOutgoingBitrateBps: 300000,
        ),
      ];
      var callCount = 0;
      Completer<RawRtcCounters?>? pending;
      var nowMs = 1000;

      Future<RawRtcCounters?> reader() {
        final completer = Completer<RawRtcCounters?>();
        pending = completer;
        callCount++;
        return completer.future;
      }

      final sampler = RtcStatsSampler(
        reader: reader,
        interval: const Duration(milliseconds: 5),
        nowMs: () => nowMs,
      );
      addTearDown(sampler.dispose);

      final sampleFuture = sampler.samples.first;
      sampler.start();

      // Drive the first poll deterministically: set the clock right before
      // resolving it, since the sampler reads _nowMs() synchronously in the
      // continuation after the read future completes.
      while (callCount < 1) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      nowMs = 1000;
      pending!.complete(responses[0]);

      // Let the single-flight guard clear so a second poll can be issued.
      while (callCount < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      nowMs = 2000;
      pending!.complete(responses[1]);

      final sample = await sampleFuture.timeout(const Duration(seconds: 2));

      // deltaReceived = 90, deltaLost = 10, deltaExpected = 100 -> 10% loss.
      expect(sample.packetLossFraction, closeTo(0.1, 1e-9));
      // First-ever EWMA sample seeds directly from the raw values.
      expect(sample.rttMs, 100);
      expect(sample.jitterMs, 20);
      // deltaBytesReceived = 20000 over 1000ms -> 160000 bps.
      expect(sample.incomingBitrateBps, 160000);
      // deltaBytesSent = 10000 over 1000ms -> 80000 bps.
      expect(sample.outgoingBitrateBps, 80000);
      expect(sample.availableOutgoingBitrateBps, 300000);
      expect(sample.timestampMs, 2000);
    });
  });
}
