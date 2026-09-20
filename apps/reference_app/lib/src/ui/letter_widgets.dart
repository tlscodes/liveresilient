// The letter's widgets: the four-state verdict banner, the alert banner,
// the Record / Thumbnail buttons and the payload preview. Shared by the
// reference app's letter sheet and the rig peer's Send window.
import 'package:flutter/material.dart';

import '../letter_composer.dart';
import '../photo_letter_picker.dart';

/// The letter's verdict, large and coloured, above the field it judges.
///
/// Four states, four looks, so "still waiting" and "it arrived" can never
/// be told apart by reading a counter: amber while queued, green when it
/// arrived, red when it did not, blue-grey when the live call is out and
/// the door is the way. Keyed so a driver can read the state, not the
/// colour.
class LetterStatusBanner extends StatelessWidget {
  const LetterStatusBanner({super.key, required this.status});

  final LetterStatus status;

  @override
  Widget build(BuildContext context) {
    final (Color tone, IconData icon) = switch (status.state) {
      LetterState.liveCallUnavailable => (
        const Color(0xFF37474F),
        Icons.phone_disabled,
      ),
      LetterState.queued => (const Color(0xFFE65100), Icons.hourglass_top),
      LetterState.arrived => (const Color(0xFF1B5E20), Icons.check_circle),
      LetterState.notDelivered => (const Color(0xFFB71C1C), Icons.error),
    };
    return Container(
      key: Key('journey-peer-letter-state-${status.state.name}'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: tone,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.white, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  letterStateLabel(status.state),
                  key: const Key('journey-peer-letter-state-label'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (status.detail.isNotEmpty)
                  Text(
                    status.detail,
                    key: const Key('journey-peer-letter-state-detail'),
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The one failure surface for authoring a letter — a recording that was
/// refused, a photo that could not be prepared. Large, coloured, in the
/// person's hand next to the button that caused it, and gone only when they
/// tap "Got it": an entry in the scrolling event list below is not something
/// a person mid-task reads.
///
/// One widget, two instances with their own keys and icons, so voice and
/// photo failures can be on screen at the same time without either one
/// silently replacing the other.
class LetterAlertBanner extends StatelessWidget {
  const LetterAlertBanner({
    super.key,
    required this.alert,
    required this.onDismiss,
    required this.keyPrefix,
    required this.errorIcon,
  });

  final VoiceAlert alert;
  final VoidCallback onDismiss;

  /// Names this banner's keys, e.g. `journey-peer-voice` →
  /// `journey-peer-voice-alert`, `…-alert-text`, `…-alert-dismiss`.
  final String keyPrefix;

  /// Drawn when [VoiceAlert.isError]; a success uses the shared check mark.
  final IconData errorIcon;

  @override
  Widget build(BuildContext context) {
    final tone = alert.isError
        ? const Color(0xFFB3261E)
        : const Color(0xFF1B5E20);
    return Container(
      key: Key('$keyPrefix-alert'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tone,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                alert.isError ? errorIcon : Icons.check_circle,
                color: Colors.white,
                size: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  alert.message,
                  key: Key('$keyPrefix-alert-text'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 48,
            child: FilledButton(
              key: Key('$keyPrefix-alert-dismiss'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: tone,
              ),
              onPressed: onDismiss,
              child: const Text('Got it'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Record / Stop, drawn from [LetterComposer.recordState] alone: one look says
/// which of the five states it is in, and the live one counts against the
/// cap so nobody has to guess whether the microphone is open.
class LetterRecordButton extends StatelessWidget {
  const LetterRecordButton({
    super.key,
    required this.composer,
    required this.enabled,
  });

  final LetterComposer composer;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VoiceRecordState>(
      valueListenable: composer.recordState,
      builder: (context, state, _) => ValueListenableBuilder<Duration>(
        valueListenable: composer.recordElapsed,
        builder: (context, elapsed, _) {
          final busy =
              state == VoiceRecordState.starting ||
              state == VoiceRecordState.stopping;
          final live = state == VoiceRecordState.recording;
          final done = state == VoiceRecordState.recorded;
          return SizedBox(
            height: 56,
            child: FilledButton(
              key: const Key('journey-peer-record'),
              style: FilledButton.styleFrom(
                backgroundColor: live
                    ? const Color(0xFFB3261E)
                    : done
                    ? const Color(0xFF1B5E20)
                    : null,
                foregroundColor: live || done ? Colors.white : null,
              ),
              onPressed: enabled && !busy ? composer.toggleRecording : null,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(live ? Icons.stop_circle : Icons.mic, size: 22),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      voiceRecordButtonLabel(state, elapsed),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Choose a photo, drawn from [LetterComposer.photoState] alone — the same
/// one-value rule the Record button follows, so "the picker is open" and
/// "nothing chosen yet" cannot look alike while a 4 MB screenshot is being
/// shrunk on a worker isolate.
class LetterPhotoButton extends StatelessWidget {
  const LetterPhotoButton({
    super.key,
    required this.composer,
    required this.enabled,
  });

  final LetterComposer composer;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PhotoPickState>(
      valueListenable: composer.photoState,
      builder: (context, state, _) => ValueListenableBuilder<PhotoLetter?>(
        valueListenable: composer.photoLetter,
        builder: (context, letter, _) {
          final busy =
              state == PhotoPickState.picking ||
              state == PhotoPickState.shrinking;
          final done = state == PhotoPickState.picked;
          return SizedBox(
            height: 56,
            child: FilledButton(
              key: const Key('journey-peer-photo'),
              style: FilledButton.styleFrom(
                backgroundColor: done ? const Color(0xFF1B5E20) : null,
                foregroundColor: done ? Colors.white : null,
              ),
              onPressed: enabled && !busy ? composer.pickPhoto : null,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    done ? Icons.image : Icons.add_photo_alternate,
                    size: 22,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      photoPickButtonLabel(state, letter),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The picture itself, decoded from the very bytes that will ride the lane.
///
/// Not a re-render of the original file: a preview drawn from the source
/// would show a sharp photo and carry a smudge, and nobody would know until
/// it arrived on the Mac. What is on screen here is the payload.

class LetterPhotoPreview extends StatelessWidget {
  const LetterPhotoPreview({super.key, required this.composer});

  final LetterComposer composer;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PhotoLetter?>(
      valueListenable: composer.photoLetter,
      builder: (context, letter, _) {
        if (letter == null) return const SizedBox.shrink();
        return Container(
          key: const Key('journey-peer-photo-preview'),
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF1B5E20),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  letter.wire,
                  height: 72,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'A thumbnail goes when you tap Send, not the full '
                  'picture.\n'
                  '${photoLetterSize(letter.wire.length)} · '
                  '${letter.width}×${letter.height} · quality '
                  '${letter.quality}, from '
                  '${photoLetterSize(letter.sourceBytes)}',
                  key: const Key('journey-peer-photo-preview-text'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
