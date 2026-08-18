import 'package:call_core/call_core.dart';
import 'package:test/test.dart';

/// The signaling keepalive derivation exists because of a measured livelock
/// (2026-08-06, T2 loss60/extreme): a FIXED 8 s liveness window on a
/// 60%-per-direction-loss link declared a live socket dead nearly every
/// window — TCP delivers under loss by DELAYING (retransmit doubling), not
/// by losing frames — and the resulting reconnect + ICE-restart loop
/// consumed the entire connect budget without one attempt completing.
void main() {
  // The e2e harness floors (the historic constants).
  const hbFloor = Duration(seconds: 2);
  const liveFloor = Duration(seconds: 8);
  const dialFloor = Duration(seconds: 10);
  const attemptsFloor = 5;

  ({
    Duration heartbeatInterval,
    Duration livenessTimeout,
    Duration connectTimeout,
    int maxReconnectAttempts,
    Duration messageLifetime,
  }) timingFor(NetworkConditions c) =>
      AdaptiveConnectionBudget.fromConditions(c).signalingTiming(
        heartbeatFloor: hbFloor,
        livenessFloor: liveFloor,
        connectTimeoutFloor: dialFloor,
        reconnectAttemptsFloor: attemptsFloor,
      );

  group('signalingTiming', () {
    test('pristine conditions bind every floor exactly — unshaped runs are '
        'bit-for-bit unchanged', () {
      final t = timingFor(NetworkConditions.pristine);
      expect(t.heartbeatInterval, hbFloor);
      expect(t.livenessTimeout, liveFloor);
      expect(t.connectTimeout, dialFloor);
      expect(t.maxReconnectAttempts, attemptsFloor);
    });

    test('loss60 gets a liveness window that covers TCP retransmit delay, '
        'not the historic 8 s', () {
      const loss60 = NetworkConditions(
        rtt: Duration(milliseconds: 4),
        loss: 0.6,
      );
      final t = timingFor(loss60);
      // The retransmit ladder alone is 63 s at the capped doublings; the
      // window that killed the run was 8 s.
      expect(t.livenessTimeout, greaterThan(const Duration(seconds: 60)));
      // The dial bound stays at the FLOOR on every profile: wire-measured
      // (2026-08-07) that dial patience produces clockwork failed
      // handshakes, while dial CADENCE — many cheap fresh connections —
      // is what survives loss. The budget compensates with attempts.
      expect(t.connectTimeout, dialFloor);
      expect(t.maxReconnectAttempts, greaterThanOrEqualTo(40));
    });

    test('extreme (rtt 2 s, 15% loss, 16 kbit/s) derives a heartbeat the '
        'narrow pipe can afford', () {
      const extreme = NetworkConditions(
        rtt: Duration(milliseconds: 2000),
        loss: 0.15,
        bandwidthBps: 16000,
      );
      final t = timingFor(extreme);
      // heartbeatWireBits / (share x bw) = 4000 / (0.05 x 16000) = 5 s: the
      // bandwidth term must dominate the 2 s floor, or the keepalive stream
      // itself crowds the control plane it exists to protect.
      expect(t.heartbeatInterval, const Duration(seconds: 5));
      expect(t.livenessTimeout, greaterThan(t.heartbeatInterval));
    });

    test('property: every derived value >= its floor, liveness > heartbeat, '
        'across the condition grid', () {
      for (final rttMs in [4, 80, 900, 2000]) {
        for (final loss in [0.0, 0.1, 0.35, 0.6, 0.9]) {
          for (final bw in [null, 16000, 32000, 1000000]) {
            final t = timingFor(NetworkConditions(
              rtt: Duration(milliseconds: rttMs),
              loss: loss,
              bandwidthBps: bw,
            ));
            final why = 'rtt=$rttMs loss=$loss bw=$bw';
            expect(t.heartbeatInterval, greaterThanOrEqualTo(hbFloor),
                reason: why);
            expect(t.livenessTimeout, greaterThanOrEqualTo(liveFloor),
                reason: why);
            expect(t.connectTimeout, greaterThanOrEqualTo(dialFloor),
                reason: why);
            expect(t.maxReconnectAttempts,
                greaterThanOrEqualTo(attemptsFloor),
                reason: why);
            // The downstream SignalingClientConfig requires this ordering.
            expect(t.livenessTimeout, greaterThan(t.heartbeatInterval),
                reason: why);
            // The socket layer never gives up before the call-level budget:
            // attempts x dial spans maxElapsed.
            final budget = AdaptiveConnectionBudget.fromConditions(
              NetworkConditions(
                rtt: Duration(milliseconds: rttMs),
                loss: loss,
                bandwidthBps: bw,
              ),
            );
            expect(
              t.maxReconnectAttempts * t.connectTimeout.inMilliseconds,
              greaterThanOrEqualTo(budget.maxElapsed.inMilliseconds),
              reason: why,
            );
            // The outbox never gives up before the reconnect budget does
            // (loss60 2026-08-07: a 2 min fixed lifetime expired an
            // in-flight send and the expiry itself triggered recovery).
            expect(
              t.messageLifetime.inMilliseconds,
              greaterThanOrEqualTo(budget.maxElapsed.inMilliseconds),
              reason: why,
            );
            expect(
              t.messageLifetime,
              greaterThanOrEqualTo(const Duration(minutes: 2)),
              reason: why,
            );
          }
        }
      }
    });

    test('property: liveness is monotone in loss (a worse link never gets '
        'less patience)', () {
      Duration last = Duration.zero;
      for (final loss in [0.0, 0.15, 0.3, 0.45, 0.6, 0.75]) {
        final t = timingFor(NetworkConditions(
          rtt: const Duration(milliseconds: 200),
          loss: loss,
        ));
        expect(t.livenessTimeout, greaterThanOrEqualTo(last),
            reason: 'loss=$loss');
        last = t.livenessTimeout;
      }
    });
  });
}
