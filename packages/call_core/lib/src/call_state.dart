enum CallPhase {
  idle,
  connecting,
  negotiating,
  connected,
  reconnecting,
  ending,
  ended,
  failed,
}

enum CallEndReason {
  localHangup,
  remoteHangup,
  reconnectExhausted,
  protocolError,
  mediaFailure,
  signalingFailure,
  disposed,
}

final class CallState {
  CallState({
    required this.phase,
    required this.sequence,
    required this.changedAt,
    this.reconnectAttempt = 0,
    this.nextRetryAt,
    this.endReason,
    this.error,
  }) {
    if (sequence < 0) {
      throw ArgumentError.value(sequence, 'sequence');
    }
    if (reconnectAttempt < 0) {
      throw ArgumentError.value(reconnectAttempt, 'reconnectAttempt');
    }
    if (phase == CallPhase.reconnecting && reconnectAttempt < 1) {
      throw ArgumentError(
        'A reconnecting state requires reconnectAttempt >= 1',
      );
    }
    if (phase != CallPhase.reconnecting && nextRetryAt != null) {
      throw ArgumentError('nextRetryAt is only valid for reconnecting states');
    }
    if ((phase == CallPhase.ended || phase == CallPhase.failed) &&
        endReason == null) {
      throw ArgumentError('Terminal states require an end reason');
    }
    if (phase != CallPhase.ended &&
        phase != CallPhase.failed &&
        endReason != null) {
      throw ArgumentError('endReason is only valid for terminal states');
    }
  }

  final CallPhase phase;
  final int sequence;
  final DateTime changedAt;
  final int reconnectAttempt;
  final DateTime? nextRetryAt;
  final CallEndReason? endReason;
  final Object? error;

  bool get isTerminal => phase == CallPhase.ended || phase == CallPhase.failed;
}
