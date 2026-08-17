/// Voice-note UI pair: the recorder overlay that docks in place of the
/// composer while recording, and the player bar rendered inside voice
/// bubbles.
///
/// Determinism contract:
///  * The recorder consumes ANY `Stream<double>` of 0..1 amplitude samples —
///    it truthfully renders whatever stream it is given.
///  * Every repeating animation (the recording pulse) checks
///    [AppMotion.ambientEnabled] and simply does not start when false, so
///    `pumpAndSettle` always settles under `flutter test`.
///  * Waveform painting happens in LOGICAL (start→end) coordinates and flips
///    for RTL, as does tap/drag-to-seek.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Reads [AppTokens] with a brightness-correct fallback so these widgets
/// (and the chat bubbles embedding them) render under a plain [ThemeData]
/// too — the pre-existing chat tests pump `MaterialApp(home: ...)` without
/// [buildAppThemeData], where the extension is absent.
AppTokens appTokensOf(BuildContext context) {
  final theme = Theme.of(context);
  return theme.extension<AppTokens>() ??
      (theme.brightness == Brightness.dark
          ? AppTokens.dark(theme.colorScheme)
          : AppTokens.light(theme.colorScheme));
}

/// `m:ss` clock label for voice-note timers and player positions.
String voiceClockLabel(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final minutes = total ~/ 60;
  final seconds = total % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// DECORATIVE waveform peaks derived deterministically from attachment
/// bytes. This is honest set dressing pending real peak extraction: the
/// wire format carries no amplitude envelope today, so the bars are a
/// stable per-attachment fingerprint (same bytes → same bars), NOT audio.
List<double> decorativeWaveformPeaks(List<int> bytes, {int barCount = 32}) {
  var h = 0x9E3779B9 ^ bytes.length;
  final peaks = <double>[];
  for (var i = 0; i < barCount; i++) {
    final b = bytes.isEmpty ? 0 : bytes[(i * 7919) % bytes.length];
    h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
    peaks.add(0.2 + 0.8 * (((h >> 8) & 0xFF) / 255.0));
  }
  return peaks;
}

/// Number of live amplitude samples the recorder keeps (and draws).
const int recorderWaveformSampleCount = 48;

/// Key on the player bar's seekable waveform region (tests target it).
const ValueKey<String> voiceNoteWaveformKey = ValueKey<String>(
  'voice-note-waveform',
);

/// A docked bar replacing the composer while a voice note records: pulsing
/// dot (ambient-gated), m:ss timer, live waveform from the last
/// [recorderWaveformSampleCount] amplitude samples, and a directional
/// slide-to-cancel affordance.
class VoiceNoteRecorderOverlay extends StatefulWidget {
  const VoiceNoteRecorderOverlay({
    super.key,
    required this.amplitude,
    required this.elapsed,
    required this.onCancel,
    this.cancelArmed = false,
  });

  /// Live 0..1 amplitude envelope.
  ///
  /// Real microphone capture wiring is a dated blocker (no recorder
  /// dependency this phase, 2026-08-10): the demo feeds a synthetic
  /// envelope and this UI truthfully renders whatever stream it is given.
  final Stream<double> amplitude;

  /// Recording time so far — the OWNER ticks it; this widget never ticks
  /// itself, so tests stay deterministic.
  final Duration elapsed;

  /// Invoked when the user cancels (tap on the affordance, or the owner's
  /// slide gesture committing).
  final VoidCallback onCancel;

  /// True while a slide-to-cancel drag has crossed the commit threshold;
  /// tints the whole bar toward the danger token.
  final bool cancelArmed;

  @override
  State<VoiceNoteRecorderOverlay> createState() =>
      _VoiceNoteRecorderOverlayState();
}

class _VoiceNoteRecorderOverlayState extends State<VoiceNoteRecorderOverlay> {
  // Ring buffer of the newest samples; the painter copies it before
  // painting so a mid-paint stream event can never shear the frame.
  final List<double> _ring = List<double>.filled(
    recorderWaveformSampleCount,
    0,
  );
  int _next = 0;
  int _filled = 0;
  StreamSubscription<double>? _subscription;

  // Repaint trigger: stream samples repaint ONLY the waveform painter —
  // no setState, no widget rebuild per sample.
  final _WaveformRepaintTrigger _repaint = _WaveformRepaintTrigger();

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(VoiceNoteRecorderOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.amplitude, widget.amplitude)) {
      _subscription?.cancel();
      _subscribe();
    }
  }

  void _subscribe() {
    _subscription = widget.amplitude.listen(_onSample);
  }

  void _onSample(double value) {
    _ring[_next] = value.clamp(0.0, 1.0);
    _next = (_next + 1) % recorderWaveformSampleCount;
    _filled = math.min(_filled + 1, recorderWaveformSampleCount);
    _repaint.bump();
  }

  /// Ordered copy, oldest → newest (copy-before-paint contract).
  List<double> _orderedSamples() {
    final out = List<double>.filled(_filled, 0);
    final start = (_next - _filled + recorderWaveformSampleCount) %
        recorderWaveformSampleCount;
    for (var i = 0; i < _filled; i++) {
      out[i] = _ring[(start + i) % recorderWaveformSampleCount];
    }
    return out;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = appTokensOf(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final restingFill = theme.colorScheme.surfaceContainerHigh;
    final fill = widget.cancelArmed
        ? Color.lerp(restingFill, tokens.danger, 0.22)!
        : restingFill;
    final waveColor = widget.cancelArmed
        ? tokens.danger
        : theme.colorScheme.onSurfaceVariant;
    return Semantics(
      label: 'Recording voice note',
      // Own node + explicit children: keeps this label exact instead of
      // merging with the timer text, and gives the nested cancel button
      // its own discoverable node.
      container: true,
      explicitChildNodes: true,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: AppSpacing.s12,
          vertical: AppSpacing.s8,
        ),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(AppRadius.r28),
        ),
        child: Row(
          children: [
            const _RecordingPulseDot(),
            const SizedBox(width: AppSpacing.s8),
            Text(
              voiceClockLabel(widget.elapsed),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: AppSpacing.s12),
            Expanded(
              child: SizedBox(
                height: 28,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _RecorderWaveformPainter(
                      sampler: _orderedSamples,
                      color: waveColor,
                      rtl: rtl,
                      repaint: _repaint,
                    ),
                    size: Size.infinite,
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.s12),
            Semantics(
              label: 'Cancel recording',
              button: true,
              child: ExcludeSemantics(
                child: GestureDetector(
                  onTap: widget.onCancel,
                  behavior: HitTestBehavior.opaque,
                  child: Opacity(
                    opacity: 0.4,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Chevron points toward the slide direction (the
                        // line start), so it flips with the text direction.
                        Icon(
                          rtl ? Icons.chevron_right : Icons.chevron_left,
                          size: 18,
                          color: theme.colorScheme.onSurface,
                        ),
                        const SizedBox(width: AppSpacing.s2),
                        Text(
                          'Slide to cancel',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The red recording dot. Pulses only while [AppMotion.ambientEnabled];
/// under `flutter test` it renders as a static dot so nothing repeats.
class _RecordingPulseDot extends StatefulWidget {
  const _RecordingPulseDot();

  @override
  State<_RecordingPulseDot> createState() => _RecordingPulseDotState();
}

class _RecordingPulseDotState extends State<_RecordingPulseDot>
    with SingleTickerProviderStateMixin {
  AnimationController? _pulse;

  @override
  void initState() {
    super.initState();
    if (AppMotion.ambientEnabled) {
      _pulse = AnimationController(
        vsync: this,
        duration: AppMotion.ambient ~/ 2,
      )..repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = appTokensOf(context);
    final dot = Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: tokens.danger, shape: BoxShape.circle),
    );
    final pulse = _pulse;
    if (pulse == null) return dot;
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1).animate(
        CurvedAnimation(parent: pulse, curve: AppMotion.standard),
      ),
      child: dot,
    );
  }
}

class _WaveformRepaintTrigger extends ChangeNotifier {
  void bump() => notifyListeners();
}

const double _barWidth = 3;
const double _barPitch = 5; // 3dp bar + 2dp gap

class _RecorderWaveformPainter extends CustomPainter {
  _RecorderWaveformPainter({
    required this.sampler,
    required this.color,
    required this.rtl,
    super.repaint,
  });

  final List<double> Function() sampler;
  final Color color;
  final bool rtl;

  @override
  void paint(Canvas canvas, Size size) {
    final samples = sampler();
    if (samples.isEmpty || size.width <= 0) return;
    final slots = math.max(1, (size.width / _barPitch).floor());
    final visible = samples.length <= slots
        ? samples
        : samples.sublist(samples.length - slots);
    final paintBar = Paint()..color = color;
    // Newest sample sits at the logical END of the line; flip for RTL.
    for (var i = 0; i < visible.length; i++) {
      final slot = slots - visible.length + i;
      final x = rtl
          ? size.width - _barPitch * slot - _barWidth
          : _barPitch * slot;
      final h = math.max(2.0, visible[i] * size.height);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, (size.height - h) / 2, _barWidth, h),
          const Radius.circular(1.5),
        ),
        paintBar,
      );
    }
  }

  @override
  bool shouldRepaint(_RecorderWaveformPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.rtl != rtl;
}

/// Playback bar for a voice bubble: play/pause button, waveform with
/// played-portion emphasis, optional tap/drag-to-seek, and a
/// position/duration clock (hidden when [duration] is zero — length
/// metadata is not on the wire for chat attachments today).
class VoiceNotePlayerBar extends StatelessWidget {
  const VoiceNotePlayerBar({
    super.key,
    required this.peaks,
    this.position = Duration.zero,
    required this.duration,
    this.playing = false,
    this.onToggle,
    this.onSeek,
    this.color,
  });

  /// Normalized 0..1 bar heights (see [decorativeWaveformPeaks]).
  final List<double> peaks;

  final Duration position;
  final Duration duration;
  final bool playing;

  /// Play/pause tap. Null renders the button disabled.
  final VoidCallback? onToggle;

  /// Seek to a 0..1 fraction (logical: 0 = start of the note in either
  /// text direction). Null hides the thumb and disables seeking — the app
  /// has no playback-position stream yet, so absence is the honest default.
  final ValueChanged<double>? onSeek;

  /// Waveform + icon color; defaults to the ambient tokens.
  final Color? color;

  double get _playedFraction => duration.inMilliseconds <= 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

  void _seekTo(BuildContext context, double dx, double width) {
    final seek = onSeek;
    if (seek == null || width <= 0) return;
    final fraction = (dx / width).clamp(0.0, 1.0);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    seek(rtl ? 1 - fraction : fraction);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = appTokensOf(context);
    final activeColor = color ?? tokens.onBubbleTheirs;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final seekable = onSeek != null;
    return Row(
      children: [
        Semantics(
          label: playing ? 'Pause voice note' : 'Play voice note',
          button: true,
          child: ExcludeSemantics(
            child: IconButton(
              onPressed: onToggle,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              color: activeColor,
              // Distinct keys per child or the switcher cross-fades nothing.
              icon: AnimatedSwitcher(
                duration: AppMotion.fast,
                switchInCurve: AppMotion.standard,
                switchOutCurve: AppMotion.standard,
                child: playing
                    ? const Icon(
                        Icons.pause_circle_outline,
                        key: ValueKey('voice-pause'),
                      )
                    : const Icon(
                        Icons.play_circle_outline,
                        key: ValueKey('voice-play'),
                      ),
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.s8),
        Expanded(
          child: SizedBox(
            height: 32,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                return GestureDetector(
                  key: voiceNoteWaveformKey,
                  behavior: HitTestBehavior.opaque,
                  onTapUp: seekable
                      ? (details) =>
                          _seekTo(context, details.localPosition.dx, width)
                      : null,
                  onHorizontalDragUpdate: seekable
                      ? (details) =>
                          _seekTo(context, details.localPosition.dx, width)
                      : null,
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _PlayerWaveformPainter(
                        peaks: peaks,
                        playedFraction: _playedFraction,
                        color: activeColor,
                        rtl: rtl,
                        showThumb: seekable,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        if (duration > Duration.zero) ...[
          const SizedBox(width: AppSpacing.s8),
          Text(
            '${voiceClockLabel(position)} / ${voiceClockLabel(duration)}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: activeColor,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}

class _PlayerWaveformPainter extends CustomPainter {
  const _PlayerWaveformPainter({
    required this.peaks,
    required this.playedFraction,
    required this.color,
    required this.rtl,
    required this.showThumb,
  });

  final List<double> peaks;
  final double playedFraction;
  final Color color;
  final bool rtl;
  final bool showThumb;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty || size.width <= 0) return;
    final slots = math.max(1, (size.width / _barPitch).floor());
    final played = Paint()..color = color;
    final rest = Paint()..color = color.withValues(alpha: 0.35);
    for (var i = 0; i < slots; i++) {
      // Resample peaks onto the available slots.
      final peak = peaks[(i * peaks.length) ~/ slots];
      final logicalFraction = (i + 0.5) / slots;
      final x = rtl
          ? size.width - _barPitch * i - _barWidth
          : _barPitch * i;
      final h = math.max(2.0, peak * size.height);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, (size.height - h) / 2, _barWidth, h),
          const Radius.circular(1.5),
        ),
        logicalFraction <= playedFraction ? played : rest,
      );
    }
    if (showThumb) {
      final logicalX = size.width * playedFraction;
      final thumbX = rtl ? size.width - logicalX : logicalX;
      canvas.drawCircle(
        Offset(thumbX.clamp(4.0, size.width - 4.0), size.height / 2),
        4,
        played,
      );
    }
  }

  @override
  bool shouldRepaint(_PlayerWaveformPainter oldDelegate) =>
      oldDelegate.peaks != peaks ||
      oldDelegate.playedFraction != playedFraction ||
      oldDelegate.color != color ||
      oldDelegate.rtl != rtl ||
      oldDelegate.showThumb != showThumb;
}
