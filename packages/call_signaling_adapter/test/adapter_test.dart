import 'package:call_core/call_core.dart';
import 'package:call_signaling_adapter/call_signaling_adapter.dart';
import 'package:signaling/signaling.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  group('AdapterCallSignaling', () {
    late FakeSignalingGateway gateway;
    late AdapterCallSignaling signaling;

    setUp(() {
      gateway = FakeSignalingGateway();
      signaling = AdapterCallSignaling(gateway);
    });

    test('start() routes only envelopes matching the started callId', () async {
      final events = <SignalingEvent>[];
      final sub = signaling.events.listen(events.add);
      await signaling.start(callId: 'call-1', role: CallRole.initiator);

      gateway.pushInbound(
        testEnvelope(callId: 'call-1', type: SignalType.offer),
      );
      gateway.pushInbound(
        testEnvelope(callId: 'other-call', type: SignalType.offer),
      );
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single, isA<RemoteDescriptionEvent>());
      await sub.cancel();
    });

    test('start() drops malformed inbound payloads', () async {
      final events = <SignalingEvent>[];
      final sub = signaling.events.listen(events.add);
      await signaling.start(callId: 'call-1', role: CallRole.initiator);

      gateway.pushInbound(
        testEnvelope(
          callId: 'call-1',
          type: SignalType.offer,
          payload: const {'sdp': 42},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty);
      await sub.cancel();
    });

    test('send() maps SendHangupCommand and awaits acknowledged', () async {
      await signaling.start(callId: 'call-1', role: CallRole.initiator);
      await signaling.send(SendHangupCommand('done'));

      expect(gateway.sendCalls, hasLength(1));
      final call = gateway.sendCalls.single;
      expect(call.callId, 'call-1');
      expect(call.type, SignalType.callControl);
      expect(call.payload, {'action': 'hangup', 'reason': 'done'});
    });

    test('send() maps SendRestartRequestCommand', () async {
      await signaling.start(callId: 'call-1', role: CallRole.initiator);
      await signaling.send(const SendRestartRequestCommand());

      final call = gateway.sendCalls.single;
      expect(call.type, SignalType.callControl);
      expect(call.payload, {'action': 'restartRequest'});
    });

    test('send() completes normally on OutboxOutcome.acknowledged', () async {
      await signaling.start(callId: 'call-1', role: CallRole.initiator);
      gateway.queueOutcome(OutboxOutcome.acknowledged);
      await expectLater(
        signaling.send(const SendRestartRequestCommand()),
        completes,
      );
    });

    test('send() throws StateError on OutboxOutcome.expired', () async {
      await signaling.start(callId: 'call-1', role: CallRole.initiator);
      gateway.queueOutcome(OutboxOutcome.expired);
      await expectLater(
        signaling.send(const SendRestartRequestCommand()),
        throwsA(isA<StateError>()),
      );
    });

    test('send() throws StateError on OutboxOutcome.disposed', () async {
      await signaling.start(callId: 'call-1', role: CallRole.initiator);
      gateway.queueOutcome(OutboxOutcome.disposed);
      await expectLater(
        signaling.send(const SendRestartRequestCommand()),
        throwsA(isA<StateError>()),
      );
    });

    test('send(SendHangupCommand) falls back to acknowledged when the gateway '
        'exceeds the 300ms timeout', () async {
      await signaling.start(callId: 'call-1', role: CallRole.initiator);
      gateway.sendDelay = const Duration(seconds: 1);

      final stopwatch = Stopwatch()..start();
      await expectLater(
        signaling.send(SendHangupCommand('user_left')),
        completes,
      );
      stopwatch.stop();

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(gateway.sendCalls.single.payload, {
        'action': 'hangup',
        'reason': 'user_left',
      });
    });

    test('send() before start() throws StateError', () async {
      await expectLater(
        signaling.send(const SendRestartRequestCommand()),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'stop() detaches listeners — later inbound frames do not emit',
      () async {
        final events = <SignalingEvent>[];
        final sub = signaling.events.listen(events.add);
        await signaling.start(callId: 'call-1', role: CallRole.initiator);
        await signaling.stop();

        gateway.pushInbound(
          testEnvelope(callId: 'call-1', type: SignalType.offer),
        );
        await Future<void>.delayed(Duration.zero);

        expect(events, isEmpty);
        await sub.cancel();
      },
    );
  });

  group('AdapterCallTransport', () {
    late FakeSignalingGateway gateway;
    late AdapterCallTransport transport;

    setUp(() {
      gateway = FakeSignalingGateway();
      transport = AdapterCallTransport(gateway);
    });

    test('connect() delegates to the gateway', () async {
      await transport.connect();
      expect(gateway.connectCalls, 1);
    });

    test('maps connecting -> connecting', () async {
      final events = <TransportEvent>[];
      final sub = transport.events.listen(events.add);
      gateway.pushState(SignalingConnectionState.connecting);
      await Future<void>.delayed(Duration.zero);
      expect(events.single.status, TransportStatus.connecting);
      await sub.cancel();
    });

    test('maps reconnecting -> connecting', () async {
      final events = <TransportEvent>[];
      final sub = transport.events.listen(events.add);
      gateway.pushState(SignalingConnectionState.reconnecting);
      await Future<void>.delayed(Duration.zero);
      expect(events.single.status, TransportStatus.connecting);
      await sub.cancel();
    });

    test('maps connected -> connected', () async {
      final events = <TransportEvent>[];
      final sub = transport.events.listen(events.add);
      gateway.pushState(SignalingConnectionState.connected);
      await Future<void>.delayed(Duration.zero);
      expect(events.single.status, TransportStatus.connected);
      await sub.cancel();
    });

    test('maps disconnected -> disconnected', () async {
      final events = <TransportEvent>[];
      final sub = transport.events.listen(events.add);
      gateway.pushState(SignalingConnectionState.disconnected);
      await Future<void>.delayed(Duration.zero);
      expect(events.single.status, TransportStatus.disconnected);
      await sub.cancel();
    });

    test('maps closed -> disconnected', () async {
      final events = <TransportEvent>[];
      final sub = transport.events.listen(events.add);
      gateway.pushState(SignalingConnectionState.closed);
      await Future<void>.delayed(Duration.zero);
      expect(events.single.status, TransportStatus.disconnected);
      await sub.cancel();
    });

    test('disconnect() detaches — later state changes do not emit', () async {
      final events = <TransportEvent>[];
      final sub = transport.events.listen(events.add);
      await transport.disconnect();

      gateway.pushState(SignalingConnectionState.connected);
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty);
      await sub.cancel();
    });

    test('connect() after disconnect() re-attaches — a recovery cycle keeps '
        'observing state changes', () async {
      final events = <TransportEvent>[];
      final sub = transport.events.listen(events.add);

      await transport.disconnect();
      await transport.connect();
      gateway.pushState(SignalingConnectionState.connected);
      await Future<void>.delayed(Duration.zero);

      expect(
        events,
        hasLength(1),
        reason:
            'the transport must not stay '
            'deaf after a disconnect/connect recovery cycle',
      );
      expect(events.single.status, TransportStatus.connected);
      await sub.cancel();
    });

    test('rapid duplicate states are collapsed: connected -> connected -> '
        'disconnected emits connected -> disconnected only', () async {
      final events = <TransportEvent>[];
      final sub = transport.events.listen(events.add);

      gateway.pushState(SignalingConnectionState.connected);
      gateway.pushState(SignalingConnectionState.connected);
      gateway.pushState(SignalingConnectionState.disconnected);
      await Future<void>.delayed(Duration.zero);

      expect(
        events.map((e) => e.status),
        [TransportStatus.connected, TransportStatus.disconnected],
        reason:
            'flapping must not propagate redundant duplicates to the '
            'core call state machine',
      );
      await sub.cancel();
    });

    test('states that map to the same TransportStatus are also collapsed '
        '(connecting -> reconnecting emits one connecting)', () async {
      final events = <TransportEvent>[];
      final sub = transport.events.listen(events.add);

      gateway.pushState(SignalingConnectionState.connecting);
      gateway.pushState(SignalingConnectionState.reconnecting);
      gateway.pushState(SignalingConnectionState.connected);
      await Future<void>.delayed(Duration.zero);

      expect(events.map((e) => e.status), [
        TransportStatus.connecting,
        TransportStatus.connected,
      ]);
      await sub.cancel();
    });

    test('dispose() closes the events stream and stays silent', () async {
      var done = false;
      final events = <TransportEvent>[];
      transport.events.listen(events.add, onDone: () => done = true);

      await transport.dispose();
      gateway.pushState(SignalingConnectionState.connected);
      await Future<void>.delayed(Duration.zero);

      expect(done, isTrue);
      expect(events, isEmpty);
    });
  });

  group('Adapter disposal (resource hygiene)', () {
    test('AdapterCallSignaling.dispose() closes events and detaches', () async {
      final gateway = FakeSignalingGateway();
      final signaling = AdapterCallSignaling(gateway);
      var done = false;
      final events = <SignalingEvent>[];
      signaling.events.listen(events.add, onDone: () => done = true);
      await signaling.start(callId: 'call-1', role: CallRole.initiator);

      await signaling.dispose();
      gateway.pushInbound(
        testEnvelope(callId: 'call-1', type: SignalType.offer),
      );
      await Future<void>.delayed(Duration.zero);

      expect(done, isTrue);
      expect(events, isEmpty);
    });

    test('AdapterCallSignaling.start() after stop() re-attaches for a new '
        'call', () async {
      final gateway = FakeSignalingGateway();
      final signaling = AdapterCallSignaling(gateway);
      final events = <SignalingEvent>[];
      final sub = signaling.events.listen(events.add);

      await signaling.start(callId: 'call-1', role: CallRole.initiator);
      await signaling.stop();
      await signaling.start(callId: 'call-2', role: CallRole.receiver);

      gateway.pushInbound(
        testEnvelope(callId: 'call-2', type: SignalType.offer),
      );
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      await sub.cancel();
    });
  });
}
