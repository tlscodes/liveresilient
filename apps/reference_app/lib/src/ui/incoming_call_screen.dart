/// Incoming call screen — the emotional peak of the app.
///
/// Design contract (kernel):
///  * Full-screen vertical gradient derived from [ColorScheme] (no hex).
///  * 112dp deterministic identicon avatar (callerName.hashCode → hue) with
///    initials, ringed by TWO pulsing halos (scale 1→1.35, opacity .35→0,
///    [AppMotion.ambient] period, second ring phase-offset 50%). The pulse
///    exists ONLY while [AppMotion.ambientEnabled]; otherwise a single static
///    hairline ring with the same base geometry renders and zero timers run,
///    so `pumpAndSettle` always settles under `flutter test`.
///  * Accept/Decline are [FloatingActionButton.large] (96dp tap targets) with
///    `heroTag: null` (two FABs share one route). Accept gets a one-shot
///    mount nudge: scale 0.92→1.0, [AppMotion.enter] over [AppMotion.gentle].
///  * Network-truth touch: when a call id exists, its first 8 chars are
///    truthfully surfaced in a chip — the real CSPRNG id, never a decorative
///    lock icon.
///  * RTL-first: only directional/vertical geometry, the action row flips
///    naturally with [Directionality].
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Full-screen UI for an inbound call offer.
class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({
    super.key,
    required this.callerName,
    this.callId,
    this.audioOnly = false,
    required this.onAccept,
    required this.onDecline,
  });

  /// Display name of the caller; also seeds the identicon.
  final String callerName;

  /// The real call id (CSPRNG, from signaling); first 8 chars are surfaced.
  final String? callId;

  /// True for a voice-only offer; toggles the subtitle suffix.
  final bool audioOnly;

  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with TickerProviderStateMixin {
  static const double _avatarSize = 112;

  /// Pulse rings grow to 1.35× the avatar radius; the layer box leaves room
  /// for that plus the stroke so nothing paints outside its boundary.
  static const double _ringExtent = _avatarSize * 1.35 + AppSpacing.s8;

  /// One-shot mount nudge on the Accept action (pumpAndSettle-safe).
  late final AnimationController _nudge;
  late final Animation<double> _nudgeScale;

  /// Repeating pulse driver — created ONLY when ambient motion is enabled;
  /// null means the static hairline ring renders and no ticker exists.
  AnimationController? _rings;

  @override
  void initState() {
    super.initState();
    _nudge = AnimationController(vsync: this, duration: AppMotion.gentle);
    _nudgeScale = Tween<double>(
      begin: 0.92,
      end: 1,
    ).animate(CurvedAnimation(parent: _nudge, curve: AppMotion.enter));
    _nudge.forward();
    if (AppMotion.ambientEnabled) {
      _rings = AnimationController(vsync: this, duration: AppMotion.ambient)
        ..repeat();
    }
  }

  @override
  void dispose() {
    _nudge.dispose();
    _rings?.dispose();
    super.dispose();
  }

  void _handleAccept() {
    AppHaptics.success();
    widget.onAccept();
  }

  void _handleDecline() {
    AppHaptics.warning();
    widget.onDecline();
  }

  String get _subtitle =>
      'Incoming call${widget.audioOnly ? ' · voice' : ' · video'}';

  /// First 8 chars of the id plus an ellipsis (whole id when already short).
  static String shortCallId(String id) =>
      id.length <= 8 ? id : '${id.substring(0, 8)}…';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = context.tokens;
    final isDark = theme.brightness == Brightness.dark;

    // Vertical gradient: direction-neutral (top→bottom), scheme-derived.
    // Dark mode tints the surfaces toward primary for depth — still no hex.
    final gradientTop = isDark
        ? Color.alphaBlend(
            scheme.primary.withValues(alpha: 0.16),
            scheme.surfaceContainerLowest,
          )
        : scheme.surfaceContainerLowest;
    final gradientBottom = isDark
        ? Color.alphaBlend(
            scheme.primary.withValues(alpha: 0.05),
            scheme.surface,
          )
        : scheme.surface;

    final callId = widget.callId;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [gradientTop, gradientBottom],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsetsDirectional.symmetric(
                      horizontal: AppSpacing.s24,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildAvatarWithRings(scheme),
                        const SizedBox(height: AppSpacing.s24),
                        Text(
                          widget.callerName,
                          style: theme.textTheme.headlineMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: AppSpacing.s8),
                        Text(
                          _subtitle,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (callId != null) ...[
                          const SizedBox(height: AppSpacing.s16),
                          Tooltip(
                            message: 'Secure call id',
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: tokens.surfaceGlass,
                                borderRadius: BorderRadius.circular(
                                  AppRadius.r12,
                                ),
                                border: Border.all(color: tokens.outlineSoft),
                              ),
                              child: Padding(
                                padding: const EdgeInsetsDirectional.symmetric(
                                  horizontal: AppSpacing.s12,
                                  vertical: AppSpacing.s4,
                                ),
                                child: Text(
                                  shortCallId(callId),
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: AppSpacing.s24,
                  end: AppSpacing.s24,
                  bottom: AppSpacing.s48,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CallAction(
                      caption: 'Decline',
                      icon: Icons.call_end,
                      semanticLabel: 'Decline call',
                      // Kernel: white glyph on the danger fill (both themes).
                      background: tokens.danger,
                      foreground: Colors.white,
                      onPressed: _handleDecline,
                    ),
                    RepaintBoundary(
                      child: ScaleTransition(
                        scale: _nudgeScale,
                        child: _CallAction(
                          caption: 'Accept',
                          icon: Icons.call,
                          semanticLabel: 'Accept call',
                          background: tokens.verified,
                          foreground: tokens.onVerified,
                          onPressed: _handleAccept,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAvatarWithRings(ColorScheme scheme) {
    final rings = _rings;
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: _ringExtent,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (rings != null)
              AnimatedBuilder(
                animation: rings,
                builder: (context, _) => CustomPaint(
                  size: const Size.square(_ringExtent),
                  painter: _PulseRingsPainter(
                    progress: rings.value,
                    baseRadius: _avatarSize / 2,
                    color: scheme.primary,
                  ),
                ),
              )
            else
              // Ambient motion off: same base geometry, zero timers.
              SizedBox.square(
                dimension: _avatarSize,
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    shape: CircleBorder(
                      side: BorderSide(
                        color: scheme.primary.withValues(alpha: 0.35),
                        width: 1,
                      ),
                    ),
                  ),
                ),
              ),
            _IdenticonAvatar(name: widget.callerName, size: _avatarSize),
          ],
        ),
      ),
    );
  }
}

/// Deterministic identicon: `name.hashCode` picks a hue; a vertical
/// (direction-neutral) gradient circle carries the initials.
class _IdenticonAvatar extends StatelessWidget {
  const _IdenticonAvatar({required this.name, required this.size});

  final String name;
  final double size;

  static String initialsOf(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    final first = parts.first.substring(0, 1).toUpperCase();
    if (parts.length == 1) return first;
    return first + parts[1].substring(0, 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Computed (not literal) colors: hue is a pure function of the name.
    final hue = (name.hashCode % 360).abs().toDouble();
    final start = HSLColor.fromAHSL(1, hue, 0.55, dark ? 0.40 : 0.52).toColor();
    final end = HSLColor.fromAHSL(
      1,
      (hue + 42) % 360,
      0.60,
      dark ? 0.28 : 0.38,
    ).toColor();
    final foreground = HSLColor.fromAHSL(1, hue, 0.40, 0.97).toColor();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [start, end],
        ),
      ),
      child: Text(
        initialsOf(name),
        style: Theme.of(
          context,
        ).textTheme.displayLarge?.copyWith(color: foreground),
      ),
    );
  }
}

