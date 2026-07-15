/// [CallSignaling] implementation over a [SignalingGateway].
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:signaling/signaling.dart';

import 'envelope_codec.dart';
import 'signaling_gateway.dart';

/// Bridges `call_core`'s [CallSignaling] onto a [SignalingGateway].
///
/// - [start] wires the gateway's inbound envelope stream to decoded
///   [SignalingEvent]s, dropping malformed payloads and envelopes for any
///   call other than the one this session started for.
/// - [send] maps the command to a wire `(type, payload)` pair and awaits
///   the terminal outbox outcome: [OutboxOutcome.acknowledged] completes
///   normally; [OutboxOutcome.expired] and [OutboxOutcome.disposed] throw a
///   [StateError] so `call_core` treats the failed send as a recovery
///   trigger.
/// - [stop] only detaches this instance's listeners — the gateway's own
///   lifecycle (connect/dispose) is owned by the caller, not by this class.
class AdapterCallSignaling implements CallSignaling {
  AdapterCallSignaling(this._gateway);

  final SignalingGateway _gateway;

  final _eventsController = StreamController<SignalingEvent>.broadcast();
  StreamSubscription<SignalEnvelope>? _inboundSubscription;
  String? _callId;

  @override
  Stream<SignalingEvent> get events => _eventsController.stream;

  @override
  Future<void> start({required String callId, required CallRole role}) async {
    _callId = callId;
    await _inboundSubscription?.cancel();
    _inboundSubscription = _gateway.inbound.listen((envelope) {
      if (envelope.callId != callId) return;
      final event = decodeInbound(envelope.type, envelope.payload);
      if (event == null) return;
      if (!_eventsController.isClosed) {
        _eventsController.add(event);
      }
    });
  }

  @override
  Future<void> send(SignalingCommand command) async {
    final callId = _callId;
    if (callId == null) {
      throw StateError('AdapterCallSignaling.send() called before start().');
    }
    final (type, payload) = encodeCommand(command);
    final outcome = await _gateway.send(
      callId: callId,
      type: type,
      payload: payload,
    );
    switch (outcome) {
      case OutboxOutcome.acknowledged:
        return;
      case OutboxOutcome.expired:
      case OutboxOutcome.disposed:
        throw StateError(
          'Signaling send did not complete (outcome: ${outcome.name}); '
          'treat as a recovery trigger.',
        );
    }
  }

  @override
  Future<void> stop() async {
    await _inboundSubscription?.cancel();
    _inboundSubscription = null;
  }
}
