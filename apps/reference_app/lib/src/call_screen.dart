/// Call screen: renders every [CallPhase] from plain data inputs only — no
/// live [CallController] or media session required, so it is fully
/// widget-testable on CI hardware with no camera/network/device.
library;

import 'package:call_core/call_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

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
    case CallPhase.degraded:
      return 'Connected — survival mode';
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

/// Human label for [mode], shown while the call runs degraded. The wording
/// deliberately reads as a MODE, never as an error.
String degradedModeLabel(DegradedMode mode) {
  switch (mode) {
    case DegradedMode.lowRateVoice:
      return 'Low-data voice — quality reduced to keep the call alive';
    case DegradedMode.tokenVoice:
      return 'Token-voice mode — ultra-low-data live voice on your '
          'personal codec';
    case DegradedMode.voiceNotes:
      return 'Voice-note mode — clips send whenever the network allows';
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
    this.degradedMode,
    this.audioOnly = false,
    this.privacyStatus = 'E2E media · no telemetry without opt-in',
    this.callId,
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

  /// Survival mode, only meaningful while [phase] is [CallPhase.degraded].
  final DegradedMode? degradedMode;

  /// Whether the session degraded to audio-only (no video track).
  final bool audioOnly;

  /// Always-visible privacy status line.
  final String privacyStatus;

  /// The current call's id, shown only while a call is active.
  ///
  /// It is also the border relay's session id, so it is what the other
  /// side needs in order to join — and equally what an eavesdropper needs
  /// in order to attach. The screen labels it as a secret and never shows
  /// it once the call has ended.
  final String? callId;

  /// Invoked when the user taps the call button. Null hides/disables it.
  final VoidCallback? onCall;

  /// Invoked when the user taps the hang-up button. Null hides/disables it.
  final VoidCallback? onHangUp;

  bool get _isActive =>
      phase == CallPhase.connecting ||
      phase == CallPhase.negotiating ||
      phase == CallPhase.connected ||
      phase == CallPhase.degraded ||
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
            if (phase == CallPhase.degraded && degradedMode != null) ...[
              const SizedBox(height: Spacing.s8),
              Chip(
                avatar: const Icon(Icons.network_check, size: 18),
                label: Text(degradedModeLabel(degradedMode!)),
              ),
            ],
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
            if (_isActive && callId != null) ...[
              const SizedBox(height: Spacing.s12),
              _CallIdCard(callId: callId!),
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

/// Shows the call id with a copy action, labelled as the secret it is.
class _CallIdCard extends StatelessWidget {
  const _CallIdCard({required this.callId});

  final String callId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.s16,
          vertical: Spacing.s12,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.key, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: Spacing.s8),
                Text('Call key', style: theme.textTheme.labelLarge),
              ],
            ),
            const SizedBox(height: Spacing.s8),
            SelectableText(
              callId,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Spacing.s8),
            Text(
              'Share only with the person you are calling — anyone with '
              'this key can join.',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Spacing.s8),
            TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: callId)),
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy'),
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
