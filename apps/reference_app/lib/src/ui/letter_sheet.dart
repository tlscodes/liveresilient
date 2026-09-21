// The reference app's Send window: the same composer, buttons and
// four-state banner the rig peer shows, hosted as a bottom sheet over the
// conversations screen and carried by [LetterCourier].
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../letter_composer.dart';
import '../letter_courier.dart';
import 'letter_widgets.dart';

/// Text, a voice take of about 30 s, or a thumbnail — carried through the
/// door when the live call is out. The banner at the top is the verdict:
/// live call unavailable, queued, arrived, or not delivered — never a
/// spinner. Send is disabled while a carry is in flight and when nothing
/// is in hand.
class LetterSheet extends StatefulWidget {
  const LetterSheet({super.key, required this.composer, required this.courier});

  final LetterComposer composer;
  final LetterCourier courier;

  @override
  State<LetterSheet> createState() => _LetterSheetState();
}

class _LetterSheetState extends State<LetterSheet> {
  /// "Nothing to send" and friends: a line under the Send button, cleared
  /// on the next act.
  final ValueNotifier<String?> _hint = ValueNotifier<String?>(null);
  late final TextEditingController _draft = TextEditingController(
    text: widget.composer.draft.value,
  );

  @override
  void dispose() {
    _hint.dispose();
    _draft.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final composer = widget.composer;
    _hint.value = null;
    await composer.finalizeRecording();
    await composer.finalizePick();
    await composer.finalizeVideo();
    final (kind, bytes) = phoneLetterChoice(
      video: composer.videoLetter.value,
      voice: composer.voiceLetter.value,
      photo: composer.photoLetter.value,
      draft: composer.draft.value,
      fallback: '',
    );
    if (kind == 'default') {
      _hint.value =
          'Nothing to send yet — type a line, record a voice take, or '
          'choose a thumbnail.';
      return;
    }
    // The take's encoded length rides along for its label in the Chats
    // list ("Voice letter · 12 s"), read before the buttons are cleared.
    final duration = kind == 'voice'
        ? composer.voiceLetter.value?.length
        : null;
    // The buttons belong to the letter that is leaving: a "Recorded 0:12"
    // left behind would read as a take the next letter already holds.
    composer.voiceLetter.value = null;
    composer.photoLetter.value = null;
    composer.videoLetter.value = null;
    composer.recordState.value = VoiceRecordState.idle;
    composer.recordElapsed.value = Duration.zero;
    composer.photoState.value = PhotoPickState.idle;
    composer.videoState.value = VideoRecordState.idle;
    if (kind == 'typed') {
      composer.draft.value = '';
      _draft.clear();
    }
    composer.note('letter chosen: $kind ${bytes.length} B');
    await widget.courier.send(
      Uint8List.fromList(bytes),
      kind: kind,
      duration: duration,
    );
  }

  @override
  Widget build(BuildContext context) {
    final composer = widget.composer;
    final courier = widget.courier;
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Letter through the door',
                key: const Key('letter-sheet-title'),
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                'Text, a voice take of about 30 s, or a thumbnail — carried '
                'over the DNS door when the live call is out.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<LetterStatus?>(
                valueListenable: courier.status,
                builder: (context, value, _) => value == null
                    ? const SizedBox.shrink()
                    : LetterStatusBanner(status: value),
              ),
              TextField(
                key: const Key('letter-sheet-draft'),
                controller: _draft,
                maxLines: 3,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Letter',
                ),
                onChanged: (value) {
                  composer.draft.value = value;
                  _hint.value = null;
                },
                onSubmitted: (_) => unawaited(_send()),
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<VoiceAlert?>(
                valueListenable: composer.voiceAlert,
                builder: (context, alert, _) => alert == null
                    ? const SizedBox.shrink()
                    : LetterAlertBanner(
                        alert: alert,
                        onDismiss: composer.dismissVoiceAlert,
                        keyPrefix: 'letter-sheet-voice',
                        errorIcon: Icons.mic_off,
                      ),
              ),
              ValueListenableBuilder<VoiceAlert?>(
                valueListenable: composer.photoAlert,
                builder: (context, alert, _) => alert == null
                    ? const SizedBox.shrink()
                    : LetterAlertBanner(
                        alert: alert,
                        onDismiss: composer.dismissPhotoAlert,
                        keyPrefix: 'letter-sheet-photo',
                        errorIcon: Icons.broken_image,
                      ),
              ),
              LetterPhotoPreview(composer: composer),
              ValueListenableBuilder<VideoAlert?>(
                valueListenable: composer.videoAlert,
                builder: (context, alert, _) => alert == null
                    ? const SizedBox.shrink()
                    : LetterAlertBanner(
                        alert: alert,
                        onDismiss: composer.dismissVideoAlert,
                        keyPrefix: 'letter-sheet-video',
                        errorIcon: Icons.videocam_off,
                      ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: courier.busy,
                builder: (context, busy, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: LetterRecordButton(
                            composer: composer,
                            enabled: !busy,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: LetterPhotoButton(
                            composer: composer,
                            enabled: !busy,
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Three in one row (2026-09-21): a fourth row
                        // overflowed the screen; the labels ellipsize and
                        // the icons carry the meaning.
                        Expanded(
                          child: LetterVideoButton(
                            composer: composer,
                            enabled: !busy,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 56,
                      child: FilledButton(
                        key: const Key('letter-sheet-send'),
                        onPressed: busy ? null : () => unawaited(_send()),
                        child: Text(busy ? 'Carrying…' : 'Send letter'),
                      ),
                    ),
                  ],
                ),
              ),
              ValueListenableBuilder<String?>(
                valueListenable: _hint,
                builder: (context, hint, _) => hint == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          hint,
                          key: const Key('letter-sheet-hint'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<List<String>>(
                valueListenable: courier.notes,
                builder: (context, lines, _) => lines.isEmpty
                    ? const SizedBox.shrink()
                    : ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 140),
                        child: ListView(
                          key: const Key('letter-sheet-notes'),
                          shrinkWrap: true,
                          reverse: true,
                          children: [
                            for (final line in lines.reversed)
                              Text(
                                line,
                                style: const TextStyle(
                                  fontFamily: 'Menlo',
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
