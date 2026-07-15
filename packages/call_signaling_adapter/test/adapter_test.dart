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
  });
}
