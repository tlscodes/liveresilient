/// Delegation coverage for [SignalingClientGateway] — the one place a real
/// [SignalingClient] meets the adapter's [SignalingGateway] seam. Wired to a
/// fake connector/socket (see `support/fake_socket.dart`) so this stays
/// socket-free like every other test in this package.
import 'dart:async';

import 'package:call_signaling_adapter/call_signaling_adapter.dart';
import 'package:signaling/signaling.dart';
import 'package:test/test.dart';

import 'support/fake_socket.dart';

void main() {
  group('SignalingClientGateway', () {
    late FakeSocket socket;
    late CountingConnector connector;
    late SignalingClient client;
    late SignalingClientGateway gateway;

    setUp(() {
      socket = FakeSocket();
      connector = CountingConnector(socket);
      client = SignalingClient(
        endpoint: Uri.parse('wss://example.test/signal'),
        localKeyId: 'key-1',
        connector: connector.call,
      );
      gateway = SignalingClientGateway(client);
    });

    tearDown(() async {
      await gateway.dispose();
    });

    test('connect() delegates to the underlying client/connector', () async {
      final states = <SignalingConnectionState>[];
      final sub = gateway.connectionState.listen(states.add);

      await gateway.connect();
      await Future<void>.delayed(Duration.zero);

      expect(connector.callCount, 1);
      expect(states, contains(SignalingConnectionState.connected));
      await sub.cancel();
    });

    test(
      'inbound forwards decoded envelopes from the underlying client',
      () async {
        await gateway.connect();
        await Future<void>.delayed(Duration.zero);

        final received = <SignalEnvelope>[];
        final sub = gateway.inbound.listen(received.add);
        final envelope = SignalEnvelope(
          messageId: generateSignalMessageId(),
          sequence: 1,
          callId: 'call-1',
          senderKeyId: 'peer-1',
          type: SignalType.offer,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
          payload: const {'type': 'offer', 'sdp': 'v=0'},
        );
        socket.pushInboundEnvelope(envelope);
        await Future<void>.delayed(Duration.zero);

        expect(received, hasLength(1));
        expect(received.single.messageId, envelope.messageId);
        await sub.cancel();
      },
    );

    test('send() forwards the envelope to the underlying socket', () async {
      await gateway.connect();
      await Future<void>.delayed(Duration.zero);

      unawaited(
        gateway.send(
          callId: 'call-1',
          type: SignalType.callControl,
          payload: const {'action': 'hangup'},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(socket.sentFrames, hasLength(1));
      expect(socket.sentFrames.single.callId, 'call-1');
      expect(socket.sentFrames.single.type, SignalType.callControl);
      expect(socket.sentFrames.single.payload, {'action': 'hangup'});
    });

    test('dispose() forwards to the underlying client', () async {
      await gateway.dispose();
      await expectLater(gateway.connect(), throwsA(isA<StateError>()));
    });
  });
}
