/// A `CallController`'s position in its call lifecycle.
///
/// Legal transitions are enforced by `CallController._isAllowedTransition`;
/// see each value's doc for where it can come from and go to. [ended] and
/// [failed] are the only terminal phases (see [CallState.isTerminal]) —
/// once reached, the state machine never leaves them.
enum CallPhase {
  /// Before `CallController.start` has been called. The only phase a
  /// freshly-constructed controller can be in.
  idle,

  /// `CallController.start` is bringing up the transport, signaling
  /// channel, and media session, but negotiation has not begun yet.
  connecting,

  /// Channels are up; an SDP offer/answer exchange is in progress (or, for
  /// the receiver role, awaited). Reachable from [connecting] and re-entered
  /// from [reconnecting] whenever a fresh ICE-restart negotiation starts.
  negotiating,

  /// The media session reports a connected state. The steady-state "call is
  /// live" phase.
  connected,

  /// Recovering from a dropped transport/media/signaling channel: waiting
  /// out backoff and/or re-running the connect + negotiate sequence. See
  /// [ReconnectingCallState.reconnectAttempt] and
  /// [ReconnectingCallState.nextRetryAt].
  reconnecting,

  /// A graceful shutdown (`CallController.hangUp` or
  /// `CallController.dispose` on a non-terminal call) is tearing down
  /// channels before the call reaches [ended].
  ending,

  /// Terminal: the call ended normally. See [TerminalCallState.endReason].
  ended,

  /// Terminal: the call ended abnormally (protocol violation or reconnect
  /// budget exhaustion). See [TerminalCallState.endReason] and
  /// [CallState.error].
  failed,
}

/// Why a [CallState] reached a terminal [CallPhase] ([CallPhase.ended] or
/// [CallPhase.failed]).
///
/// Carried (and required) exclusively by the [TerminalCallState] subtypes
/// [EndedCallState] and [FailedCallState] — non-terminal states cannot hold
/// one by construction.
enum CallEndReason {
  /// The local side called `CallController.hangUp`.
  localHangup,

  /// The remote peer sent a hangup over signaling.
  remoteHangup,

  /// The `ReconnectPolicy` declined to retry again (attempt budget or
  /// elapsed-time budget exhausted, or the policy itself threw).
  reconnectExhausted,

  /// The remote peer violated the negotiation protocol (e.g. an answer that
  /// isn't actually an answer).
  protocolError,

  /// Unused by `CallController` itself today (media failures route through
  /// [reconnectExhausted] or [protocolError]); reserved for a caller-driven
  /// terminal transition attributing failure specifically to the media
  /// layer.
  mediaFailure,

  /// Unused by `CallController` itself today (signaling failures route
  /// through [reconnectExhausted] or [protocolError]); reserved for a
  /// caller-driven terminal transition attributing failure specifically to
  /// the signaling layer.
  signalingFailure,

  /// `CallController.dispose` tore down a call that had not yet reached a
  /// terminal phase.
  disposed,
}

/// An immutable snapshot of a `CallController`'s state at one point in
/// time — a SEALED hierarchy, so a `switch` over a [CallState] is
/// exhaustive and phase-specific data exists only on the subtype where it
/// is meaningful. Impossible combinations (a reconnecting snapshot with
/// attempt 0, a terminal snapshot without an [TerminalCallState.endReason],
/// a retry deadline outside recovery) are unrepresentable by construction.
///
/// The unnamed [CallState.new] factory keeps the original phase+fields
/// calling convention and throws the same [ArgumentError]s the pre-sealed
/// class did, then returns the matching subtype. The base class also keeps
/// the original read surface ([phase], [reconnectAttempt], [nextRetryAt],
/// [endReason], [error]) so phase-agnostic consumers stay source-compatible.
///
/// Value semantics: [operator ==] and [hashCode] compare every field
/// value-wise, EXCEPT [error], which is compared by identity (`Object?` has
/// no general-purpose deep-equality contract, so identity is the only
/// sound choice — see [error]'s doc).
sealed class CallState {
  CallState._({required this.sequence, required this.changedAt, this.error}) {
    if (sequence < 0) {
      throw ArgumentError.value(sequence, 'sequence');
    }
  }

