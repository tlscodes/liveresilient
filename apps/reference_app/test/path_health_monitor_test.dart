/// Path-continuity tests: a degraded path causes an automatic switch to
/// the next ranked path (call continues, no escalation); only a fully
/// unhealthy path set triggers the recovery callback, exactly once per
/// healthy→unhealthy edge.
library;

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_webrtc/media_webrtc.dart';
import 'package:reference_app/src/path_health_monitor.dart';

/// Scripted [TransportChannel]: `send` pops from [script] (falls back to
/// [fallback]); `probe` returns [probeResult].
class _ScriptedChannel implements TransportChannel {
  _ScriptedChannel(this.name, {int rttMs = 50})
    : health = ChannelHealth(
        reliabilityPrior: 1.0,
        bandwidth: 1.0,
        rttMs: rttMs,
      );

  @override
  final String name;

  @override
  final ChannelHealth health;

  final List<SendResult> script = <SendResult>[];
  SendResult fallback = const SendResult(SendStatus.ok, rttMs: 40);
  bool probeResult = true;
  int sends = 0;
  int probes = 0;

  @override
  Future<bool> probe() async {
    probes++;
    return probeResult;
  }

  @override
  Future<SendResult> send(List<int> payload) async {
    sends++;
    return script.isNotEmpty ? script.removeAt(0) : fallback;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  group('PathHealthMonitor with scripted paths', () {
    test('degraded primary path switches to the healthy secondary and the '
        'call continues — no recovery fired', () async {
      final primary = _ScriptedChannel('primary', rttMs: 20);
      final secondary = _ScriptedChannel('secondary', rttMs: 200);
      var recoveries = 0;
      final monitor = PathHealthMonitor(
        createSelector: () =>
            PathSelector(<TransportChannel>[primary, secondary]),
        onUnhealthy: () async => recoveries++,
      );

      // Healthy baseline: the lower-RTT primary is ranked first and
      // serves every probe alone.
      await monitor.evaluateNow();
      expect(primary.sends, 1);
      expect(secondary.sends, 0);

      // Primary degrades hard: every probe on it now fails, so the
      // selector fails over to the secondary within the same cycle.
      primary.fallback = const SendResult(SendStatus.unavailable);
      for (var i = 0; i < 5; i++) {
        await monitor.evaluateNow();
      }
      expect(secondary.sends, greaterThanOrEqualTo(4));
      expect(recoveries, 0, reason: 'a surviving path means no escalation');

      // The degraded primary is out of rotation (score 0 after the
      // unavailable observation), the secondary carries the call.
      final primarySendsSoFar = primary.sends;
      await monitor.evaluateNow();
      expect(primary.sends, primarySendsSoFar);
      expect(recoveries, 0);
      await monitor.dispose();
    });

    test('all paths down fires recovery exactly once, then re-arms after the '
        'path heals', () async {
      final path = _ScriptedChannel('only', rttMs: 30);
      var recoveries = 0;
      // Note: the breaker never trips here — an unavailable observation
      // zeroes the health score, and score-0 paths are skipped before any
      // further send could accumulate failures. Recovery detection runs on
      // score + probe outcomes, so default breaker timings are fine.
      final monitor = PathHealthMonitor(
        createSelector: () => PathSelector(<TransportChannel>[path]),
        onUnhealthy: () async => recoveries++,
      );

      await monitor.evaluateNow();
      expect(recoveries, 0);

      // Hard drop: stats gone, probes fail.
      path.fallback = const SendResult(SendStatus.unavailable);
      path.probeResult = false;
      await monitor.evaluateNow();
      expect(recoveries, 1);

      // Still down: the latch keeps it at one escalation.
      await monitor.evaluateNow();
      await monitor.evaluateNow();
      expect(recoveries, 1);

      // Recovery succeeded (ICE restart brought the path back): probes
      // succeed again, delivery resumes, the latch re-arms.
      path.fallback = const SendResult(SendStatus.ok, rttMs: 35);
      path.probeResult = true;
      // First cycle: refresh's probe brings the path back online;
      // second cycle: a probe delivery succeeds and re-arms the latch.
      await monitor.evaluateNow();
      await monitor.evaluateNow();
      expect(recoveries, 1);

      // A second hard drop fires again — the edge trigger re-armed.
      path.fallback = const SendResult(SendStatus.unavailable);
      path.probeResult = false;
      for (var i = 0; i < 4 && recoveries < 2; i++) {
        await monitor.evaluateNow();
      }
      expect(recoveries, 2);
      await monitor.dispose();
    });

    test('sustained heavy loss (transient failures, probe still up) escalates '
        'after consecutive failed delivery cycles', () async {
      final path = _ScriptedChannel('lossy', rttMs: 30);
      var recoveries = 0;
      final monitor = PathHealthMonitor(
        createSelector: () => PathSelector(<TransportChannel>[path]),
        onUnhealthy: () async => recoveries++,
        unhealthyAfterConsecutiveFailures: 3,
      );

      await monitor.evaluateNow();
      expect(recoveries, 0);

      // Heavy packet loss: probes keep succeeding (the path is
      // reachable) but delivery keeps failing — reachable-but-unusable.
      path.fallback = const SendResult(SendStatus.transient, rttMs: 900);
      await monitor.evaluateNow();
      await monitor.evaluateNow();
      expect(recoveries, 0, reason: 'below the consecutive threshold');
      await monitor.evaluateNow();
      expect(recoveries, 1, reason: '3rd consecutive failed cycle');
      await monitor.evaluateNow();
      expect(recoveries, 1, reason: 'latched until delivery resumes');
      await monitor.dispose();
    });

    test('start re-arms the latch and stop halts the timer', () async {
      final path = _ScriptedChannel('only');
      var recoveries = 0;
      final monitor = PathHealthMonitor(
        createSelector: () => PathSelector(<TransportChannel>[path]),
        onUnhealthy: () async => recoveries++,
        interval: const Duration(milliseconds: 5),
      );
      expect(monitor.isRunning, isFalse);
      monitor.start();
      expect(monitor.isRunning, isTrue);
      monitor.stop();
      expect(monitor.isRunning, isFalse);
      await monitor.dispose();
      monitor.start();
      expect(monitor.isRunning, isFalse, reason: 'disposed monitors stay off');
      expect(recoveries, 0);
    });
  });

  group('WebRtcPathChannel stats scoring', () {
    RawRtcCounters counters({
      required int received,
      required int lost,
      double? rttSeconds = 0.05,
    }) {
      return RawRtcCounters(
        packetsReceived: received,
        packetsLost: lost,
        packetsSent: received,
        bytesReceived: received * 100,
        bytesSent: received * 100,
        jitterSeconds: 0.01,
        currentRoundTripTimeSeconds: rttSeconds,
        availableOutgoingBitrateBps: null,
      );
    }

    test('healthy flow reports ok with measured RTT', () async {
      var read = 0;
      final channel = WebRtcPathChannel(
        readCounters: () async {
          read++;
          return counters(received: read * 100, lost: 0);
        },
      );
      final first = await channel.send(const <int>[0]);
      expect(first.status, SendStatus.ok, reason: 'first read is baseline');
      final second = await channel.send(const <int>[0]);
      expect(second.status, SendStatus.ok);
      expect(second.rttMs, 50);
      expect(await channel.probe(), isTrue);
    });

    test('loss above the threshold reports transient', () async {
      var read = 0;
      final channel = WebRtcPathChannel(
        readCounters: () async {
          read++;
          // 100 received / 50 newly lost each interval = 33% loss.
          return counters(received: read * 100, lost: read * 50);
        },
      );
      await channel.send(const <int>[0]);
      final result = await channel.send(const <int>[0]);
      expect(result.status, SendStatus.transient);
    });

    test('missing counters report unavailable; a silent interval is only '
        'transient', () async {
      RawRtcCounters? next;
      final channel = WebRtcPathChannel(readCounters: () async => next);
      expect(
        (await channel.send(const <int>[0])).status,
        SendStatus.unavailable,
      );
      expect(await channel.probe(), isFalse);

      next = counters(received: 500, lost: 0);
      expect((await channel.send(const <int>[0])).status, SendStatus.ok);
      // No new packets since the last read: cannot confirm delivery, but
      // not a hard failure either.
      expect((await channel.send(const <int>[0])).status, SendStatus.transient);
    });
  });
}
