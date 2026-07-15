import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:signaling/signaling.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

/// `SignalingClient` schedules real `Timer`/`Timer.periodic` (heartbeat,
/// liveness, reconnect) and reads `clock.now()` for envelope timestamps
/// and staleness checks. Every test drives both through the same fake
/// timeline so elapsed time and "now" never drift apart.
void runFake(void Function(FakeAsync async) body) {
  final epoch = DateTime.utc(2026, 1, 1);
  fakeAsync((async) {
    withClock(Clock(() => epoch.add(async.elapsed)), () => body(async));
  });
}

SignalingClient _buildClient({
  required CountingConnector connector,
  OutboxStore? outboxStore,
  SignalingClientConfig config = const SignalingClientConfig(),
  String localKeyId = 'local-key',
  Uri? endpoint,
}) {
  return SignalingClient(
    endpoint: endpoint ?? Uri.parse('wss://signal.example.com/v2'),
    localKeyId: localKeyId,
    connector: connector.call,
    outboxStore: outboxStore,
    config: config,
  );
}

void main() {
  group('constructor', () {
    test('rejects a non-wss endpoint', () {
      expect(
        () => SignalingClient(
          endpoint: Uri.parse('ws://signal.example.com'),
          localKeyId: 'k',
          connector: CountingConnector().call,
        ),
        throwsArgumentError,
      );
    });

    test('accepts a wss endpoint', () {
      expect(
        () => SignalingClient(
          endpoint: Uri.parse('wss://signal.example.com'),
          localKeyId: 'k',
          connector: CountingConnector().call,
        ),
        returnsNormally,
      );
    });
  });

  group('connect()', () {
    test(
      'transitions connecting -> connected and calls the connector once',
      () {
        runFake((async) {
          final connector = CountingConnector()..queueSocket(FakeSocket());
          final client = _buildClient(connector: connector);
          final states = <SignalingConnectionState>[];
          client.connectionState.listen(states.add);

          client.connect();
          async.flushMicrotasks();

          expect(states, [
            SignalingConnectionState.connecting,
            SignalingConnectionState.connected,
          ]);
          expect(connector.callCount, 1);

          client.dispose();
          async.flushMicrotasks();
        });
      },
    );

    test('calling connect() again while already connected is a no-op', () {
      runFake((async) {
        final connector = CountingConnector()..queueSocket(FakeSocket());
        final client = _buildClient(connector: connector);
        client.connect();
        async.flushMicrotasks();
        expect(connector.callCount, 1);

        client.connect();
        async.flushMicrotasks();
        expect(connector.callCount, 1);

        client.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('heartbeat', () {
    test('sends a heartbeat frame every heartbeatInterval (3 cycles)', () {
      runFake((async) {
        final socket = FakeSocket();
        final connector = CountingConnector()..queueSocket(socket);
        final client = _buildClient(connector: connector);
        client.connect();
        async.flushMicrotasks();

        expect(
          socket.sentFrames.where((e) => e.type == SignalType.heartbeat),
          isEmpty,
        );

        for (var cycle = 1; cycle <= 3; cycle++) {
          async.elapse(const Duration(seconds: 15));
          final heartbeats = socket.sentFrames
              .where((e) => e.type == SignalType.heartbeat)
              .toList();
          expect(heartbeats.length, cycle, reason: 'cycle $cycle');
        }

        client.dispose();
        async.flushMicrotasks();
      });
    });

    test(
      'a heartbeat send failure is absorbed; the client stays connected',
      () {
        runFake((async) {
          final socket = FakeSocket();
          final connector = CountingConnector()..queueSocket(socket);
          final client = _buildClient(connector: connector);
          client.connect();
          async.flushMicrotasks();

          socket.failSend = true;
          async.elapse(const Duration(seconds: 15));
          async.flushMicrotasks();

          expect(client.currentState, SignalingConnectionState.connected);

          client.dispose();
          async.flushMicrotasks();
        });
      },
    );
  });

  group('inbound application envelopes', () {
    test('an inbound envelope is auto-acked and surfaced exactly once', () {
      runFake((async) {
        final socket = FakeSocket();
        final connector = CountingConnector()..queueSocket(socket);
        final client = _buildClient(connector: connector);
        final inbound = <SignalEnvelope>[];
        client.inbound.listen(inbound.add);
        client.connect();
        async.flushMicrotasks();

        final incoming = testEnvelope(
          messageId: 'peer-1',
          type: SignalType.offer,
          senderKeyId: 'peer-key',
        );
        socket.pushInboundEnvelope(incoming);
        async.flushMicrotasks();

        expect(inbound.map((e) => e.messageId), ['peer-1']);
        final acks = socket.sentFrames
            .where((e) => e.type == SignalType.ack)
            .toList();
        expect(acks, hasLength(1));
        expect(acks.single.payload['ackedMessageId'], 'peer-1');

        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('a duplicate inbound messageId is re-acked but not re-surfaced', () {
      runFake((async) {
        final socket = FakeSocket();
        final connector = CountingConnector()..queueSocket(socket);
        final client = _buildClient(connector: connector);
        final inbound = <SignalEnvelope>[];
        client.inbound.listen(inbound.add);
        client.connect();
        async.flushMicrotasks();

        final incoming = testEnvelope(
          messageId: 'peer-1',
          type: SignalType.offer,
        );
        socket.pushInboundEnvelope(incoming);
        async.flushMicrotasks();
        socket.pushInboundEnvelope(incoming); // simulated retransmission
        async.flushMicrotasks();

        expect(inbound, hasLength(1));
        final acks = socket.sentFrames
            .where((e) => e.type == SignalType.ack)
            .toList();
        expect(acks, hasLength(2)); // re-acked both times

        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('an inbound heartbeat is consumed silently (no surface, no ack)', () {
      runFake((async) {
        final socket = FakeSocket();
        final connector = CountingConnector()..queueSocket(socket);
        final client = _buildClient(connector: connector);
        final inbound = <SignalEnvelope>[];
        client.inbound.listen(inbound.add);
        client.connect();
        async.flushMicrotasks();

        final hb = testEnvelope(type: SignalType.heartbeat, payload: const {});
        socket.pushInboundEnvelope(hb);
        async.flushMicrotasks();

        expect(inbound, isEmpty);
        expect(
          socket.sentFrames.where((e) => e.type == SignalType.ack),
          isEmpty,
        );

        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('an inbound envelope older than maxEnvelopeAge is dropped without '
        'ack or surfacing', () {
      runFake((async) {
        final socket = FakeSocket();
        final connector = CountingConnector()..queueSocket(socket);
        final client = _buildClient(connector: connector);
        final inbound = <SignalEnvelope>[];
        client.inbound.listen(inbound.add);
        client.connect();
        async.flushMicrotasks();

        final staleCreatedAt = clock
            .now()
            .subtract(const Duration(minutes: 6))
            .millisecondsSinceEpoch;
        final stale = testEnvelope(
          messageId: 'stale-1',
          type: SignalType.offer,
          createdAtMs: staleCreatedAt,
        );
        socket.pushInboundEnvelope(stale);
        async.flushMicrotasks();

        expect(inbound, isEmpty);
        expect(
          socket.sentFrames.where((e) => e.type == SignalType.ack),
          isEmpty,
        );

        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('a malformed inbound frame is dropped without crashing; the session '
        'continues normally afterward', () {
      runFake((async) {
        final socket = FakeSocket();
        final connector = CountingConnector()..queueSocket(socket);
        final client = _buildClient(connector: connector);
        final inbound = <SignalEnvelope>[];
        client.inbound.listen(inbound.add);
        client.connect();
        async.flushMicrotasks();

        socket.pushInbound(utf8.encode('not a json envelope'));
        async.flushMicrotasks();

        expect(inbound, isEmpty);
        expect(client.currentState, SignalingConnectionState.connected);

        final ok = testEnvelope(messageId: 'ok-1', type: SignalType.offer);
        socket.pushInboundEnvelope(ok);
        async.flushMicrotasks();
        expect(inbound.map((e) => e.messageId), ['ok-1']);

        client.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('inbound acks wire into the outbox', () {
    test('an inbound ack completes the matching send() future via the outbox '
        'and is never surfaced on inbound', () {
      runFake((async) {
        final socket = FakeSocket();
        final connector = CountingConnector()..queueSocket(socket);
        final client = _buildClient(connector: connector);
        final inbound = <SignalEnvelope>[];
        client.inbound.listen(inbound.add);
        client.connect();
        async.flushMicrotasks();

        OutboxOutcome? outcome;
        client
            .send(
              callId: 'call-1',
              type: SignalType.offer,
              payload: const {'sdp': 'v=0'},
            )
            .then((o) => outcome = o);
        async.elapse(Duration.zero); // fire the outbox's immediate attempt
        async.flushMicrotasks();

        final sentOffer = socket.sentFrames.firstWhere(
          (e) => e.type == SignalType.offer,
        );

        final ackFromPeer = sentOffer.buildAck(
          ackSenderKeyId: 'peer-key',
          sequence: 1,
          nowMs: clock.now().millisecondsSinceEpoch,
        );
        socket.pushInboundEnvelope(ackFromPeer);
        async.flushMicrotasks();

        expect(outcome, OutboxOutcome.acknowledged);
        expect(inbound, isEmpty);

        client.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('liveness and reconnect', () {
    test(
      '45s of silence trips the liveness timer and triggers a reconnect',
      () {
        runFake((async) {
          final connector = CountingConnector()
            ..queueSocket(FakeSocket())
            ..queueSocket(FakeSocket());
          final client = _buildClient(connector: connector);
          final states = <SignalingConnectionState>[];
          client.connectionState.listen(states.add);
          client.connect();
          async.flushMicrotasks();
          expect(connector.callCount, 1);

          // No inbound frames at all for the full liveness window.
          async.elapse(const Duration(seconds: 45));
          expect(states, contains(SignalingConnectionState.reconnecting));

          // Reconnect delay is full-jitter, bounded by maxReconnectDelay:
          // assert only the upper bound, never an exact delay.
          async.elapse(
            client.config.maxReconnectDelay + const Duration(milliseconds: 1),
          );
          async.flushMicrotasks();

          expect(connector.callCount, 2);
          expect(client.currentState, SignalingConnectionState.connected);

          client.dispose();
          async.flushMicrotasks();
        });
      },
    );

    test('a socket error mid-session moves to reconnecting and reconnects', () {
      runFake((async) {
        final socket1 = FakeSocket();
        final socket2 = FakeSocket();
        final connector = CountingConnector()
          ..queueSocket(socket1)
          ..queueSocket(socket2);
        final client = _buildClient(connector: connector);
        final states = <SignalingConnectionState>[];
        client.connectionState.listen(states.add);
        client.connect();
        async.flushMicrotasks();
        expect(connector.callCount, 1);

        socket1.emitError(StateError('socket died'));
        async.flushMicrotasks();
        expect(states, contains(SignalingConnectionState.reconnecting));

        async.elapse(
          client.config.maxReconnectDelay + const Duration(milliseconds: 1),
        );
        async.flushMicrotasks();

        expect(connector.callCount, 2);
        expect(client.currentState, SignalingConnectionState.connected);

        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('the remote cleanly closing the socket (onDone) also reconnects', () {
      runFake((async) {
        final socket1 = FakeSocket();
        final socket2 = FakeSocket();
        final connector = CountingConnector()
          ..queueSocket(socket1)
          ..queueSocket(socket2);
        final client = _buildClient(connector: connector);
        client.connect();
        async.flushMicrotasks();
        expect(connector.callCount, 1);

        socket1.emitDone();
        async.flushMicrotasks();

        async.elapse(
          client.config.maxReconnectDelay + const Duration(milliseconds: 1),
        );
        async.flushMicrotasks();

        expect(connector.callCount, 2);
        expect(client.currentState, SignalingConnectionState.connected);

        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('reconnect attempts are capped at maxReconnectAttempts, then the '
        'client settles into disconnected and stops retrying', () {
      runFake((async) {
        final connector = CountingConnector();
        connector.defaultFactory = () => throw StateError('offline');
        final client = _buildClient(
          connector: connector,
          config: const SignalingClientConfig(maxReconnectAttempts: 10),
        );

        client.connect();
        async.flushMicrotasks();
        expect(connector.callCount, 1); // the initial connect() attempt

        // Each failed attempt schedules the next with a delay bounded by
        // maxReconnectDelay (full jitter); elapsing that cap after every
        // failure guarantees the next attempt (or the terminal
        // disconnected state) has already happened.
        for (var i = 0; i < 10; i++) {
          async.elapse(
            client.config.maxReconnectDelay + const Duration(milliseconds: 1),
          );
          async.flushMicrotasks();
        }

        expect(client.currentState, SignalingConnectionState.disconnected);
        expect(connector.callCount, 11); // 1 initial + 10 reconnect attempts

        final callsAfterGivingUp = connector.callCount;
        async.elapse(const Duration(minutes: 10));
        expect(connector.callCount, callsAfterGivingUp);

        client.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('outbox <-> connection integration', () {
    test('a still-pending outbox envelope is retransmitted on the new socket '
        'immediately after reconnect (flush on reconnect)', () {
      runFake((async) {
        final socket1 = FakeSocket();
        final socket2 = FakeSocket();
        final connector = CountingConnector()
          ..queueSocket(socket1)
          ..queueSocket(socket2);
        final client = _buildClient(connector: connector);
        client.connect();
        async.flushMicrotasks();

        client.send(
          callId: 'call-1',
          type: SignalType.offer,
          payload: const {'sdp': 'v=0'},
        );
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        expect(
          socket1.sentFrames.where((e) => e.type == SignalType.offer),
          hasLength(1),
        );

        // socket1 dies before any ack arrives; the outbox keeps the
        // envelope pending across the reconnect.
        socket1.emitError(StateError('dropped'));
        async.flushMicrotasks();

        // Step in small increments up to the reconnect-delay cap, stopping
        // the instant reconnect completes. The outbox's own back-off timer
        // keeps running independently of connection state while
        // disconnected (attempts while `_socket == null` are silently
        // dropped by `_transmitFrame`, never reach `sentFrames`), so
        // stepping precisely — rather than elapsing the full cap in one
        // shot — avoids also sweeping past one of ITS retries, which would
        // legitimately (at-least-once delivery) add a second transmission
        // on socket2 and make the "immediately on reconnect" assertion
        // below ambiguous.
        var reconnected = false;
        var elapsedMs = 0;
        while (!reconnected && elapsedMs <= 30000) {
          async.elapse(const Duration(milliseconds: 50));
          async.flushMicrotasks();
          elapsedMs += 50;
          reconnected = connector.callCount == 2;
        }

        expect(reconnected, isTrue);
        expect(client.currentState, SignalingConnectionState.connected);
        expect(
          socket2.sentFrames.where((e) => e.type == SignalType.offer),
          hasLength(1),
        );

        client.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('dispose()', () {
    test('closes state as closed, closes both streams, and leaves zero '
        'pending timers (including outbox timers)', () {
      runFake((async) {
        final socket = FakeSocket();
        final connector = CountingConnector()..queueSocket(socket);
        final client = _buildClient(connector: connector);

        final states = <SignalingConnectionState>[];
        var inboundDone = false;
        var stateDone = false;
        client.connectionState.listen(
          states.add,
          onDone: () => stateDone = true,
        );
        client.inbound.listen(null, onDone: () => inboundDone = true);

        client.connect();
        async.flushMicrotasks();

        // A never-acked pending send leaves a live outbox retry timer
        // for dispose() to cancel.
        client.send(
          callId: 'call-1',
          type: SignalType.offer,
          payload: const {'sdp': 'v=0'},
        );
        async.flushMicrotasks();

        client.dispose();
        async.flushMicrotasks();

        expect(states.last, SignalingConnectionState.closed);
        expect(client.currentState, SignalingConnectionState.closed);
        expect(inboundDone, isTrue);
        expect(stateDone, isTrue);
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}