  /// Creates the subtype matching [phase]. Throws [ArgumentError] if
  /// [phase] and the other fields are mutually inconsistent — the same
  /// validation contract as the pre-sealed class, now also rejecting a
  /// non-zero [reconnectAttempt] outside [CallPhase.reconnecting] (an
  /// impossible state the old class silently stored).
  factory CallState({
    required CallPhase phase,
    required int sequence,
    required DateTime changedAt,
    int reconnectAttempt = 0,
    DateTime? nextRetryAt,
    CallEndReason? endReason,
    Object? error,
  }) {
    if (reconnectAttempt < 0) {
      throw ArgumentError.value(reconnectAttempt, 'reconnectAttempt');
    }
    if (phase == CallPhase.reconnecting && reconnectAttempt < 1) {
      throw ArgumentError(
        'A reconnecting state requires reconnectAttempt >= 1',
      );
    }
    if (phase != CallPhase.reconnecting && reconnectAttempt != 0) {
      throw ArgumentError(
        'reconnectAttempt is only valid for reconnecting states',
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

    return switch (phase) {
      CallPhase.idle => IdleCallState(
        sequence: sequence,
        changedAt: changedAt,
        error: error,
      ),
      CallPhase.connecting => ConnectingCallState(
        sequence: sequence,
        changedAt: changedAt,
        error: error,
      ),
      CallPhase.negotiating => NegotiatingCallState(
        sequence: sequence,
        changedAt: changedAt,
        error: error,
      ),
      CallPhase.connected => ConnectedCallState(
        sequence: sequence,
        changedAt: changedAt,
        error: error,
      ),
      CallPhase.reconnecting => ReconnectingCallState(
        sequence: sequence,
        changedAt: changedAt,
        reconnectAttempt: reconnectAttempt,
        nextRetryAt: nextRetryAt,
        error: error,
      ),
      CallPhase.ending => EndingCallState(
        sequence: sequence,
        changedAt: changedAt,
        error: error,
      ),
      CallPhase.ended => EndedCallState(
        sequence: sequence,
        changedAt: changedAt,
        endReason: endReason!,
        error: error,
      ),
      CallPhase.failed => FailedCallState(
        sequence: sequence,
        changedAt: changedAt,
        endReason: endReason!,
        error: error,
      ),
    };
  }

  /// The lifecycle position this snapshot captures — derived from the
  /// subtype, so it can never disagree with the carried data.
  CallPhase get phase;

  /// Monotonically increasing across every [CallState] a given
  /// `CallController` ever emits, starting at 0. Never negative. Lets a
  /// consumer detect out-of-order delivery / know which of two snapshots is
  /// newer without relying on [changedAt] (which can tie or, under a
  /// non-monotonic clock, even go backwards).
  final int sequence;

  /// When [phase] was entered, per the controller's injected `Clock`
  /// (`package:clock`) — not necessarily the real wall clock, and not
  /// guaranteed strictly increasing across snapshots (see [sequence] for a
  /// monotonic alternative).
  final DateTime changedAt;

  /// The 1-based reconnect attempt number. `>= 1` on
  /// [ReconnectingCallState] (which overrides this); `0` on every other
  /// subtype by construction.
  int get reconnectAttempt => 0;

  /// When the next reconnect attempt is scheduled to fire. Non-null only
  /// ever on [ReconnectingCallState] (which overrides this).
  DateTime? get nextRetryAt => null;

  /// Why the call ended. Non-null exactly on the [TerminalCallState]
  /// subtypes (which override this as a required field).
  CallEndReason? get endReason => null;

  /// The triggering error, if any — typically populated on
  /// [ReconnectingCallState] (the cause of the current recovery attempt)
  /// and [FailedCallState] (the terminal cause). Carried on every subtype,
  /// mirroring the pre-sealed class (it was the one field never
  /// cross-checked against [phase]).
  ///
  /// Typed `Object?` because it carries whatever exception/error a
  /// transport, signaling, or media adapter happened to throw — there is no
  /// shared base type to demand structural equality from, so [operator ==]
  /// and [hashCode] compare this field by identity rather than value. Two
  /// [CallState]s built from `Exception('x')` and a second, distinct
  /// `Exception('x')` instance are therefore unequal even though the
  /// exceptions print identically; only the exact same error object (e.g.
  /// re-used across snapshots, or both fields left `null`) compares equal.
  final Object? error;

  /// Whether this snapshot is one of the two terminal subtypes
  /// ([EndedCallState], [FailedCallState]) past which a `CallController`
  /// never transitions again. Exhaustive over the sealed hierarchy.
  bool get isTerminal => switch (this) {
    EndedCallState() || FailedCallState() => true,
    IdleCallState() ||
    ConnectingCallState() ||
    NegotiatingCallState() ||
    ConnectedCallState() ||
    ReconnectingCallState() ||
    EndingCallState() => false,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is CallState &&
        other.phase == phase &&
        other.sequence == sequence &&
        other.changedAt == changedAt &&
        other.reconnectAttempt == reconnectAttempt &&
        other.nextRetryAt == nextRetryAt &&
        other.endReason == endReason &&
        identical(other.error, error);
  }

  @override
  int get hashCode => Object.hash(
    phase,
    sequence,
    changedAt,
    reconnectAttempt,
    nextRetryAt,
    endReason,
    identityHashCode(error),
  );

  @override
  String toString() =>
      'CallState(phase: ${phase.name}, sequence: $sequence, '
      'reconnectAttempt: $reconnectAttempt, endReason: ${endReason?.name})';
}

/// Snapshot of [CallPhase.idle].
final class IdleCallState extends CallState {
  IdleCallState({
    required super.sequence,
    required super.changedAt,
    super.error,
  }) : super._();

  @override
  CallPhase get phase => CallPhase.idle;
}

/// Snapshot of [CallPhase.connecting].
final class ConnectingCallState extends CallState {
  ConnectingCallState({
    required super.sequence,
    required super.changedAt,
    super.error,
  }) : super._();

  @override
  CallPhase get phase => CallPhase.connecting;
}

/// Snapshot of [CallPhase.negotiating].
final class NegotiatingCallState extends CallState {
  NegotiatingCallState({
    required super.sequence,
    required super.changedAt,
    super.error,
  }) : super._();

  @override
  CallPhase get phase => CallPhase.negotiating;
}

/// Snapshot of [CallPhase.connected].
final class ConnectedCallState extends CallState {
  ConnectedCallState({
    required super.sequence,
    required super.changedAt,
    super.error,
  }) : super._();

  @override
  CallPhase get phase => CallPhase.connected;
}

/// Snapshot of [CallPhase.reconnecting] — the only subtype that carries a
/// reconnect attempt (guaranteed `>= 1`) and an optional retry deadline.
final class ReconnectingCallState extends CallState {
  ReconnectingCallState({
    required super.sequence,
    required super.changedAt,
    required this.reconnectAttempt,
    this.nextRetryAt,
    super.error,
  }) : super._() {
    if (reconnectAttempt < 1) {
      throw ArgumentError(
        'A reconnecting state requires reconnectAttempt >= 1',
      );
    }
  }

  @override
  CallPhase get phase => CallPhase.reconnecting;

  @override
  final int reconnectAttempt;

  @override
  final DateTime? nextRetryAt;
}

/// Snapshot of [CallPhase.ending].
final class EndingCallState extends CallState {
  EndingCallState({
    required super.sequence,
    required super.changedAt,
    super.error,
  }) : super._();

  @override
  CallPhase get phase => CallPhase.ending;
}

/// Common supertype of the two terminal snapshots — the only states that
/// carry a (required) [endReason]. `state is TerminalCallState` replaces
/// phase-pair checks.
sealed class TerminalCallState extends CallState {
  TerminalCallState._({
    required super.sequence,
    required super.changedAt,
    required this.endReason,
    super.error,
  }) : super._();

  @override
  final CallEndReason endReason;
}

/// Snapshot of [CallPhase.ended] — the call ended normally.
final class EndedCallState extends TerminalCallState {
  EndedCallState({
    required super.sequence,
    required super.changedAt,
    required super.endReason,
    super.error,
  }) : super._();

  @override
  CallPhase get phase => CallPhase.ended;
}

/// Snapshot of [CallPhase.failed] — the call ended abnormally.
final class FailedCallState extends TerminalCallState {
  FailedCallState({
    required super.sequence,
    required super.changedAt,
    required super.endReason,
    super.error,
  }) : super._();

  @override
  CallPhase get phase => CallPhase.failed;
}
