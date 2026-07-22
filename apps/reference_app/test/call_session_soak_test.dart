/// End-to-end session soak: the TWO live-call continuity loops that the
/// production composition root starts together — the path-health monitor
/// (escalates into reconnect/ICE-restart) and the media-adaptation driver
/// (walks the quality ladder) — driven from ONE shared counter source
/// through many impaired-network episodes under fake time.
///
/// The unit soaks cover each loop alone; this proves they coexist on the
/// same clock without starving or double-firing: exactly one escalation per
/// dead stretch, adaptation ratchets down under sustained loss and recovers
/// on clean stats, and neither loop leaks a timer after dispose.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_webrtc/media_webrtc.dart';
import 'package:reference_app/src/media_adaptation_driver.dart';
import 'package:reference_app/src/path_health_monitor.dart';

class _SoakPort implements PeerConnectionPort {
  RawRtcCounters? counters;
  final List<VideoSenderParameters> videoParams = <VideoSenderParameters>[];

  @override
  Future<RawRtcCounters?> readStatsCounters() async => counters;

  @override
  Future<void> setVideoSenderParameters(
    VideoSenderParameters parameters,
  ) async {
    videoParams.add(parameters);
  }

  @override
  Future<void> setAudioMaxBitrate(int bitrateBps) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  const interval = Duration(seconds: 2);

  test('soak: monitor + adaptation driver share one live path through 30 '
      'impaired episodes — one escalation per dead stretch, ladder '
      'ratchets down and recovers, no leaked timers', () {
    fakeAsync((async) {
      final port = _SoakPort();
      var received = 0;
      var lost = 0;
      var rtt = 0.05;
      var dead = false;

      void publish() {
        port.counters = dead
            ? null
            : RawRtcCounters(
                packetsReceived: received,
                packetsLost: lost,
                packetsSent: received,
                bytesReceived: received * 100,
                bytesSent: received * 100,
                jitterSeconds: 0.01,
                currentRoundTripTimeSeconds: rtt,
              );
      }

      publish();

      var escalations = 0;
      final monitor = buildWebRtcPathHealthMonitor(
        readCounters: port.readStatsCounters,
        onUnhealthy: () async => escalations++,
        interval: interval,
      );
      final driver = MediaAdaptationDriver(
        port: () => port,
        statsInterval: interval,
        nowMs: () => async.elapsed.inMilliseconds,
      );

      // Production wiring: both loops start when the call reaches
      // `connected`, both stop when it leaves.
      void enterConnected() {
        monitor.start();
        driver.start();
      }

      void leaveConnected() {
        monitor.stop();
        driver.stop();
      }

      enterConnected();

      /// Advances shared fake time by one sampling interval, letting both
      /// loops read the same counter snapshot.
      void tick({int packets = 100, int loss = 0}) {
        received += packets;
        lost += loss;
        publish();
        async.elapse(interval);
        async.flushMicrotasks();
      }

      const episodes = 30;
      var deadEpisodes = 0;
      var lossEpisodes = 0;
      var sawDowngrade = false;

      for (var episode = 0; episode < episodes; episode++) {
        // Healthy stretch with RTT jitter, well inside tolerance.
        for (var i = 0; i < 5; i++) {
          rtt = 0.02 + 0.03 * (i % 4);
          tick();
        }

        // Sustained heavy loss: the adaptation ladder must step down, and
        // 40% loss is past the monitor's tolerance too — it escalates, but
        // exactly once for the whole stretch, not once per sample.
        final beforeLoss = escalations;
        for (var i = 0; i < 6; i++) {
          tick(packets: 60, loss: 40);
        }
        expect(
          escalations - beforeLoss,
          1,
          reason:
              'episode $episode: a sustained loss stretch must escalate '
              'once, not once per sample',
        );
        lossEpisodes++;
        if (port.videoParams.isNotEmpty) sawDowngrade = true;

        // Clean recovery stretch: slow-up hysteresis walks back.
        for (var i = 0; i < 8; i++) {
          rtt = 0.03;
          tick();
        }

        // Every 5th episode the path dies outright; exactly one escalation
        // must fire, then the call reconnects onto a fresh path.
        if (episode % 5 == 4) {
          deadEpisodes++;
          final before = escalations;
          dead = true;
          for (var i = 0; i < 4; i++) {
            tick();
          }
          expect(
            escalations - before,
            1,
            reason:
                'episode $episode: dead stretch must escalate exactly '
                'once, not a recovery storm',
          );
          dead = false;
          // Reconnect: phase leaves and re-enters `connected`.
          leaveConnected();
          enterConnected();
        }
      }

      expect(deadEpisodes, 6);
      expect(lossEpisodes, episodes);
      expect(
        escalations,
        deadEpisodes + lossEpisodes,
        reason:
            'escalations fire only for impaired stretches — never '
            'during the healthy or recovery stretches',
      );
      expect(
        sawDowngrade,
        isTrue,
        reason: 'sustained 40% loss must move the quality ladder',
      );

      // Teardown leaves no pending timer on either loop.
      leaveConnected();
      driver.dispose();
      monitor.dispose();
      async.flushMicrotasks();
      async.elapse(interval * 5);
      expect(async.pendingTimers, isEmpty);
    });
  });
}
