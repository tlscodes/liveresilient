import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

/// Wires a [CallController] to fresh fakes and a fake clock. Every entry
/// point into the controller must run through [run] so `clock.now()` calls
/// made from inside the controller resolve against `async.elapsed` instead
/// of the real wall clock -- required for deterministic recovery/retryAt
/// math. Reactions driven purely by fake-stream events do not need [run]:
/// controller subscriptions are installed inside the first [run] call, and
/// Dart stream listeners run in the zone captured at `.listen()` time, so
/// they inherit the fake-clock zone automatically.
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

          expect(
            h.states.map((s) => s.phase).toList(),
            [CallPhase.connecting, CallPhase.negotiating],
          );

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

    test(
      'glare while initiator (impolite): incoming offer ignored, no rollback',
      () {
        fakeAsync((async) {
          final h = Harness();
          final offerCompleter = Completer<SessionDescription>();
          h.media.createOfferImpl = ({required iceRestart}) =>
              offerCompleter.future;

          h.run(async, h.controller.start);
          async.flushMicrotasks();

          // start() is stuck awaiting createOffer -> _makingOffer is true.
          expect(h.states.last.phase, CallPhase.negotiating);
          expect(h.log.entries, [
            'media.start',
            'transport.connect',
            'signaling.start',
            'media.createOffer(iceRestart:false)',
          ]);

          h.signaling.emit(RemoteDescriptionEvent(fakeOffer()));
          h.signaling.emit(RemoteIceCandidateEvent(fakeCandidate(1)));
          async.flushMicrotasks();

          // The offer was ignored outright: no rollback, no answer path,
          // and the ICE candidate that rode along with it was dropped too.
          expect(h.media.rollbackCalls, 0);
          expect(h.log.entries.any((e) => e.contains('createAnswer')), false);
          expect(
            h.log.entries.any((e) => e.contains('setRemoteDescription')),
            false,
          );
          expect(h.media.remoteCandidates, isEmpty);

          offerCompleter.complete(fakeOffer());
          async.flushMicrotasks();

          expect(
            h.log.entries.last,
            'signaling.send(description:offer)',
          );
          expectNoPendingTimers(async);
        });
      },
    );
  });

  group('3. Buffered local ICE candidates', () {
    test('buffered before signaling starts, flushed in order after', () {
      fakeAsync((async) {
        final h = Harness(maxBufferedIceCandidates: 3);
        final connectGate = Completer<void>();
        h.transport.connectImpl = () => connectGate.future;

        h.run(async, h.controller.start);
        async.flushMicrotasks();

        // Still stuck connecting the transport -> signaling never started.
        h.media.emit(LocalIceCandidateEvent(fakeCandidate(1)));
        h.media.emit(LocalIceCandidateEvent(fakeCandidate(2)));
        h.media.emit(LocalIceCandidateEvent(fakeCandidate(3)));
        async.flushMicrotasks();

        expect(h.signaling.sent, isEmpty);

        connectGate.complete();
        async.flushMicrotasks();

        final iceSent = h.signaling.sent
            .whereType<SendIceCandidateCommand>()
            .map((c) => c.candidate.candidate)
            .toList();
        expect(iceSent, [
          'candidate:1 1 UDP 2122260223 10.0.0.1 51 typ host',
          'candidate:2 1 UDP 2122260223 10.0.0.2 52 typ host',
          'candidate:3 1 UDP 2122260223 10.0.0.3 53 typ host',
        ]);
        expectNoPendingTimers(async);
      });
    });

    test('overflow beyond maxBufferedIceCandidates drops oldest first', () {
      fakeAsync((async) {
        final h = Harness(maxBufferedIceCandidates: 3);
        final connectGate = Completer<void>();
        h.transport.connectImpl = () => connectGate.future;

        h.run(async, h.controller.start);
        async.flushMicrotasks();

        for (var i = 1; i <= 5; i++) {
          h.media.emit(LocalIceCandidateEvent(fakeCandidate(i)));
        }
        async.flushMicrotasks();

        connectGate.complete();
        async.flushMicrotasks();

        final iceIndexes = h.signaling.sent
            .whereType<SendIceCandidateCommand>()
            .map((c) => c.candidate.candidate)
            .toList();
        // Candidates 1 and 2 were evicted; only the newest 3 survive, in
        // arrival order.
        expect(iceIndexes, [
          'candidate:3 1 UDP 2122260223 10.0.0.3 53 typ host',
          'candidate:4 1 UDP 2122260223 10.0.0.4 54 typ host',
          'candidate:5 1 UDP 2122260223 10.0.0.5 55 typ host',
        ]);
        expectNoPendingTimers(async);
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
        h.transport.emit(
          const TransportEvent(TransportStatus.disconnected),
        );
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
        h.transport.emit(
          const TransportEvent(TransportStatus.disconnected),
        );
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

          h.transport.emit(
            const TransportEvent(TransportStatus.disconnected),
          );
          async.flushMicrotasks();
          expect(h.states.last.reconnectAttempt, 1);

          async.elapse(const Duration(milliseconds: 100));
          // Negotiate ran, but media never reported connected -> the
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
    test('policy gives up -> failed(reconnectExhausted), done resolves', () {
      fakeAsync((async) {
        final policy = ScriptedReconnectPolicy(<ReconnectDecision>[
          ReconnectDecision.giveUp('budget exhausted'),
        ]);
        final h = Harness(reconnectPolicy: policy);
        h.run(async, h.controller.start);
        async.flushMicrotasks();

        final outcome = Outcome<CallState>();
        outcome.attach(h.controller.done);

        h.transport.emit(
          const TransportEvent(TransportStatus.disconnected),
        );
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.failed);
        expect(h.states.last.endReason, CallEndReason.reconnectExhausted);
        expect(outcome.completed, true);
        expect(outcome.value?.phase, CallPhase.failed);
        expect(outcome.value?.endReason, CallEndReason.reconnectExhausted);
        expectNoPendingTimers(async);
      });
    });

    test('a throwing policy also fails as reconnectExhausted', () {
      fakeAsync((async) {
        final h = Harness(reconnectPolicy: ThrowingReconnectPolicy());
        h.run(async, h.controller.start);
        async.flushMicrotasks();

        h.transport.emit(
          const TransportEvent(TransportStatus.disconnected),
        );
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.failed);
        expect(h.states.last.endReason, CallEndReason.reconnectExhausted);
        expectNoPendingTimers(async);
      });
    });
  });

  group('7. Protocol error', () {
    test('createAnswer returning an offer -> failed(protocolError)', () {
      fakeAsync((async) {
        final h = Harness(role: CallRole.receiver);
        h.media.createAnswerImpl = () async => fakeOffer();
        h.run(async, h.controller.start);
        async.flushMicrotasks();

        h.signaling.emit(RemoteDescriptionEvent(fakeOffer()));
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.failed);
        expect(h.states.last.endReason, CallEndReason.protocolError);
        expectNoPendingTimers(async);
      });
    });

    test(
      'createOffer returning an answer during a signaling-driven '
      'renegotiate -> failed(protocolError)',
      () {
        // NOTE: a bad createOffer during the *initial* start() negotiate
        // is caught by start()'s generic `catch` and routed through
        // _beginRecovery, not _fail -- only negotiates triggered from
        // _handleSignalingEvent (e.g. RestartRequestedEvent) run under the
        // `on CallProtocolException -> _fail(protocolError)` handler. So
        // this drives the bad createOffer via a restart request instead.
        fakeAsync((async) {
          final h = Harness(role: CallRole.receiver);
          h.run(async, h.controller.start);
          async.flushMicrotasks();
          h.signaling.emit(RemoteDescriptionEvent(fakeOffer()));
          async.flushMicrotasks();
          expect(h.states.last.phase, CallPhase.negotiating);

          h.media.createOfferImpl = ({required iceRestart}) async =>
              fakeAnswer();
          h.signaling.emit(const RestartRequestedEvent());
          async.flushMicrotasks();

          expect(h.states.last.phase, CallPhase.failed);
          expect(h.states.last.endReason, CallEndReason.protocolError);
          expectNoPendingTimers(async);
        });
      },
    );
  });

  group('8. hangUp', () {
    test('sends hangup, tears down once each, ends localHangup', () {
      fakeAsync((async) {
        final h = Harness();
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();

        h.run(async, h.controller.hangUp);
        async.flushMicrotasks();

        final hangups = h.signaling.sent.whereType<SendHangupCommand>();
        expect(hangups, hasLength(1));
        expect(hangups.first.reason, 'hangup');

        expect(h.states.last.phase, CallPhase.ended);
        expect(h.states.last.endReason, CallEndReason.localHangup);
        expect(h.signaling.stopCalls, 1);
        expect(h.transport.disconnectCalls, 1);
        expect(h.media.stopCalls, 1);
        expectNoPendingTimers(async);
      });
    });

    test('hangUp after terminal is a no-op, not an error', () {
      fakeAsync((async) {
        final h = Harness();
        h.run(async, h.controller.start);
        async.flushMicrotasks();

        h.run(async, h.controller.hangUp);
        async.flushMicrotasks();
        final afterFirst = h.states.length;

        final outcome = Outcome<void>();
        outcome.attach(h.run(async, h.controller.hangUp));
        async.flushMicrotasks();

        expect(outcome.completed, true);
        expect(outcome.error, isNull);
        expect(h.states.length, afterFirst);
      });
    });

    test('teardown swallows a failing collaborator (best-effort)', () {
      fakeAsync((async) {
        final h = Harness();
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

        expect(h.states.last.phase, CallPhase.ended);
        expect(h.states.last.endReason, CallEndReason.localHangup);
        expect(h.media.stopCalls, 1);
        expectNoPendingTimers(async);
      });
    });
  });

  group('9. Hangup/dispose/lifecycle edge cases', () {
    test('RemoteHangupEvent -> ended(remoteHangup)', () {
      fakeAsync((async) {
        final h = Harness();
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.media.emit(
          const MediaConnectionChangedEvent(MediaConnectionState.connected),
        );
        async.flushMicrotasks();

        h.signaling.emit(RemoteHangupEvent('bye'));
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.ended);
        expect(h.states.last.endReason, CallEndReason.remoteHangup);
        expectNoPendingTimers(async);
      });
    });

    test('dispose() mid-call -> ended(disposed), stream closes, no timers', () {
      fakeAsync((async) {
        final h = Harness();
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        expect(h.states.last.phase, CallPhase.negotiating);

        h.run(async, h.controller.dispose);
        async.flushMicrotasks();

        expect(h.states.last.phase, CallPhase.ended);
        expect(h.states.last.endReason, CallEndReason.disposed);
        expect(h.statesClosed, true);
        expectNoPendingTimers(async);
      });
    });

    test('dispose() after terminal only cancels subscriptions, is idempotent', () {
      fakeAsync((async) {
        final h = Harness();
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.run(async, h.controller.hangUp);
        async.flushMicrotasks();

        h.run(async, h.controller.dispose);
        async.flushMicrotasks();
        expect(h.statesClosed, true);
        final afterFirstDispose = h.states.length;

        // A second dispose must be a pure no-op.
        h.run(async, h.controller.dispose);
        async.flushMicrotasks();
        expect(h.states.length, afterFirstDispose);
      });
    });

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

    test('hangUp after dispose throws StateError (disposed guard)', () {
      fakeAsync((async) {
        final h = Harness();
        h.run(async, h.controller.start);
        async.flushMicrotasks();
        h.run(async, h.controller.dispose);
        async.flushMicrotasks();

        final outcome = Outcome<void>();
        outcome.attach(h.run(async, h.controller.hangUp));
        async.flushMicrotasks();

        expect(outcome.completed, true);
        expect(outcome.error, isA<StateError>());
      });
    });

    test('sequence numbers strictly increase across a full lifecycle', () {
      fakeAsync((async) {
        final h = Harness(role: CallRole.receiver);
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

        expect(h.states, isNotEmpty);
        expectStrictlyIncreasingSequence(h.states);
      });
    });
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

    test('a local ICE send failure buffers the candidate and starts recovery', () {
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
    });

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
  });
}
