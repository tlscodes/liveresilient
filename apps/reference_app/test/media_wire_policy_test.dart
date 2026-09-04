/// The adaptation driver's mid-call wire policy: only a path that shows the
/// flood (loss, or a round trip inflated past twice its floor) re-fits the
/// Opus rate and, after the re-evaluator's dwell, asks for a longer packet
/// time — once, never shorter, never on a clean link whatever the estimate.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_webrtc/media_webrtc.dart';
import 'package:reference_app/src/media_adaptation_driver.dart';

class _FakePort implements PeerConnectionPort {
  RawRtcCounters? counters;
  final List<int> audioBitrates = <int>[];

  @override
  Future<RawRtcCounters?> readStatsCounters() async => counters;

  @override
  Future<void> setVideoSenderParameters(
    VideoSenderParameters parameters,
  ) async {}

  @override
  Future<void> setAudioMaxBitrate(int bitrateBps) async {
    audioBitrates.add(bitrateBps);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

RawRtcCounters _counters(
  int received, {
  required int lost,
  required double availableBps,
  double rttSeconds = 0.05,
}) {
  return RawRtcCounters(
    packetsReceived: received,
    packetsLost: lost,
    packetsSent: received,
    bytesReceived: received * 100,
    bytesSent: received * 100,
    jitterSeconds: 0.01,
    currentRoundTripTimeSeconds: rttSeconds,
    availableOutgoingBitrateBps: availableBps,
  );
}

void main() {
  const tick = Duration(milliseconds: 100);

  test('a clean link never renegotiates, whatever the estimate says', () {
    fakeAsync((async) {
      final port = _FakePort();
      var calls = 0;
      final driver = MediaAdaptationDriver(
        port: () => port,
        statsInterval: tick,
        nowMs: () => async.elapsed.inMilliseconds,
        onRenegotiateWirePolicy: (_) async => calls++,
      );
      driver.start();
      var received = 0;
      // An audio-only call's estimate sits near its send rate on a clean
      // link (~80 kbit/s): not congestion, so no re-evaluation at all.
      for (var i = 0; i < 8; i++) {
        received += 1000;
        port.counters = _counters(received, lost: 0, availableBps: 80000);
        async.elapse(tick);
        async.flushMicrotasks();
      }
      expect(calls, 0);
      expect(driver.wirePolicy.ptimeMs, 20);
      expect(port.audioBitrates, isEmpty);
      driver.dispose();
      async.flushMicrotasks();
    });
  });

  test('a flooded thin link re-fits the rate at once and lengthens the packet '
      'time after the dwell, once', () {
    fakeAsync((async) {
      final port = _FakePort();
      final renegotiated = <OpusWireBudget>[];
      final verdicts = <OpusPolicyDecision>[];
      final driver = MediaAdaptationDriver(
        port: () => port,
        statsInterval: tick,
        nowMs: () => async.elapsed.inMilliseconds,
        onRenegotiateWirePolicy: (policy) async => renegotiated.add(policy),
      );
      driver.wireDecisions.listen(verdicts.add);
      expect(driver.wirePolicy.ptimeMs, 20, reason: 'the unknown-link default');

      var received = 0;
      var lost = 0;
      void cleanTick() {
        received += 1000;
        port.counters = _counters(received, lost: lost, availableBps: 3000000);
        async.elapse(tick);
        async.flushMicrotasks();
      }

      // 40 kbit/s estimate with 9 % loss and a 1.9 s round trip: the flood.
      void floodedTick() {
        received += 910;
        lost += 90;
        port.counters = _counters(
          received,
          lost: lost,
          availableBps: 40000,
          rttSeconds: 1.9,
        );
        async.elapse(tick);
        async.flushMicrotasks();
      }

      driver.start();
      cleanTick(); // baseline poll
      cleanTick();
      expect(verdicts, isEmpty, reason: 'clean samples feed nothing');

      floodedTick();
      expect(renegotiated, isEmpty, reason: 'ptime waits for the dwell');
      expect(
        port.audioBitrates,
        isNotEmpty,
        reason: 'the rate is an encoder parameter and follows at once',
      );
      floodedTick();
      floodedTick();
      expect(renegotiated, hasLength(1));
      // Duplex on 40 kbit/s: the longest packet time with a rate that fits
      // under 70 % occupancy per stream (the admission's own arithmetic).
      final admitted = renegotiated.single;
      expect(admitted.ptimeMs, 120);
      expect(admitted.opusRateBps, lessThanOrEqualTo(10000));
      expect(admitted.opusRateBps, greaterThanOrEqualTo(6000));
      expect(driver.wirePolicy.ptimeMs, 120);
      // The wire ceiling was applied; the ladder's own rung may cap tighter.
      expect(port.audioBitrates, contains(admitted.opusRateBps));
      expect(port.audioBitrates.last, lessThanOrEqualTo(admitted.opusRateBps));

      // The same flood keeps the policy steady: no second renegotiation; a
      // recovered link raises the rate but never shortens the packet time.
      for (var i = 0; i < 5; i++) {
        floodedTick();
      }
      expect(renegotiated, hasLength(1));
      lost += 400; // one more lossy sample with a generous estimate
      received += 600;
      port.counters = _counters(
        received,
        lost: lost,
        availableBps: 3000000,
        rttSeconds: 1.9,
      );
      async.elapse(tick);
      async.flushMicrotasks();
      expect(renegotiated, hasLength(1), reason: 'never shorter mid-call');

      driver.stop();
      async.flushMicrotasks();
      driver.dispose();
      async.flushMicrotasks();
      expect(async.periodicTimerCount, 0);
    });
  });

  test('samples without an estimate leave the wire policy alone', () {
    fakeAsync((async) {
      final port = _FakePort();
      var calls = 0;
      final driver = MediaAdaptationDriver(
        port: () => port,
        statsInterval: tick,
        nowMs: () => async.elapsed.inMilliseconds,
        onRenegotiateWirePolicy: (_) async => calls++,
      );
      driver.start();
      var received = 0;
      for (var i = 0; i < 6; i++) {
        received += 700;
        port.counters = RawRtcCounters(
          packetsReceived: received,
          packetsLost: i * 300,
          packetsSent: received,
          bytesReceived: received * 100,
          bytesSent: received * 100,
          jitterSeconds: 0.01,
        );
        async.elapse(tick);
        async.flushMicrotasks();
      }
      expect(calls, 0);
      expect(driver.wirePolicy.ptimeMs, 20);
      driver.dispose();
      async.flushMicrotasks();
    });
  });
}
