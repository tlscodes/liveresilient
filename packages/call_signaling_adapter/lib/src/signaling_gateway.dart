/// Narrow view over [SignalingClient] used by this adapter package.
///
/// `call_core` and `signaling` are intentionally independent type systems —
/// this package is the only place they meet. [SignalingGateway] exists so
/// the adapter (and its tests) depend on a small interface rather than the
/// concrete `SignalingClient`, keeping unit tests socket-free.
library;

import 'package:signaling/signaling.dart';

/// The subset of [SignalingClient]'s surface the adapter needs.
abstract interface class SignalingGateway {
  /// Application-facing inbound envelopes (mirrors
  /// `SignalingClient.inbound`).
  Stream<SignalEnvelope> get inbound;

  /// Connection-state transitions (mirrors
  /// `SignalingClient.connectionState`).
  Stream<SignalingConnectionState> get connectionState;

  Future<void> connect();

  /// Sends an envelope with at-least-once delivery and returns the
  /// terminal outbox outcome.
  Future<OutboxOutcome> send({
    required String callId,
    required SignalType type,
    required Map<String, Object?> payload,
  });

  Future<void> dispose();
}

/// Default [SignalingGateway] wrapping a real [SignalingClient].
class SignalingClientGateway implements SignalingGateway {
  SignalingClientGateway(this._client);

  final SignalingClient _client;

  @override
  Stream<SignalEnvelope> get inbound => _client.inbound;

  @override
  Stream<SignalingConnectionState> get connectionState =>
      _client.connectionState;

  @override
  Future<void> connect() => _client.connect();

  @override
  Future<OutboxOutcome> send({
    required String callId,
    required SignalType type,
    required Map<String, Object?> payload,
  }) {
    return _client.send(callId: callId, type: type, payload: payload);
  }

  @override
  Future<void> dispose() => _client.dispose();
}
