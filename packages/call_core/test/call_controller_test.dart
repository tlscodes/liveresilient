import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

/// Pumps the real (non-fake) event queue a number of times.
///
/// Needed because `StreamSubscription.cancel()` -- used internally by the
/// controller's teardown path (`_cancelSubscriptions`) -- resolves through
/// the actual Dart event loop rather than through `fake_async`'s controlled
/// microtask queue. This was verified with a minimal repro completely
/// outside `CallController`: a bare `StreamController.broadcast()` +
/// `.listen()` + `await subscription.cancel()` inside `fakeAsync` never
/// completes via `flushMicrotasks()`/`elapse()`, regardless of `sync:true`,
/// regardless of `withClock` nesting, and regardless of whether cancel is
/// called from the subscription's own listener or an unrelated task -- so
/// it's a genuine dart:async/fake_async interaction, not a bug in the
/// controller or in these tests. The fix: drop out of the synchronous
/// `fakeAsync` callback, let a few real microtask turns pass (which lets
/// `cancel()` settle for real), then resume draining the same `FakeAsync`
/// instance's queue -- its zone-bound continuations correctly resume once
/// the real gap closes, since Dart `async` function bodies always resume in
/// their originating zone regardless of which zone completed the awaited
/// future.
Future<void> pumpEventQueue([int times = 20]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Wires a [CallController] to fresh fakes and a fake clock.
///
/// MUST be constructed from *inside* the surrounding `fakeAsync(...)`
/// callback (never before it, never after it returns). `CallController`'s
/// internal task queue (`_serialTail`) is seeded with an already-completed
/// `Future<void>.value()`; empirically, chaining `.then()` onto that future
/// only routes through `fake_async`'s controlled microtask queue if the
/// future itself was created while the fake zone was already active --
/// otherwise the very first `_enqueue`d task (i.e. `start()`) never
/// resolves via `flushMicrotasks()`/`elapse()` at all. (Same family of
/// zone-bypass quirk as the `StreamSubscription.cancel()` issue [run]'s
/// caller has to work around with [pumpEventQueue] -- both are
/// already-completed/no-op futures whose continuation dispatch doesn't
/// follow the normal "zone active at `.then()` call time" rule under
/// `fake_async`.)
///
/// Every entry point into the controller must additionally run through
/// [run] so `clock.now()` calls made from inside the controller resolve
/// against `async.elapsed` instead of the real wall clock -- required for
/// deterministic recovery/retryAt math. Reactions driven purely by
/// fake-stream events do not need [run]: controller subscriptions are
/// installed inside the first [run] call, and Dart stream listeners run in
/// the zone captured at `.listen()` time, so they inherit the fake-clock
/// zone automatically.
final class Harness {
  Harness({
    this.role = CallRole.initiator,
    ReconnectPolicy? reconnectPolicy,
    this.connectionTimeout = const Duration(seconds: 20),
    this.operationTimeout = const Duration(seconds: 15),
    this.maxBufferedIceCandidates = 256,
    String callId = 'call-1',
  }) : log = CallLog(),
       baseTime = DateTime.utc(2026, 1, 1),
       reconnectPolicy =
           reconnectPolicy ??
           ScriptedReconnectPolicy(<ReconnectDecision>[
             ReconnectDecision.giveUp('no retries configured'),
           ]) {
    transport = FakeTransport(log: log);
    signaling = FakeSignaling(log: log);
    media = FakeMedia(log: log);
    controller = CallController(
      callId: callId,
      role: role,
      transport: transport,
      signaling: signaling,
      media: media,
      reconnectPolicy: this.reconnectPolicy,
      connectionTimeout: connectionTimeout,
      operationTimeout: operationTimeout,
      maxBufferedIceCandidates: maxBufferedIceCandidates,
    );
    states = <CallState>[];
    controller.states.listen(states.add, onDone: () => statesClosed = true);
  }

  final CallRole role;
  final ReconnectPolicy reconnectPolicy;
  final Duration connectionTimeout;
  final Duration operationTimeout;
  final int maxBufferedIceCandidates;
  final CallLog log;
  final DateTime baseTime;

  late final FakeTransport transport;
  late final FakeSignaling signaling;
  late final FakeMedia media;
  late final CallController controller;
  late final List<CallState> states;
  bool statesClosed = false;

  /// Runs [body] inside a zone whose `clock.now()` tracks [async]'s fake
  /// elapsed time, then returns [body]'s result (typically a pending
  /// `Future` -- callers still need `async.flushMicrotasks()`/`elapse()`).
  T run<T>(FakeAsync async, T Function() body) {
    return withClock(Clock(() => baseTime.add(async.elapsed)), body);
  }
}

/// Attaches to [future] without awaiting (illegal inside a sync `fakeAsync`
/// body) and records its outcome for later synchronous inspection once the
/// caller has drained microtasks/timers.
final class Outcome<T> {
  Object? error;
  T? value;
  bool completed = false;

  void attach(Future<T> future) {
    unawaited(
      future.then(
        (v) {
          value = v;
          completed = true;
        },
        onError: (Object e) {
          error = e;
          completed = true;
        },
      ),
    );
  }
}

void expectStrictlyIncreasingSequence(List<CallState> states) {
  for (var i = 1; i < states.length; i++) {
    expect(
      states[i].sequence,
      greaterThan(states[i - 1].sequence),
      reason: 'sequence must strictly increase across all emissions',
    );
  }
}

void expectNoPendingTimers(FakeAsync async) {
  expect(async.periodicTimerCount, 0, reason: 'periodic timers leaked');
  expect(async.nonPeriodicTimerCount, 0, reason: 'non-periodic timers leaked');
}

void main() {
  group('1. Initiator happy path', () {
    test(
      'connecting -> negotiating -> connected, with correct call/send order',
      () {
        fakeAsync((async) {
          final h = Harness();
          h.run(async, h.controller.start);
          async.flushMicrotasks();

          expect(h.states.map((s) => s.phase).toList(), [
            CallPhase.connecting,
            CallPhase.negotiating,
          ]);

          expect(h.log.entries, [
            'media.start',
            'transport.connect',
            'signaling.start',
            'media.createOffer(iceRestart:false)',
            'media.setLocalDescription(offer)',
            'signaling.send(description:offer)',
          ]);
          expect(h.media.signalingState, MediaSignalingState.haveLocalOffer);

          // Remote answers.
          h.signaling.emit(RemoteDescriptionEvent(fakeAnswer()));
          async.flushMicrotasks();
          expect(h.log.entries.last, 'media.setRemoteDescription(answer)');
          expect(h.media.signalingState, MediaSignalingState.stable);
          expect(h.states.last.phase, CallPhase.negotiating);

          // Media reports connected.
          h.media.emit(
            const MediaConnectionChangedEvent(MediaConnectionState.connected),
          );
          async.flushMicrotasks();

          expect(h.states.last.phase, CallPhase.connected);
          expectStrictlyIncreasingSequence(h.states);
          expectNoPendingTimers(async);
        });
      },
    );
  });

  group('2. Receiver perfect negotiation', () {
    test('plain remote offer -> answer sent, no rollback', () {
      fakeAsync((async) {
        final h = Harness(role: CallRole.receiver);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        expect(h.states.last.phase, CallPhase.negotiating);

        h.signaling.emit(RemoteDescriptionEvent(fakeOffer()));
        async.flushMicrotasks();

        expect(h.media.rollbackCalls, 0);
        expect(h.log.entries, [
          'media.start',
          'transport.connect',
          'signaling.start',
          'media.setRemoteDescription(offer)',
          'media.createAnswer',
          'media.setLocalDescription(answer)',
          'signaling.send(description:answer)',
        ]);
        expect(h.media.signalingState, MediaSignalingState.stable);
        expectNoPendingTimers(async);
      });
    });

    test('glare while receiver (polite): rollback then answer', () {
      fakeAsync((async) {
        final h = Harness(role: CallRole.receiver);
        h.run(async, h.controller.start);
        async.flushMicrotasks();

        // Simulate a local offer already in flight (glare) by forcing the
        // fake media adapter's signaling state directly.
        h.media.signalingState = MediaSignalingState.haveLocalOffer;

        h.signaling.emit(RemoteDescriptionEvent(fakeOffer()));
        async.flushMicrotasks();

        expect(h.media.rollbackCalls, 1);
        final rollbackIndex = h.log.entries.indexOf('media.rollback');
        final answerIndex = h.log.entries.indexOf(
          'signaling.send(description:answer)',
        );
        expect(rollbackIndex, greaterThanOrEqualTo(0));
        expect(answerIndex, greaterThan(rollbackIndex));
        expectNoPendingTimers(async);
      });
    });

    test('a colliding offer received while the initial offer is still in '
        'flight is ignored once resolved (impolite/initiator)', () {
      // NOTE ON THE ACTOR MODEL: CallController serializes ALL work
      // through a single `_enqueue` chain -- a queued task (like the
      // remote-offer event below) never starts running until the
      // currently in-flight task (start()'s own negotiate, here) fully
      // completes. So this can't literally catch `_makingOffer` mid-flip
      // (that's structurally unreachable under strict serialization: no
      // two enqueued tasks are ever mid-execution at once). What it DOES
      // verify is the real, reachable outcome: once our own offer
      // negotiation finishes (leaving media in `haveLocalOffer`, not
      // `stable`), a remote offer that arrives afterwards is still a
      // collision by the OTHER criterion in `_handleRemoteDescription`
      // (signalingState != stable), and for an impolite (initiator) role
      // that collision is ignored outright -- no rollback, no answer
      // sent, and any ICE candidate riding along with the ignored offer
      // is dropped too.
      fakeAsync((async) {
        final h = Harness();
        final offerCompleter = Completer<SessionDescription>();
        h.media.createOfferImpl = ({required iceRestart}) =>
            offerCompleter.future;

        h.run(async, h.controller.start);
        async.flushMicrotasks();
        expect(h.log.entries, [
          'media.start',
          'transport.connect',
          'signaling.start',
          'media.createOffer(iceRestart:false)',
        ]);

        h.signaling.emit(RemoteDescriptionEvent(fakeOffer()));
        h.signaling.emit(RemoteIceCandidateEvent(fakeCandidate(1)));
        offerCompleter.complete(fakeOffer());
        async.flushMicrotasks();

        expect(h.media.rollbackCalls, 0);
        expect(h.log.entries.any((e) => e.contains('createAnswer')), false);
        expect(
          h.log.entries.any((e) => e.contains('setRemoteDescription')),
          false,
        );
        expect(h.media.remoteCandidates, isEmpty);
        expect(h.log.entries.last, 'signaling.send(description:offer)');
        expect(h.media.signalingState, MediaSignalingState.haveLocalOffer);
        expectNoPendingTimers(async);
      });
    });
  });

  group('3. Buffered local ICE candidates', () {
    // Emitting a LocalIceCandidateEvent while `start()` itself is still
    // in flight does NOT reach `_bufferLocalCandidate`: the controller
    // serializes everything through one `_enqueue` chain, so an event
    // enqueued while start() is running is simply queued behind it and
    // only runs once start() fully finishes -- by which point signaling
    // has already started for real. The only reachable window where
    // `_signalingStarted` is false AND the actor queue is free (so a
    // freshly-emitted event actually runs its buffering branch right
    // away) is after the INITIAL connect attempt has failed and the
    // controller is sitting in `reconnecting` waiting on the retry timer.
    // These tests drive that path deliberately.
    test('buffered while the initial connect is failing, flushed in order '
        'once the retry succeeds', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(milliseconds: 100)),
        ]);
        final h = Harness(maxBufferedIceCandidates: 3, reconnectPolicy: policy);
        var signalingStartAttempts = 0;
        h.signaling.startImpl = ({required callId, required role}) async {
          signalingStartAttempts++;
          if (signalingStartAttempts == 1) {
            throw StateError('signaling unavailable');
          }
        };

        h.run(async, h.controller.start);
        async.flushMicrotasks();
        expect(h.states.last.phase, CallPhase.reconnecting);

        h.media.emit(LocalIceCandidateEvent(fakeCandidate(1)));
        h.media.emit(LocalIceCandidateEvent(fakeCandidate(2)));
        h.media.emit(LocalIceCandidateEvent(fakeCandidate(3)));
        async.flushMicrotasks();
        expect(h.signaling.sent, isEmpty);

        async.elapse(const Duration(milliseconds: 100));

        final iceSent = h.signaling.sent
            .whereType<SendIceCandidateCommand>()
            .map((c) => c.candidate.candidate)
            .toList();
        expect(iceSent, [
          'candidate:1 1 UDP 2122260223 10.0.0.1 51 typ host',
          'candidate:2 1 UDP 2122260223 10.0.0.2 52 typ host',
          'candidate:3 1 UDP 2122260223 10.0.0.3 53 typ host',
        ]);
      });
    });

    test('overflow beyond maxBufferedIceCandidates drops oldest first', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(milliseconds: 100)),
        ]);
        final h = Harness(maxBufferedIceCandidates: 3, reconnectPolicy: policy);
        var signalingStartAttempts = 0;
        h.signaling.startImpl = ({required callId, required role}) async {
          signalingStartAttempts++;
          if (signalingStartAttempts == 1) {
            throw StateError('signaling unavailable');
          }
        };

        h.run(async, h.controller.start);
        async.flushMicrotasks();
        expect(h.states.last.phase, CallPhase.reconnecting);

        for (var i = 1; i <= 5; i++) {
          h.media.emit(LocalIceCandidateEvent(fakeCandidate(i)));
        }
        async.flushMicrotasks();

        async.elapse(const Duration(milliseconds: 100));

        final iceSent = h.signaling.sent
            .whereType<SendIceCandidateCommand>()
            .map((c) => c.candidate.candidate)
            .toList();
        // Candidates 1 and 2 were evicted; only the newest 3 survive, in
        // arrival order.
        expect(iceSent, [
          'candidate:3 1 UDP 2122260223 10.0.0.3 53 typ host',
          'candidate:4 1 UDP 2122260223 10.0.0.4 54 typ host',
          'candidate:5 1 UDP 2122260223 10.0.0.5 55 typ host',
        ]);
      });
    });
  });

  group('4. Recovery happy path', () {
    test('scripted single-retry reconnect, then counters reset', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(milliseconds: 100)),
        ]);
        final h = Harness(reconnectPolicy: policy);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        // Bring signaling to `stable` the same way a real peer would, so
        // the ICE-restart negotiate below doesn't also trigger a rollback.
        h.signaling.emit(RemoteDescriptionEvent(fakeAnswer()));
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();
        expect(h.states.last.phase, CallPhase.connected);

        h.log.entries.clear();
        h.transport.emit(const TransportEvent(TransportStatus.disconnected));
        async.flushMicrotasks();

        final reconnecting = h.states.last;
        expect(reconnecting.phase, CallPhase.reconnecting);
        expect(reconnecting.reconnectAttempt, 1);
        expect(
          reconnecting.nextRetryAt,
          h.baseTime.add(const Duration(milliseconds: 100)),
        );

        async.elapse(const Duration(milliseconds: 100));

        // `_ensureMediaStarted` is a no-op here: media was already started
        // during the initial `start()` and recovery never restarts it.
        expect(h.log.entries, [
          'signaling.stop',
          'transport.disconnect',
          'transport.connect',
          'signaling.start',
          'media.createOffer(iceRestart:true)',
          'media.setLocalDescription(offer)',
          'signaling.send(description:offer)',
        ]);
        expect(h.media.startCalls, 1);
        expect(h.transport.disconnectCalls, 1);
        expect(h.signaling.stopCalls, 1);
        expect(h.states.last.phase, CallPhase.reconnecting);

        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.connected);
        expectNoPendingTimers(async);

        // Fail again: recovery must start over at attempt 1, not 2.
        h.transport.emit(const TransportEvent(TransportStatus.disconnected));
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.reconnecting);
        expect(h.states.last.reconnectAttempt, 1);
        expect(policy.contexts.last.attempt, 1);
        expectStrictlyIncreasingSequence(h.states);
      });
    });
  });

  group('5. Connection-timeout path', () {
    test(
      'reconnect succeeds but media stays down -> next attempt at connectionTimeout',
      () {
        fakeAsync((async) {
          final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
            ReconnectDecision.retry(const Duration(milliseconds: 100)),
          ]);
          final h = Harness(
            reconnectPolicy: policy,
            connectionTimeout: const Duration(milliseconds: 200),
          );
          h.run(async, h.controller.start);
          async.flushMicrotasks();
          h.signaling.emit(RemoteDescriptionEvent(fakeAnswer()));
          async.flushMicrotasks();
          h.media.emit(
            const MediaConnectionChangedEvent(MediaConnectionState.connected),
          );
          async.flushMicrotasks();

          h.transport.emit(const TransportEvent(TransportStatus.disconnected));
          async.flushMicrotasks();
          expect(h.states.last.reconnectAttempt, 1);

          async.elapse(const Duration(milliseconds: 100));
          // Negotiate ran, but media never reported connected -- the
          // controller must be waiting, not yet scheduling attempt 2.
          expect(h.states.last.phase, CallPhase.reconnecting);
          expect(h.states.last.reconnectAttempt, 1);
          expect(async.nonPeriodicTimerCount, 1);

          async.elapse(const Duration(milliseconds: 200));

          final scheduled = h.states.last;
          expect(scheduled.phase, CallPhase.reconnecting);
          expect(scheduled.reconnectAttempt, 2);
          expect(policy.contexts.last.attempt, 2);
        });
      },
    );
  });

  group('6. Recovery exhaustion', () {
    test(
      'policy gives up -> failed(reconnectExhausted), done resolves',
      () async {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.giveUp('budget exhausted'),
        ]);
        late final Harness h;
        final outcome = Outcome<CallState>();

        late FakeAsync fa;
        fakeAsync((async) {
          fa = async;
          h = Harness(reconnectPolicy: policy);
          outcome.attach(h.controller.done);
          h.run(async, h.controller.start);
          async.flushMicrotasks();

          h.transport.emit(const TransportEvent(TransportStatus.disconnected));
          async.flushMicrotasks();
        });
        await pumpEventQueue();
        fa.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.failed);
        expect(h.states.last.endReason, CallEndReason.reconnectExhausted);
        expect(outcome.completed, true);
        expect(outcome.value?.phase, CallPhase.failed);
        expect(outcome.value?.endReason, CallEndReason.reconnectExhausted);
        expectNoPendingTimers(fa);
      },
    );

    test('a throwing policy also fails as reconnectExhausted', () async {
      late final Harness h;

      late FakeAsync fa;
      fakeAsync((async) {
        fa = async;
        h = Harness(reconnectPolicy: ThrowingReconnectPolicy());
        h.run(async, h.controller.start);
        async.flushMicrotasks();

        h.transport.emit(const TransportEvent(TransportStatus.disconnected));
        async.flushMicrotasks();
      });
      await pumpEventQueue();
      fa.flushMicrotasks();

      expect(h.states.last.phase, CallPhase.failed);
      expect(h.states.last.endReason, CallEndReason.reconnectExhausted);
      expectNoPendingTimers(fa);
    });
  });

  group('7. Protocol error', () {
    test('createAnswer returning an offer -> failed(protocolError)', () async {
      late final Harness h;

      late FakeAsync fa;
      fakeAsync((async) {
        fa = async;
        h = Harness(role: CallRole.receiver);
        h.media.createAnswerImpl = () async => fakeOffer();
        h.run(async, h.controller.start);
        async.flushMicrotasks();

        h.signaling.emit(RemoteDescriptionEvent(fakeOffer()));
        async.flushMicrotasks();
      });
      await pumpEventQueue();
      fa.flushMicrotasks();

      expect(h.states.last.phase, CallPhase.failed);
      expect(h.states.last.endReason, CallEndReason.protocolError);
      expectNoPendingTimers(fa);
    });

    test('createOffer returning an answer during a signaling-driven '
        'renegotiate -> failed(protocolError)', () async {
      // NOTE: a bad createOffer during the *initial* start() negotiate
      // is caught by start()'s generic `catch` and routed through
      // _beginRecovery, not _fail -- only negotiates triggered from
      // _handleSignalingEvent (e.g. RestartRequestedEvent) run under the
      // `on CallProtocolException -> _fail(protocolError)` handler. So
      // this drives the bad createOffer via a restart request instead.
      late final Harness h;

      late FakeAsync fa;
      fakeAsync((async) {
        fa = async;
        h = Harness(role: CallRole.receiver);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.signaling.emit(RemoteDescriptionEvent(fakeOffer()));
        async.flushMicrotasks();
        expect(h.states.last.phase, CallPhase.negotiating);

        h.media.createOfferImpl = ({required iceRestart}) async => fakeAnswer();
        h.signaling.emit(const RestartRequestedEvent());
        async.flushMicrotasks();
      });
      await pumpEventQueue();
      fa.flushMicrotasks();

      expect(h.states.last.phase, CallPhase.failed);
      expect(h.states.last.endReason, CallEndReason.protocolError);
      expectNoPendingTimers(fa);
    });
  });

  group('8. hangUp', () {
    test('sends hangup, tears down once each, ends localHangup', () async {
      late final Harness h;

      late FakeAsync fa;
      fakeAsync((async) {
        fa = async;
        h = Harness();
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();

        h.run(async, h.controller.hangUp);
        async.flushMicrotasks();
      });
      await pumpEventQueue();
      fa.flushMicrotasks();

      final hangups = h.signaling.sent.whereType<SendHangupCommand>();
      expect(hangups, hasLength(1));
      expect(hangups.first.reason, 'hangup');

      expect(h.states.last.phase, CallPhase.ended);
      expect(h.states.last.endReason, CallEndReason.localHangup);
      expect(h.signaling.stopCalls, 1);
      expect(h.transport.disconnectCalls, 1);
      expect(h.media.stopCalls, 1);
      expectNoPendingTimers(fa);
    });

    test('hangUp after terminal is a no-op, not an error', () async {
      late final Harness h;

      late FakeAsync fa;
      fakeAsync((async) {
        fa = async;
        h = Harness();
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.run(async, h.controller.hangUp);
        async.flushMicrotasks();
      });
      await pumpEventQueue();
      fa.flushMicrotasks();

      expect(h.states.last.phase, CallPhase.ended);
      final afterFirst = h.states.length;

      // Terminal already reached. The controller's `_serialTail` task
      // chain was built up entirely inside `fa`'s fake zone, so a plain
      // real `await controller.hangUp()` out here hangs (its continuation
      // is still dispatched through `fa`'s queue, which nothing drains
      // anymore) -- re-enter fake-time control on the SAME FakeAsync
      // instance via its public `run()` instead.
      final outcome = Outcome<void>();
      fa.run((async) {
        outcome.attach(h.run(async, h.controller.hangUp));
        async.flushMicrotasks();
      });
      await pumpEventQueue();
      fa.flushMicrotasks();

      expect(outcome.completed, true);
      expect(outcome.error, isNull);
      expect(h.states.length, afterFirst);
    });

    test('teardown swallows a failing collaborator (best-effort)', () async {
      late final Harness h;

      late FakeAsync fa;
      fakeAsync((async) {
        fa = async;
        h = Harness();
        h.signaling.sendImpl = (command) async {
          if (command is SendHangupCommand) {
            throw StateError('network blip');
          }
        };
        h.transport.disconnectImpl = () async =>
            throw StateError('already gone');

        h.run(async, h.controller.start);
        async.flushMicrotasks();

        h.run(async, h.controller.hangUp);
        async.flushMicrotasks();
      });
      await pumpEventQueue();
      fa.flushMicrotasks();

      expect(h.states.last.phase, CallPhase.ended);
      expect(h.states.last.endReason, CallEndReason.localHangup);
      expect(h.media.stopCalls, 1);
      expectNoPendingTimers(fa);
    });
  });

  group('9. Hangup/dispose/lifecycle edge cases', () {
    test('RemoteHangupEvent -> ended(remoteHangup)', () async {
      late final Harness h;

      late FakeAsync fa;
      fakeAsync((async) {
        fa = async;
        h = Harness();
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();

        h.signaling.emit(RemoteHangupEvent('bye'));
        async.flushMicrotasks();
      });
      await pumpEventQueue();
      fa.flushMicrotasks();

      expect(h.states.last.phase, CallPhase.ended);
      expect(h.states.last.endReason, CallEndReason.remoteHangup);
      expectNoPendingTimers(fa);
    });

    test(
      'dispose() mid-call -> ended(disposed), stream closes, no timers',
      () async {
        late final Harness h;

        late FakeAsync fa;
        fakeAsync((async) {
          fa = async;
          h = Harness();
          h.run(async, h.controller.start);
          async.flushMicrotasks();
          expect(h.states.last.phase, CallPhase.negotiating);

          h.run(async, h.controller.dispose);
          async.flushMicrotasks();
        });
        await pumpEventQueue();
        fa.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.ended);
        expect(h.states.last.endReason, CallEndReason.disposed);
        expect(h.statesClosed, true);
        expectNoPendingTimers(fa);
      },
    );

    test(
      'dispose() after terminal only cancels subscriptions, is idempotent',
      () async {
        late final Harness h;

        late FakeAsync fa;
        fakeAsync((async) {
          fa = async;
          h = Harness();
          h.run(async, h.controller.start);
          async.flushMicrotasks();
          h.run(async, h.controller.hangUp);
          async.flushMicrotasks();
        });
        await pumpEventQueue();
        fa.flushMicrotasks();
        expect(h.states.last.phase, CallPhase.ended);

        // First dispose after terminal: hangUp's teardown already cleared
        // _subscriptions, so _cancelSubscriptions hits its empty fast
        // return. Still re-enter fake-time control via `fa.run()` rather
        // than a plain real await -- the existing `_serialTail` chain's
        // continuation dispatch stays tied to `fa`'s zone either way.
        final firstDispose = Outcome<void>();
        fa.run((async) {
          firstDispose.attach(h.run(async, h.controller.dispose));
          async.flushMicrotasks();
        });
        await pumpEventQueue();
        fa.flushMicrotasks();
        expect(firstDispose.completed, true);
        expect(firstDispose.error, isNull);
        expect(h.statesClosed, true);
        final afterFirstDispose = h.states.length;

        // A second dispose must be a pure no-op.
        final secondDispose = Outcome<void>();
        fa.run((async) {
          secondDispose.attach(h.run(async, h.controller.dispose));
          async.flushMicrotasks();
        });
        await pumpEventQueue();
        fa.flushMicrotasks();
        expect(secondDispose.completed, true);
        expect(secondDispose.error, isNull);
        expect(h.states.length, afterFirstDispose);
      },
    );

    test('start() called twice throws StateError on the second call', () {
      fakeAsync((async) {
        final h = Harness();
        h.run(async, h.controller.start);
        async.flushMicrotasks();

        final outcome = Outcome<void>();
        outcome.attach(h.run(async, h.controller.start));
        async.flushMicrotasks();

        expect(outcome.completed, true);
        expect(outcome.error, isA<StateError>());
      });
    });

    test('hangUp after dispose throws StateError (disposed guard)', () async {
      late final Harness h;

      late FakeAsync fa;
      fakeAsync((async) {
        fa = async;
        h = Harness();
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.run(async, h.controller.dispose);
        async.flushMicrotasks();
      });
      await pumpEventQueue();
      fa.flushMicrotasks();
      expect(h.states.last.phase, CallPhase.ended);
      expect(h.states.last.endReason, CallEndReason.disposed);

      final outcome = Outcome<void>();
      fa.run((async) {
        outcome.attach(h.run(async, h.controller.hangUp));
        async.flushMicrotasks();
      });
      await pumpEventQueue();
      fa.flushMicrotasks();

      expect(outcome.completed, true);
      expect(outcome.error, isA<StateError>());
    });

    test(
      'sequence numbers strictly increase across a full lifecycle',
      () async {
        late final Harness h;

        late FakeAsync fa;
        fakeAsync((async) {
          fa = async;
          h = Harness(role: CallRole.receiver);
          h.run(async, h.controller.start);
          async.flushMicrotasks();
          h.signaling.emit(RemoteDescriptionEvent(fakeOffer()));
          async.flushMicrotasks();
          h.media.emit(
            const MediaConnectionChangedEvent(MediaConnectionState.connected),
          );
          async.flushMicrotasks();
          h.run(async, h.controller.hangUp);
          async.flushMicrotasks();
        });
        await pumpEventQueue();
        fa.flushMicrotasks();

        expect(h.states, isNotEmpty);
        expect(h.states.last.phase, CallPhase.ended);
        expectStrictlyIncreasingSequence(h.states);
      },
    );
  });

  group('Coverage: stream lifecycle and misc branches', () {
    test('transport stream closing (onDone) triggers recovery', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(milliseconds: 50)),
        ]);
        final h = Harness(reconnectPolicy: policy);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();

        unawaited(h.transport.close());
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.reconnecting);
      });
    });

    test('signaling stream error (onError) triggers recovery', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(milliseconds: 50)),
        ]);
        final h = Harness(reconnectPolicy: policy);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();

        h.signaling.emitError(StateError('signaling socket died'));
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.reconnecting);
      });
    });

    test('media stream error (onError) triggers recovery directly', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(milliseconds: 50)),
        ]);
        final h = Harness(reconnectPolicy: policy);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();

        h.media.emitError(StateError('media pipeline crashed'));
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.reconnecting);
      });
    });

    test('media connectionState closed triggers recovery', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(milliseconds: 50)),
        ]);
        final h = Harness(reconnectPolicy: policy);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();

        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.closed),
        );
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.reconnecting);
      });
    });

    test('media failure event triggers recovery', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(milliseconds: 50)),
        ]);
        final h = Harness(reconnectPolicy: policy);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();

        h.media.emit(MediaFailureEvent(StateError('codec exploded')));
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.reconnecting);
      });
    });

    test('RestartRequestedEvent triggers an ICE-restart negotiate', () {
      fakeAsync((async) {
        final h = Harness(role: CallRole.receiver);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.signaling.emit(RemoteDescriptionEvent(fakeOffer()));
        async.flushMicrotasks();
        h.log.entries.clear();

        h.signaling.emit(const RestartRequestedEvent());
        async.flushMicrotasks();

        expect(h.log.entries, [
          'media.createOffer(iceRestart:true)',
          'media.setLocalDescription(offer)',
          'signaling.send(description:offer)',
        ]);
      });
    });

    test(
      'a local ICE send failure buffers the candidate and starts recovery',
      () {
        fakeAsync((async) {
          final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
            ReconnectDecision.retry(const Duration(milliseconds: 50)),
          ]);
          final h = Harness(reconnectPolicy: policy);
          h.run(async, h.controller.start);
          async.flushMicrotasks();

          h.signaling.sendImpl = (command) async {
            if (command is SendIceCandidateCommand) {
              throw StateError('send failed');
            }
          };
          h.media.emit(LocalIceCandidateEvent(fakeCandidate(9)));
          async.flushMicrotasks();

          expect(h.states.last.phase, CallPhase.reconnecting);
        });
      },
    );

    test('operation timeout surfaces as a recovery cause', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(milliseconds: 50)),
        ]);
        final h = Harness(
          reconnectPolicy: policy,
          operationTimeout: const Duration(milliseconds: 10),
        );
        h.transport.connectImpl = () => Completer<void>().future;

        h.run(async, h.controller.start);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 10));

        expect(h.states.last.phase, CallPhase.reconnecting);
      });
    });

    test('transport stream error (onError) triggers recovery', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(milliseconds: 50)),
        ]);
        final h = Harness(reconnectPolicy: policy);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();

        h.transport.emitError(StateError('transport socket died'));
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.reconnecting);
      });
    });

    test('signaling stream closing (onDone) triggers recovery', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(milliseconds: 50)),
        ]);
        final h = Harness(reconnectPolicy: policy);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();

        unawaited(h.signaling.close());
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.reconnecting);
      });
    });

    test('media stream closing (onDone) triggers recovery', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(milliseconds: 50)),
        ]);
        final h = Harness(reconnectPolicy: policy);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();

        unawaited(h.media.close());
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.reconnecting);
      });
    });

    test('a non-colliding remote ICE candidate is applied directly', () {
      fakeAsync((async) {
        final h = Harness(role: CallRole.receiver);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.signaling.emit(RemoteDescriptionEvent(fakeOffer()));
        async.flushMicrotasks();

        h.signaling.emit(RemoteIceCandidateEvent(fakeCandidate(1)));
        async.flushMicrotasks();

        expect(h.media.remoteCandidates, hasLength(1));
      });
    });

    test('media connectionState failed triggers recovery', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(milliseconds: 50)),
        ]);
        final h = Harness(reconnectPolicy: policy);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();

        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.failed),
        );
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.reconnecting);
      });
    });

    test('ICE-restart negotiate rolls back first when signaling state is '
        'not stable', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(milliseconds: 100)),
        ]);
        final h = Harness(reconnectPolicy: policy);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        // No remote answer applied -- media stays in `haveLocalOffer`.
        expect(h.media.signalingState, MediaSignalingState.haveLocalOffer);

        h.transport.emit(const TransportEvent(TransportStatus.disconnected));
        async.flushMicrotasks();
        h.log.entries.clear();

        async.elapse(const Duration(milliseconds: 100));

        expect(h.media.rollbackCalls, 1);
        final rollbackIndex = h.log.entries.indexOf('media.rollback');
        final createOfferIndex = h.log.entries.indexOf(
          'media.createOffer(iceRestart:true)',
        );
        expect(rollbackIndex, greaterThanOrEqualTo(0));
        expect(createOfferIndex, greaterThan(rollbackIndex));
      });
    });

    test(
      'receiver-role recovery sends a restart request before renegotiating',
      () {
        fakeAsync((async) {
          final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
            ReconnectDecision.retry(const Duration(milliseconds: 100)),
          ]);
          final h = Harness(role: CallRole.receiver, reconnectPolicy: policy);
          h.run(async, h.controller.start);
          async.flushMicrotasks();
          h.signaling.emit(RemoteDescriptionEvent(fakeOffer()));
          async.flushMicrotasks();
          h.media.emit(
            const MediaConnectionChangedEvent(MediaConnectionState.connected),
          );
          async.flushMicrotasks();

          h.log.entries.clear();
          h.transport.emit(const TransportEvent(TransportStatus.disconnected));
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 100));

          expect(
            h.log.entries,
            containsAllInOrder([
              'signaling.send(restart)',
              'media.createOffer(iceRestart:true)',
            ]),
          );
        });
      },
    );

    test('a failing reconnect attempt reschedules another attempt', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(milliseconds: 100)),
          ReconnectDecision.retry(const Duration(milliseconds: 100)),
        ]);
        final h = Harness(reconnectPolicy: policy);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.signaling.emit(RemoteDescriptionEvent(fakeAnswer()));
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();

        // Installed AFTER the initial start() already connected once with
        // the default (always-succeeds) behavior, so this only governs the
        // recovery retry's transport.connect() call -- throw exactly once.
        var thrown = false;
        h.transport.connectImpl = () async {
          if (!thrown) {
            thrown = true;
            throw StateError('reconnect network failure');
          }
        };

        h.transport.emit(const TransportEvent(TransportStatus.disconnected));
        async.flushMicrotasks();
        expect(h.states.last.reconnectAttempt, 1);

        async.elapse(const Duration(milliseconds: 100));
        // The retry's transport.connect() threw -- expect a second attempt
        // to have been scheduled instead of the controller getting stuck.
        expect(h.states.last.phase, CallPhase.reconnecting);
        expect(h.states.last.reconnectAttempt, 2);
        expect(policy.contexts.last.attempt, 2);
      });
    });

    test('a new failure while waiting for reconnection cancels the wait and '
        'retries immediately', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(milliseconds: 100)),
        ]);
        final h = Harness(
          reconnectPolicy: policy,
          connectionTimeout: const Duration(seconds: 30),
        );
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.signaling.emit(RemoteDescriptionEvent(fakeAnswer()));
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();

        h.transport.emit(const TransportEvent(TransportStatus.disconnected));
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 100));
        // Media never reported connected -- the controller is now
        // waiting (a 30s connectionTimeout timer is pending).
        expect(h.states.last.reconnectAttempt, 1);
        expect(async.nonPeriodicTimerCount, 1);

        // A fresh failure arrives well before the connectionTimeout
        // fires.
        h.transport.emit(const TransportEvent(TransportStatus.disconnected));
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.reconnecting);
        expect(h.states.last.reconnectAttempt, 2);
        expect(async.nonPeriodicTimerCount, 1);
      });
    });

    test('dispose() before start() transitions idle -> ended directly', () {
      fakeAsync((async) {
        final h = Harness();
        expect(h.controller.state.phase, CallPhase.idle);

        h.run(async, h.controller.dispose);
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.ended);
        expect(h.states.last.endReason, CallEndReason.disposed);
      });
    });

    test('hangUp() before start() transitions idle -> ending -> ended', () {
      fakeAsync((async) {
        final h = Harness();
        h.run(async, h.controller.hangUp);
        async.flushMicrotasks();

        expect(h.states.map((s) => s.phase).toList(), [
          CallPhase.ending,
          CallPhase.ended,
        ]);
        expect(h.states.last.endReason, CallEndReason.localHangup);
      });
    });

    test('hangUp() with an invalid reason errors synchronously without '
        'enqueueing', () {
      fakeAsync((async) {
        final h = Harness();
        final outcome = Outcome<void>();
        outcome.attach(h.controller.hangUp(reason: ''));
        async.flushMicrotasks();

        expect(outcome.completed, true);
        expect(outcome.error, isA<ArgumentError>());
      });
    });
  });

  group('Coverage: value objects and constructor validation', () {
    test('SessionDescription rejects empty/oversized/malformed sdp', () {
      expect(
        () => SessionDescription(type: SessionDescriptionType.offer, sdp: ''),
        throwsArgumentError,
      );
      expect(
        () => SessionDescription(
          type: SessionDescriptionType.offer,
          sdp: 'a' * (1024 * 1024 + 1),
        ),
        throwsArgumentError,
      );
      expect(
        () => SessionDescription(
          type: SessionDescriptionType.offer,
          sdp: 'not-an-sdp',
        ),
        throwsArgumentError,
      );
    });

    test('IceCandidate rejects malformed candidates and metadata', () {
      expect(
        () => IceCandidate(candidate: 'a' * (16 * 1024 + 1), sdpMid: '0'),
        throwsArgumentError,
      );
      expect(
        () => IceCandidate(candidate: 'candidate:1 foo\r\nbar', sdpMid: '0'),
        throwsArgumentError,
      );
      expect(
        () => IceCandidate(candidate: 'not-a-candidate', sdpMid: '0'),
        throwsArgumentError,
      );
      expect(
        () => IceCandidate(candidate: 'candidate:1 foo'),
        throwsArgumentError,
      );
      expect(
        () => IceCandidate(candidate: null, sdpMid: ''),
        throwsArgumentError,
      );
      expect(
        () => IceCandidate(candidate: null, sdpMLineIndex: -1),
        throwsArgumentError,
      );
      // Valid: null candidate (end-of-candidates marker) with no mid/index.
      expect(IceCandidate(candidate: null).candidate, isNull);
    });

    test('RemoteHangupEvent and SendHangupCommand reject bad reasons', () {
      expect(() => RemoteHangupEvent('a' * 257), throwsArgumentError);
      expect(() => RemoteHangupEvent('bad\x00reason'), throwsArgumentError);
      expect(RemoteHangupEvent().reason, isNull);
      expect(() => SendHangupCommand('a' * 257), throwsArgumentError);
    });

    test('CallControllerException.toString formats code and message', () {
      const error = CallControllerException('some_code', 'some message');
      expect(
        error.toString(),
        'CallControllerException(some_code): some message',
      );
    });

    test('CallController constructor validates timeouts and buffer size', () {
      expect(
        () => Harness(operationTimeout: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => Harness(connectionTimeout: Duration.zero),
        throwsArgumentError,
      );
      expect(() => Harness(maxBufferedIceCandidates: 0), throwsArgumentError);
      expect(
        () => Harness(maxBufferedIceCandidates: 4097),
        throwsArgumentError,
      );
    });

    test('CallController constructor validates callId', () {
      expect(() => Harness(callId: ''), throwsArgumentError);
      expect(() => Harness(callId: 'a' * 129), throwsArgumentError);
      expect(() => Harness(callId: 'bad id with spaces'), throwsArgumentError);
    });

    test('state getter reflects the last emitted CallState', () {
      final h = Harness();
      expect(h.controller.state.phase, CallPhase.idle);
    });
  });

  group('Coverage: remaining reachable event/transition branches', () {
    test('SignalingFailureEvent from the signaling stream triggers '
        'recovery', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(milliseconds: 50)),
        ]);
        final h = Harness(reconnectPolicy: policy);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();

        h.signaling.emit(
          SignalingFailureEvent(StateError('auth token expired')),
        );
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.reconnecting);
      });
    });

    test('TransportStatus.closed triggers recovery (distinct from '
        'disconnected)', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(milliseconds: 50)),
        ]);
        final h = Harness(reconnectPolicy: policy);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();

        h.transport.emit(const TransportEvent(TransportStatus.closed));
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.reconnecting);
      });
    });

    test('a generic exception while applying a remote ICE candidate routes '
        'to recovery (not protocol failure)', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(milliseconds: 50)),
        ]);
        final h = Harness(reconnectPolicy: policy);
        h.media.addRemoteIceCandidateImpl = (_) async {
          throw StateError('ICE agent rejected the candidate');
        };
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();

        h.signaling.emit(
          RemoteIceCandidateEvent(
            IceCandidate(
              candidate: 'candidate:1 1 udp 1 10.0.0.1 1 typ host',
              sdpMid: '0',
            ),
          ),
        );
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.reconnecting);
      });
    });

    test('newConnection / connecting media states are ignored (no state '
        'change, no recovery)', () {
      fakeAsync((async) {
        final h = Harness();
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();
        final before = h.states.length;

        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connecting),
        );
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.newConnection),
        );
        async.flushMicrotasks();

        expect(
          h.states.length,
          before,
          reason:
              'duplicate/benign '
              'connection-progress events must not emit new states',
        );
        expect(h.states.last.phase, CallPhase.connected);
      });
    });

    test('recovery attempt ending with media already connected emits '
        'connected immediately (no connection-timeout wait)', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(milliseconds: 50)),
        ]);
        final h = Harness(reconnectPolicy: policy);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();

        h.media.connectionState = MediaConnectionState.connected;
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.disconnected),
        );
        async.flushMicrotasks();
        expect(h.states.last.phase, CallPhase.reconnecting);

        async.elapse(const Duration(milliseconds: 50));
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.connected);
        expectNoPendingTimers(async);
      });
    });

    test('hangUp during reconnecting transitions '
        'reconnecting -> ending -> ended', () async {
      late Harness h;
      late Outcome<void> hangup;
      late FakeAsync fa;
      fakeAsync((async) {
        fa = async;
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(seconds: 5)),
        ]);
        h = Harness(reconnectPolicy: policy);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.failed),
        );
        async.flushMicrotasks();
        expect(h.states.last.phase, CallPhase.reconnecting);

        hangup = Outcome<void>()..attach(h.run(async, h.controller.hangUp));
        async.flushMicrotasks();
      });
      await pumpEventQueue();
      fa.flushMicrotasks();

      expect(hangup.completed, isTrue);
      expect(hangup.error, isNull);
      expect(
        h.states.map((s) => s.phase).toList().sublist(h.states.length - 2),
        [CallPhase.ending, CallPhase.ended],
      );
      expect(h.states.last.endReason, CallEndReason.localHangup);
    });

    test('RemoteHangupEvent during reconnecting transitions '
        'reconnecting -> ended(remoteHangup)', () async {
      late Harness h;
      late FakeAsync fa;
      fakeAsync((async) {
        fa = async;
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.retry(const Duration(seconds: 5)),
        ]);
        h = Harness(reconnectPolicy: policy);
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.failed),
        );
        async.flushMicrotasks();
        expect(h.states.last.phase, CallPhase.reconnecting);

        h.signaling.emit(RemoteHangupEvent('peer left'));
        async.flushMicrotasks();
      });
      await pumpEventQueue();
      fa.flushMicrotasks();

      expect(h.states.last.phase, CallPhase.ended);
      expect(h.states.last.endReason, CallEndReason.remoteHangup);
    });
  });
}
