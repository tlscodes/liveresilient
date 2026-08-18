/// Call screen: renders every [CallPhase] from plain data inputs only — no
/// live [CallController] or media session required, so it is fully
/// widget-testable on CI hardware with no camera/network/device.
library;

import 'package:call_core/call_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'theme.dart';
import 'ui/network_truth.dart';
import 'ui/quality_gauge.dart';

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
    this.quality,
    this.rung,
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

  /// Live per-reading quality stats for the active call, sourced from the
  /// real path stats. Null (or a non-active [phase]) hides the gauge card;
  /// the screen never invents readings.
  final Stream<CallQualityReading>? quality;

  /// The adaptive ladder's current [OperatingRung]; null renders the ladder
  /// display in its no-signal state.
  final OperatingRung? rung;

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
    final liveQuality = quality;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsetsDirectional.all(Spacing.s16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: Spacing.s24),
            _PhaseHero(phase: phase, isActive: _isActive, callId: callId),
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
            // Mirrors the real degraded mode — active exactly when the call
            // is running on voice notes; zero height otherwise.
            VoiceNoteModeBanner(
              active: phase == CallPhase.degraded &&
                  degradedMode == DegradedMode.voiceNotes,
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
            // Real-stats instruments: only while a call is actually running
            // AND a stats stream exists — the gauge never renders without a
            // call to measure.
            if (liveQuality != null && _isActive) ...[
              const SizedBox(height: AppSpacing.s16),
              _QualityCard(quality: liveQuality, rung: rung),
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
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.r12),
                  side: BorderSide(color: tokensOrDefault(context).outlineSoft),
                ),
              ),
            ],
            const SizedBox(height: Spacing.s24),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: SizedBox(
                width: double.infinity,
                child: _ActionButtons(
                  isActive: _isActive,
                  onCall: onCall,
                  onHangUp: onHangUp,
                ),
              ),
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

/// The 96dp phase hero circle. Its color is stable for the whole call —
/// derived from the call id when one exists (see [heroColorFor]), falling
/// back to the scheme primary — and each phase CHANGE plays a one-shot
/// scale-in ([AnimatedSwitcher] keyed by phase, settle-safe).
class _PhaseHero extends StatelessWidget {
  const _PhaseHero({
    required this.phase,
    required this.isActive,
    required this.callId,
  });

  final CallPhase phase;
  final bool isActive;
  final String? callId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final id = callId;
    final color = id == null || id.isEmpty
        ? scheme.primary
        : heroColorFor(id, scheme.brightness);
    return AnimatedSwitcher(
      duration: AppMotion.base,
      switchInCurve: AppMotion.enter,
      switchOutCurve: AppMotion.standard,
      transitionBuilder: (child, animation) => ScaleTransition(
        scale: animation,
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: Container(
        key: ValueKey<CallPhase>(phase),
        width: 96,
        height: 96,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(
          isActive ? Icons.call : Icons.call_end,
          size: 44,
          color: id == null || id.isEmpty ? scheme.onPrimary : Colors.white,
        ),
      ),
    );
  }
}

/// Deterministic per-call hero color: an FNV-1a hash of [callId] picks the
/// hue (stable across runs and platforms, unlike `String.hashCode`), with
/// lightness capped per [brightness] so white ink always reads on it.
/// A derived color by design — the call's visual identity — not a palette
/// literal.
Color heroColorFor(String callId, Brightness brightness) {
  var hash = 0x811c9dc5;
  for (final unit in callId.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  final hue = (hash % 360).toDouble();
  final lightness = brightness == Brightness.dark ? 0.46 : 0.40;
  return HSLColor.fromAHSL(1, hue, 0.45, lightness).toColor();
}

/// The quality instruments card. The [StreamBuilder] is scoped to exactly
/// this leaf — one reading repaints the gauge/ladder pair and nothing else
/// on the screen; no `setState` exists anywhere in this flow.
class _QualityCard extends StatelessWidget {
  const _QualityCard({required this.quality, required this.rung});

  final Stream<CallQualityReading> quality;
  final OperatingRung? rung;

  @override
  Widget build(BuildContext context) {
    final tokens = tokensOrDefault(context);
    return Card(
      margin: EdgeInsetsDirectional.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.r16),
        side: BorderSide(color: tokens.outlineSoft),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(AppSpacing.s16),
        child: StreamBuilder<CallQualityReading>(
          stream: quality,
          builder: (context, snapshot) {
            final gauge = QualityGauge(reading: snapshot.data);
            final ladder = LadderRungIndicator(rung: rung);
            return LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth >= 420) {
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      gauge,
                      const SizedBox(width: AppSpacing.s24),
                      ladder,
                    ],
                  );
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    gauge,
                    const SizedBox(height: AppSpacing.s16),
                    ladder,
                  ],
                );
              },
            );
          },
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
      margin: EdgeInsetsDirectional.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.r16),
        side: BorderSide(color: tokensOrDefault(context).outlineSoft),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(
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
