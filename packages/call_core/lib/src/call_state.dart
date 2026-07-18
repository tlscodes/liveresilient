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
  /// [CallState.reconnectAttempt] and [CallState.nextRetryAt], both of which
  /// are only meaningful while in this phase.
  reconnecting,

  /// A graceful shutdown (`CallController.hangUp` or
  /// `CallController.dispose` on a non-terminal call) is tearing down
  /// channels before the call reaches [ended].
  ending,

  /// Terminal: the call ended normally. See [CallState.endReason] for why.
  ended,

  /// Terminal: the call ended abnormally (protocol violation or reconnect
  /// budget exhaustion). See [CallState.endReason] and [CallState.error].
  failed,
}

/// Why a [CallState] reached a terminal [CallPhase] ([CallPhase.ended] or
/// [CallPhase.failed]).
///
/// Required on every terminal [CallState] and forbidden on every
/// non-terminal one (enforced by [CallState]'s constructor).
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
/// time.
///
/// Every field's legality is cross-checked against [phase] by the
/// constructor (see each parameter's doc below), so a constructed
/// [CallState] is always internally consistent — there is no way to hold,
/// for example, a [reconnecting] phase with `reconnectAttempt: 0`, or a
/// terminal phase without an [endReason].
///
/// Value semantics: [operator ==] and [hashCode] compare every field
/// value-wise, EXCEPT [error], which is compared by identity (`Object?` has
/// no general-purpose deep-equality contract, so identity is the only
/// sound choice — see [error]'s doc).
final class CallState {
  /// Creates a new snapshot. Throws [ArgumentError] if [phase] and the
  /// other fields are mutually inconsistent — see each parameter's doc.
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

  /// The lifecycle position this snapshot captures.
  final CallPhase phase;

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

  /// The 1-based reconnect attempt number this snapshot corresponds to.
  /// Only meaningful (and required to be `>= 1`) while [phase] is
  /// [CallPhase.reconnecting]; `0` everywhere else.
  final int reconnectAttempt;

  /// When the next reconnect attempt is scheduled to fire. Only ever
  /// non-null while [phase] is [CallPhase.reconnecting]; `null` in every
  /// other phase.
  final DateTime? nextRetryAt;

  /// Why the call ended. Required (non-null) on both terminal phases
  /// ([CallPhase.ended], [CallPhase.failed]); forbidden (must be null) in
  /// every non-terminal phase.
  final CallEndReason? endReason;

  /// The triggering error, if any — typically populated on
  /// [CallPhase.reconnecting] (the cause of the current recovery attempt)
  /// and [CallPhase.failed] (the terminal cause). Not cross-checked against
  /// [phase] by the constructor, unlike every other field.
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

  /// Whether [phase] is one of the two terminal phases
  /// ([CallPhase.ended], [CallPhase.failed]) past which a `CallController`
  /// never transitions again.
  bool get isTerminal => phase == CallPhase.ended || phase == CallPhase.failed;

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
