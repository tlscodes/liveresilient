/// Call screen: renders every [CallPhase] from plain data inputs only — no
/// live [CallController] or media session required, so it is fully
/// widget-testable on CI hardware with no camera/network/device.
library;

import 'package:call_core/call_core.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// Human label for [phase], distinct per phase so tests can assert each
/// state renders its own text.
String callPhaseLabel(CallPhase phase) {
  switch (phase) {
    case CallPhase.idle:
      return 'Idle';
    case CallPhase.connecting:
      return 'Connecting…';
    case CallPhase.negotiating:
      return 'Negotiating…';
    case CallPhase.connected:
      return 'Connected';
    case CallPhase.reconnecting:
      return 'Reconnecting…';
    case CallPhase.ending:
      return 'Ending call…';
    case CallPhase.ended:
      return 'Call ended';
    case CallPhase.failed:
      return 'Call failed';
  }
}

/// Human label for [reason], shown alongside a terminal phase.
String callEndReasonLabel(CallEndReason reason) {
  switch (reason) {
    case CallEndReason.localHangup:
      return 'You hung up';
    case CallEndReason.remoteHangup:
      return 'The other side hung up';
    case CallEndReason.reconnectExhausted:
      return 'Could not reconnect';
    case CallEndReason.protocolError:
      return 'Protocol error';
    case CallEndReason.mediaFailure:
      return 'Media failure';
    case CallEndReason.signalingFailure:
      return 'Signaling failure';
    case CallEndReason.disposed:
      return 'Call was disposed';
  }
}

/// One call screen, driven entirely by plain data — [phase] plus the fields
/// that are only meaningful for some phases (mirrors `CallState`'s own
/// cross-field rules, but as widget inputs instead of a live object).
class CallScreen extends StatelessWidget {
  const CallScreen({
    super.key,
    required this.phase,
    this.reconnectAttempt = 0,
    this.endReason,
    this.audioOnly = false,
    this.privacyStatus = 'E2E media · no telemetry without opt-in',
    this.onCall,
    this.onHangUp,
  });

  /// Current lifecycle phase.
  final CallPhase phase;

  /// 1-based attempt number, only meaningful while [phase] is
  /// [CallPhase.reconnecting].
  final int reconnectAttempt;

  /// Why the call ended, only meaningful on a terminal [phase].
  final CallEndReason? endReason;

  /// Whether the session degraded to audio-only (no video track).
  final bool audioOnly;

  /// Always-visible privacy status line.
  final String privacyStatus;

  /// Invoked when the user taps the call button. Null hides/disables it.
  final VoidCallback? onCall;

  /// Invoked when the user taps the hang-up button. Null hides/disables it.
  final VoidCallback? onHangUp;

  bool get _isActive =>
      phase == CallPhase.connecting ||
      phase == CallPhase.negotiating ||
      phase == CallPhase.connected ||
      phase == CallPhase.reconnecting ||
      phase == CallPhase.ending;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Spacing.s16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: Spacing.s24),
            Icon(
              _isActive ? Icons.call : Icons.call_end,
              size: 72,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: Spacing.s16),
            Semantics(
              liveRegion: true,
              child: Text(
                callPhaseLabel(phase),
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
            ),
            if (phase == CallPhase.reconnecting) ...[
              const SizedBox(height: Spacing.s8),
              Text(
                'Attempt $reconnectAttempt',
                style: theme.textTheme.bodyMedium,
              ),
            ],
            if ((phase == CallPhase.ended || phase == CallPhase.failed) &&
                endReason != null) ...[
              const SizedBox(height: Spacing.s8),
              Text(
                callEndReasonLabel(endReason!),
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
            if (audioOnly) ...[
              const SizedBox(height: Spacing.s12),
              Chip(
                avatar: const Icon(Icons.mic, size: 18),
                label: const Text('Audio only'),
              ),
            ],
            const SizedBox(height: Spacing.s24),
            _ActionButtons(
              isActive: _isActive,
              onCall: onCall,
              onHangUp: onHangUp,
            ),
            const SizedBox(height: Spacing.s24),
            Text(
              privacyStatus,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButtons extends StatelessWidget {
  const _ActionButtons({
    required this.isActive,
    required this.onCall,
    required this.onHangUp,
  });

  final bool isActive;
  final VoidCallback? onCall;
  final VoidCallback? onHangUp;

  @override
  Widget build(BuildContext context) {
    if (isActive) {
      return Semantics(
        label: 'Hang up',
        button: true,
        child: ExcludeSemantics(
          child: FilledButton.tonalIcon(
            onPressed: onHangUp,
            icon: const Icon(Icons.call_end),
            label: const Text('Hang up'),
          ),
        ),
      );
    }
    return Semantics(
      label: 'Call',
      button: true,
      child: ExcludeSemantics(
        child: FilledButton.icon(
          onPressed: onCall,
          icon: const Icon(Icons.call),
          label: const Text('Call'),
        ),
      ),
    );
  }
}
