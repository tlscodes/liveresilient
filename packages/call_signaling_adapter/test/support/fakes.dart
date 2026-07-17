/// Test doubles for the `call_signaling_adapter` test suites.
library;

import 'dart:async';

import 'package:call_signaling_adapter/call_signaling_adapter.dart';
import 'package:signaling/signaling.dart';

/// In-memory [SignalingGateway] double — no sockets, no timers.
///
/// - Push inbound frames with [pushInbound].
/// - Push connection-state transitions with [pushState].
/// - Queue what the next `send()` calls should resolve to (or throw) with
///   [queueOutcome] / [queueError]; defaults to
///   [OutboxOutcome.acknowledged].
/// - [sendCalls] records every `send()` invocation for assertion.
class FakeSignalingGateway implements SignalingGateway {
  final _inboundController = StreamController<SignalEnvelope>.broadcast();
  final _stateController =
      StreamController<SignalingConnectionState>.broadcast();

  final List<({String callId, SignalType type, Map<String, Object?> payload})>
  sendCalls = [];

  final List<OutboxOutcome> _queuedOutcomes = [];
  final List<Object> _queuedErrors = [];

  int connectCalls = 0;
  int disposeCalls = 0;

  /// When set, every `send()` waits this long before resolving — simulates
  /// a slow/stalled gateway for timeout tests.
  Duration? sendDelay;

  @override
  Stream<SignalEnvelope> get inbound => _inboundController.stream;

  @override
  Stream<SignalingConnectionState> get connectionState =>
      _stateController.stream;

  @override
  Future<void> connect() async {
    connectCalls++;
  }

  @override
  Future<OutboxOutcome> send({
    required String callId,
    required SignalType type,
    required Map<String, Object?> payload,
  }) async {
    sendCalls.add((callId: callId, type: type, payload: payload));
    final delay = sendDelay;
    if (delay != null) {
      await Future<void>.delayed(delay);
    }
    if (_queuedErrors.isNotEmpty) {
      throw _queuedErrors.removeAt(0);
    }
    if (_queuedOutcomes.isNotEmpty) {
      return _queuedOutcomes.removeAt(0);
    }
    return OutboxOutcome.acknowledged;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await _inboundController.close();
    await _stateController.close();
  }

  void pushInbound(SignalEnvelope envelope) {
    if (_inboundController.isClosed) return;
    _inboundController.add(envelope);
  }

  void pushState(SignalingConnectionState state) {
    if (_stateController.isClosed) return;
    _stateController.add(state);
  }

  void queueOutcome(OutboxOutcome outcome) => _queuedOutcomes.add(outcome);

  void queueError(Object error) => _queuedErrors.add(error);
}

/// Builds a valid [SignalEnvelope] with sensible defaults.
SignalEnvelope testEnvelope({
  String? messageId,
  int sequence = 1,
  String callId = 'call-1',
  String senderKeyId = 'key-1',
  SignalType type = SignalType.offer,
  int? createdAtMs,
  Map<String, Object?> payload = const {'type': 'offer', 'sdp': 'v=0'},
}) {
  return SignalEnvelope(
    messageId: messageId ?? generateSignalMessageId(),
    sequence: sequence,
    callId: callId,
    senderKeyId: senderKeyId,
    type: type,
    createdAtMs: createdAtMs ?? DateTime.now().millisecondsSinceEpoch,
    payload: payload,
  );
}
