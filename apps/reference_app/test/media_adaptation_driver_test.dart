/// Live-call adaptation loop: simulated degrading stats drive the session
/// down the quality ladder to audio-only through REAL sampler + policy +
/// applied sender parameters, and sustained clean stats recover it.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_webrtc/media_webrtc.dart';
import 'package:reference_app/src/media_adaptation_driver.dart';

/// Fake port: scripted counters in, applied sender parameters out. Only the
/// members the adaptation loop touches are functional.
class _FakeAdaptationPort implements PeerConnectionPort {
  RawRtcCounters? counters;
  final List<VideoSenderParameters> videoParams = <VideoSenderParameters>[];
  final List<int> audioBitrates = <int>[];

  @override
  Future<RawRtcCounters?> readStatsCounters() async => counters;

  @override
  Future<void> setVideoSenderParameters(
    VideoSenderParameters parameters,
  ) async {
    videoParams.add(parameters);
  }

  @override
  Future<void> setAudioMaxBitrate(int bitrateBps) async {
    audioBitrates.add(bitrateBps);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  const tick = Duration(milliseconds: 100);

  RawRtcCounters counters({
    required int received,
    required int lost,
    double rttSeconds = 0.05,
    double? availableBps = 3000000,
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

  test('rising loss steps the session down to audio-only and sustained '
      'clean conditions recover it', () {
    fakeAsync((async) {
      final port = _FakeAdaptationPort();
      final decisions = <MediaPolicyDecision>[];
      final driver = MediaAdaptationDriver(
        port: () => port,
        statsInterval: tick,
        nowMs: () => async.elapsed.inMilliseconds,
      );
      driver.decisions.listen(decisions.add);
      expect(driver.profile, MediaProfile.medium);

      var received = 0;
      var lost = 0;
      void healthyTick() {
        received += 1000;
        port.counters = counters(received: received, lost: lost);
        async.elapse(tick);
        async.flushMicrotasks();
      }

      void severeLossTick() {
        received += 700;
        lost += 300; // 30% interval loss >= the 20% severe threshold.
        port.counters = counters(received: received, lost: lost);
        async.elapse(tick);
        async.flushMicrotasks();
      }

      driver.start();
      healthyTick(); // Baseline poll (no sample yet).
      healthyTick();
      expect(decisions, isEmpty, reason: 'healthy stats change nothing');

      // Severe loss: two-step drops walk medium → minimal → audioOnly.
      severeLossTick();
      expect(driver.profile, MediaProfile.minimal);
      severeLossTick();
      expect(driver.profile, MediaProfile.audioOnly);

      // The ladder was APPLIED to the sender, ending with video disabled
      // and the audio floor protected.
      expect(port.videoParams, hasLength(2));
      expect(port.videoParams.first.maxBitrateBps, 120000);
      expect(port.videoParams.last.enabled, isFalse);
      expect(port.audioBitrates.last, 16000);
      expect(decisions.map((d) => d.next).toList(), [
        MediaProfile.minimal,
        MediaProfile.audioOnly,
      ]);

      // Recovery: 8 consecutive clean samples (slow-up hysteresis) with
      // ample measured bandwidth headroom bring video back one step.
      for (var i = 0; i < 8; i++) {
        healthyTick();
      }
      expect(driver.profile, MediaProfile.minimal);
      expect(port.videoParams.last.enabled, isTrue);
      expect(
        port.videoParams.last.maxBitrateBps,
        120000,
        reason: 'recovery re-enters the ladder at the minimal tier',
      );

      driver.stop();
      async.flushMicrotasks();
      driver.dispose();
      async.flushMicrotasks();
      expect(async.periodicTimerCount, 0, reason: 'sampler timer leaked');
    });
  });

  test('a dead port (null counters) never produces decisions, and start '
      'after stop resets hysteresis but keeps the earned profile', () {
    fakeAsync((async) {
      final port = _FakeAdaptationPort();
      final driver = MediaAdaptationDriver(
        port: () => port,
        statsInterval: tick,
        nowMs: () => async.elapsed.inMilliseconds,
      );

      driver.start();
      port.counters = null;
      for (var i = 0; i < 5; i++) {
        async.elapse(tick);
        async.flushMicrotasks();
      }
      expect(driver.profile, MediaProfile.medium);
      expect(port.videoParams, isEmpty);

      // Degrade to audioOnly, then simulate the reconnect stop/start.
      var received = 0;
      var lost = 0;
      void tickWith({required int good, required int bad}) {
        received += good;
        lost += bad;
        port.counters = counters(received: received, lost: lost);
        async.elapse(tick);
        async.flushMicrotasks();
      }

      tickWith(good: 1000, bad: 0); // baseline
      tickWith(good: 700, bad: 300);
      tickWith(good: 700, bad: 300);
      expect(driver.profile, MediaProfile.audioOnly);

      driver.stop();
      driver.start();
      expect(
        driver.profile,
        MediaProfile.audioOnly,
        reason:
            'a reconnected call re-joins at its degraded level and '
            'earns the upgrade back through hysteresis',
      );

      // Production teardown order: the phase listener stops the driver
      // before the session disposes it (a broadcast-subscription cancel
      // never settles under fakeAsync, so the timer must already be gone).
      driver.stop();
      driver.dispose();
      async.flushMicrotasks();
      expect(async.periodicTimerCount, 0);
    });
  });
}