/// One labeled call action: a large FAB (96dp target) over a caption.
/// `heroTag: null` because two FABs share this route.
class _CallAction extends StatelessWidget {
  const _CallAction({
    required this.caption,
    required this.icon,
    required this.semanticLabel,
    required this.background,
    required this.foreground,
    required this.onPressed,
  });

  final String caption;
  final IconData icon;
  final String semanticLabel;
  final Color background;
  final Color foreground;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton.large(
          heroTag: null,
          backgroundColor: background,
          foregroundColor: foreground,
          onPressed: onPressed,
          child: Icon(icon, semanticLabel: semanticLabel),
        ),
        const SizedBox(height: AppSpacing.s8),
        Text(
          caption,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Two expanding halos: progress p ∈ [0,1) maps to scale 1→1.35 and
/// opacity .35→0; the second ring runs 50% out of phase.
class _PulseRingsPainter extends CustomPainter {
  const _PulseRingsPainter({
    required this.progress,
    required this.baseRadius,
    required this.color,
  });

  final double progress;
  final double baseRadius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (final phase in const <double>[0.0, 0.5]) {
      final p = (progress + phase) % 1.0;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: 0.35 * (1.0 - p));
      canvas.drawCircle(center, baseRadius * (1.0 + 0.35 * p), paint);
    }
  }

  @override
  bool shouldRepaint(_PulseRingsPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.baseRadius != baseRadius ||
      oldDelegate.color != color;
}
