/// Path-health soak: drives the production monitor wiring
/// (WebRtcPathChannel + PathSelector via buildWebRtcPathHealthMonitor)
/// through many episodes of simulated packet loss, RTT jitter, and
/// intermittent dead-path stretches, asserting the escalation callback
/// fires exactly once per dead episode — never for tolerable loss or
/// jitter — and that the monitor recovers and re-arms every time.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:media_webrtc/media_webrtc.dart';
import 'package:reference_app/src/path_health_monitor.dart';

void main() {
  test('soak: 50 impaired-network episodes — one escalation per dead '
      'stretch, none for loss/jitter within tolerance', () async {
    var packetsReceived = 0;
    var packetsLost = 0;
    var rttSeconds = 0.05;
    var dead = false;

    Future<RawRtcCounters?> readCounters() async {
      if (dead) return null;
      return RawRtcCounters(
        packetsReceived: packetsReceived,
        packetsLost: packetsLost,
        packetsSent: packetsReceived,
        bytesReceived: packetsReceived * 100,
        bytesSent: packetsReceived * 100,
        jitterSeconds: 0.01,
        currentRoundTripTimeSeconds: rttSeconds,
      );
    }

    var escalations = 0;
    final monitor = buildWebRtcPathHealthMonitor(
      readCounters: readCounters,
      onUnhealthy: () async => escalations++,
    );
    monitor.start();
    monitor.stop(); // timer off; the soak drives cycles deterministically.

    const episodes = 50;
    var deadEpisodes = 0;
    for (var episode = 0; episode < episodes; episode++) {
      // Healthy stretch with RTT jitter (20–200ms swings stay tolerable).
      for (var tick = 0; tick < 6; tick++) {
        packetsReceived += 100;
        rttSeconds = 0.02 + 0.03 * (tick % 4);
        await monitor.evaluateNow();
      }
      // Mild packet loss (~5%, below the 15% degradation threshold).
      for (var tick = 0; tick < 3; tick++) {
        packetsReceived += 95;
        packetsLost += 5;
        await monitor.evaluateNow();
      }
      // Every 5th episode the path dies outright for a few cycles; the
      // escalation triggers the call's reconnect, which lands on a fresh
      // path — modeled exactly like production: the call phase leaves
      // `connected` (stop) and re-enters it (start).
      if (episode % 5 == 4) {
        deadEpisodes++;
        dead = true;
        for (var tick = 0; tick < 4; tick++) {
          await monitor.evaluateNow();
        }
        dead = false;
        monitor.stop();
        monitor.start();
        monitor.stop(); // timer stays off; ticks remain test-driven.
      }
    }

    expect(deadEpisodes, 10);
    expect(
      escalations,
      deadEpisodes,
      reason:
          'exactly one escalation per dead stretch: tolerable loss and '
          'jitter must never fire, and a dead path must fire exactly once',
    );
    await monitor.dispose();
    expect(monitor.isRunning, isFalse);
  });
}
