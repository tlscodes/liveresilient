enum CallStatus {
  idle,
  dialing,
  ringing,
  connected,
  reconnecting,
  ended,
}

final class CallState {
  const CallState({
    this.status = CallStatus.idle,
  });

  final CallStatus status;

  bool get isIdle => status == CallStatus.idle;

  bool get isInProgress =>
      status == CallStatus.dialing ||
      status == CallStatus.ringing ||
      status == CallStatus.connected ||
      status == CallStatus.reconnecting;

  bool get isConnected => status == CallStatus.connected;

  bool get isTerminal => status == CallStatus.ended;

  CallState copyWith({
    CallStatus? status,
  }) {
    return CallState(
      status: status ?? this.status,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CallState && other.status == status;

  @override
  int get hashCode => status.hashCode;

  @override
  String toString() => 'CallState(status: ${status.name})';
}
