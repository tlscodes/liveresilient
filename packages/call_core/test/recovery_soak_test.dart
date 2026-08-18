/// Impaired-network soak: drives one CallController through hundreds of
/// failure/recovery cycles (transport drops, media disconnects, media
/// failures — the in-process fakes' analog of packet loss, jitter spikes,
/// and intermittent path drops) under fake time, asserting no deadlock
/// (every cycle reaches `connected` again), no leak (bounded state
/// emissions, zero pending timers), and clean recovery (attempt counters
/// reset every cycle).
library;

import 'package:call_core/call_core.dart';
import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  test('soak: 200 impaired-network cycles recover cleanly with no deadlock, '
      'no leak, and reset counters', () {
    fakeAsync((async) {
      final baseTime = DateTime.utc(2026, 1, 1);
      T run<T>(T Function() body) =>
          withClock(Clock(() => baseTime.add(async.elapsed)), body);

      final log = CallLog();
      final transport = FakeTransport(log: log);
      final signaling = FakeSignaling(log: log);
      final media = FakeMedia(log: log);
      final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
        ReconnectDecision.retry(const Duration(milliseconds: 50)),
      ]);
      final controller = CallController(
        callId: 'soak-call',
        role: CallRole.initiator,
        transport: transport,
        signaling: signaling,
        media: media,
        reconnectPolicy: policy,
      );
      final states = <CallState>[];
      controller.states.listen(states.add);

      // Bring the call up once.
      run(controller.start);
      async.flushMicrotasks();
      signaling.emit(RemoteDescriptionEvent(fakeAnswer()));
      async.flushMicrotasks();
      media.emit(
        const MediaConnectionChangedEvent(MediaConnectionState.connected),
      );
      async.flushMicrotasks();
      expect(states.last.phase, CallPhase.connected);

      const cycles = 200;
      for (var cycle = 0; cycle < cycles; cycle++) {
        // Rotate through the three in-process impairment modes.
        switch (cycle % 3) {
          case 0:
            transport.emit(const TransportEvent(TransportStatus.disconnected));
          case 1:
            media.emit(
              const MediaConnectionChangedEvent(
                MediaConnectionState.disconnected,
              ),
            );
            // Squall grace (raised 2026-08-08): let the disconnected
            // grace window lapse so this cycle enters recovery.
            async.elapse(const Duration(milliseconds: 5001));
          default:
            media.emit(
              const MediaConnectionChangedEvent(MediaConnectionState.failed),
            );
        }
        async.flushMicrotasks();
        expect(
          states.last.phase,
          CallPhase.reconnecting,
          reason: 'cycle $cycle must enter recovery',
        );
        expect(
          states.last.reconnectAttempt,
          1,
          reason:
              'cycle $cycle: counters must have reset after the previous '
              'recovery — attempts never accumulate across cycles',
        );

        // Jitter the wait past the backoff delay (recovery fires at 50ms).
        async.elapse(Duration(milliseconds: 50 + (cycle % 7)));
        signaling.emit(RemoteDescriptionEvent(fakeAnswer()));
        async.flushMicrotasks();
        media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();
        expect(
          states.last.phase,
          CallPhase.connected,
          reason:
              'cycle $cycle must recover to connected — a stall here is '
              'a deadlock',
        );
      }

      // Clean recovery: the policy saw attempt=1 on every single cycle.
      expect(policy.contexts, hasLength(cycles));
      expect(policy.contexts.every((c) => c.attempt == 1), isTrue);

      // No leak: emissions stay bounded (a few per cycle, not quadratic)
      // and monotonic, and no timer survives the soak.
      expect(states.length, lessThan(cycles * 5 + 10));
      for (var i = 1; i < states.length; i++) {
        expect(states[i].sequence, greaterThan(states[i - 1].sequence));
      }
      expect(async.periodicTimerCount, 0, reason: 'periodic timers leaked');
      expect(
        async.nonPeriodicTimerCount,
        0,
        reason: 'non-periodic timers leaked',
      );

      // The call is still healthy and can end normally.
      run(controller.hangUp);
      async.flushMicrotasks();
    });
  });
}
