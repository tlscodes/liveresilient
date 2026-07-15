import 'package:call_core/call_core.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 7, 15, 12, 0, 0);

  group('CallState construction', () {
    test('accepts a valid non-terminal, non-reconnecting state', () {
      final state = CallState(
        phase: CallPhase.connected,
        sequence: 0,
        changedAt: now,
      );
      expect(state.phase, CallPhase.connected);
      expect(state.sequence, 0);
      expect(state.reconnectAttempt, 0);
      expect(state.nextRetryAt, isNull);
      expect(state.endReason, isNull);
    });

    test('accepts a valid reconnecting state with attempt >= 1', () {
      final state = CallState(
        phase: CallPhase.reconnecting,
        sequence: 3,
        changedAt: now,
        reconnectAttempt: 1,
        nextRetryAt: now.add(const Duration(seconds: 1)),
      );
      expect(state.phase, CallPhase.reconnecting);
      expect(state.reconnectAttempt, 1);
      expect(state.nextRetryAt, isNotNull);
    });

    test('accepts a valid terminal state with an end reason', () {
      final state = CallState(
        phase: CallPhase.ended,
        sequence: 5,
        changedAt: now,
        endReason: CallEndReason.localHangup,
      );
      expect(state.phase, CallPhase.ended);
      expect(state.endReason, CallEndReason.localHangup);
    });

    test('accepts a valid failed terminal state', () {
      final state = CallState(
        phase: CallPhase.failed,
        sequence: 2,
        changedAt: now,
        endReason: CallEndReason.protocolError,
      );
      expect(state.phase, CallPhase.failed);
      expect(state.endReason, CallEndReason.protocolError);
    });

    test('rejects a negative sequence', () {
      expect(
        () => CallState(phase: CallPhase.idle, sequence: -1, changedAt: now),
        throwsArgumentError,
      );
    });

    test('rejects a negative reconnectAttempt', () {
      expect(
        () => CallState(
          phase: CallPhase.idle,
          sequence: 0,
          changedAt: now,
          reconnectAttempt: -1,
        ),
        throwsArgumentError,
      );
    });

    test('rejects reconnecting phase with reconnectAttempt 0', () {
      expect(
        () => CallState(
          phase: CallPhase.reconnecting,
          sequence: 0,
          changedAt: now,
        ),
        throwsArgumentError,
      );
    });

    test('rejects nextRetryAt set outside the reconnecting phase', () {
      expect(
        () => CallState(
          phase: CallPhase.connected,
          sequence: 0,
          changedAt: now,
          nextRetryAt: now,
        ),
        throwsArgumentError,
      );
    });

    test('rejects a terminal ended state without an end reason', () {
      expect(
        () => CallState(phase: CallPhase.ended, sequence: 0, changedAt: now),
        throwsArgumentError,
      );
    });

    test('rejects a terminal failed state without an end reason', () {
      expect(
        () => CallState(phase: CallPhase.failed, sequence: 0, changedAt: now),
        throwsArgumentError,
      );
    });

    test('rejects an endReason set on a non-terminal phase', () {
      expect(
        () => CallState(
          phase: CallPhase.connecting,
          sequence: 0,
          changedAt: now,
          endReason: CallEndReason.disposed,
        ),
        throwsArgumentError,
      );
    });
  });

  group('CallState.isTerminal truth table', () {
    final terminalPhases = {CallPhase.ended, CallPhase.failed};

    for (final phase in CallPhase.values) {
      test('$phase isTerminal == ${terminalPhases.contains(phase)}', () {
        final state = CallState(
          phase: phase,
          sequence: 0,
          changedAt: now,
          reconnectAttempt: phase == CallPhase.reconnecting ? 1 : 0,
          endReason: terminalPhases.contains(phase)
              ? CallEndReason.remoteHangup
              : null,
        );
        expect(state.isTerminal, terminalPhases.contains(phase));
      });
    }
  });
}
