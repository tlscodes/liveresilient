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

  group('RtcStatsSampler stop()/start() race', () {
    test(
      'a read that resolves after stop() must not resurrect stale state, '
      'and the next start() treats its first poll as a fresh baseline',
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

        final emitted = <RtcStatsSample>[];
        sampler.samples.listen(emitted.add);

        sampler.start();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(callCount, 1, reason: 'the first tick must have begun a read');
        final staleRead = pending!;

        // stop() while that read is still unresolved.
        sampler.stop();

        // Resolve the STALE read only after stop(): the epoch guard must
        // silently drop it -- no state mutation, no emission -- even though
        // it carries large cumulative counters that would otherwise become
        // a bogus "_previous" baseline.
        staleRead.complete(
          _counters(
            packetsReceived: 100000,
            packetsLost: 0,
            packetsSent: 100000,
            bytesReceived: 100000000,
            bytesSent: 100000000,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          emitted,
          isEmpty,
          reason: 'a read resolving after stop() must never emit a sample',
        );

        // start() again: its first poll only seeds a fresh baseline, so it
        // must not emit either -- proving the stale pre-stop counters were
        // discarded rather than reused as "_previous".
        sampler.start();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(callCount, 2, reason: 'restart must poll again');
        pending!.complete(
          _counters(
            packetsReceived: 5,
            packetsLost: 0,
            packetsSent: 5,
            bytesReceived: 500,
            bytesSent: 500,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          emitted,
          isEmpty,
          reason: 'the first poll after restart only seeds the new baseline',
        );

        // A second poll after restart computes a delta against the FRESH
        // baseline (5 packets / 500 bytes). If the stale pre-stop counters
        // (100000 packets / 1e8 bytes) had leaked through, this delta would
        // go negative and the sample would be silently skipped instead of
        // emitted with the small, correct delta asserted below.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(callCount, 3);
        pending!.complete(
          _counters(
            packetsReceived: 10,
            packetsLost: 0,
            packetsSent: 10,
            bytesReceived: 1000,
            bytesSent: 1000,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(emitted, hasLength(1));
        expect(emitted.single.packetLossFraction, 0.0);
      },
    );
  });
}
