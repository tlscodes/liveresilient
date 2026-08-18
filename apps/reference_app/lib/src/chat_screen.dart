/// Chat screen: renders a list of [ChatEntry] (text, attachment, or staged
/// photo) plus an input row. Plain data in, callbacks out — no live
/// messenger required, so it is fully widget-testable.
///
/// Visual system (2026-08-10 restyle): bubbles, ticks and the composer are
/// built on the token design system in `ui/tokens.dart`. Rendering rules the
/// tests rely on:
///  * One-shot entrance animation runs ONLY for entries that appear after
///    the first build; the initial transcript renders settled.
///  * Cross-fades (tick swaps, photo rung swaps) run only while
///    [AppMotion.ambientEnabled] — under `flutter test` state changes land
///    in a single frame, exactly as the pre-existing tests pin them.
///  * All geometry is directional (start/end), so Persian RTL flips the
///    bubble tails and waveforms without any per-side code.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:live_captions/live_captions.dart';
import 'package:messaging/messaging.dart';

import 'photo_source.dart';
import 'theme.dart';
import 'ui/voice_note.dart';

/// A minimal valid 1x1 transparent PNG — real decodable bytes so
/// [Image.memory] never fails, with no network/asset image involved. Shared
/// by the in-app chat demo and widget tests.
final List<int> demoTinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY'
  '42YAAAAASUVORK5CYII=',
);

/// One row in the chat transcript: a [message] plus at most one payload —
/// a completed [attachment], or a staged photo referenced by [photoId]
/// (whose ladder state lives in the screen's photo maps). Both null means
/// a plain text bubble.
class ChatEntry {
  const ChatEntry({required this.message, this.attachment, this.photoId});

  final ChatMessage message;
  final Attachment? attachment;
  final String? photoId;
}

/// Sender-side staged-photo status backing my own photo bubble (the
/// controller owns and mutates it; the screen only renders).
class OutgoingPhotoStatus {
  OutgoingPhotoStatus(this.photoId, this.displayBytes);

  final String photoId;

  /// The capped wire original — always renderable locally.
  final Uint8List displayBytes;

  /// The rung currently in flight on the sender side.
  PhotoStage stage = PhotoStage.announced;

  /// True once the receiver's DONE landed — the lane only sends DONE after
  /// its own sha check, so done == remotely verified.
  bool done = false;

  bool failed = false;

  /// True when the lane answered from the receiver's held bytes (repeat
  /// send of the same photo).
  bool deduplicated = false;
}

/// Formats [sizeBytes] as a short human string, e.g. `12.3 KB`.
String formatBytes(int sizeBytes) {
  if (sizeBytes < 1024) return '$sizeBytes B';
  final kb = sizeBytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  return '${(kb / 1024).toStringAsFixed(1)} MB';
}

/// Whether [attachment] is playable voice audio (a degraded-mode voice
/// note or a recovered gap replay).
bool isVoiceAttachment(Attachment attachment) =>
    attachment.contentType.startsWith('audio/');

/// Human label for a voice attachment bubble.
String voiceAttachmentLabel(Attachment attachment) =>
    attachment.contentType == 'audio/replay'
    ? 'Recovered audio — the part that was cut off'
    : 'Voice note';

/// True when the entry at [index] continues a run of consecutive messages
/// from the same sender (pure grouping logic, unit-tested).
bool chatEntryContinuesGroup(List<ChatEntry> entries, int index) =>
    index > 0 &&
    entries[index - 1].message.senderId == entries[index].message.senderId;

/// Vertical gap above a bubble row: tight inside a same-sender group, a
/// full step between groups, none above the first row.
double chatBubbleGapAbove({
  required bool continuesGroup,
  required bool isFirst,
}) {
  if (isFirst) return 0;
  return continuesGroup ? AppSpacing.s2 : AppSpacing.s8;
}

/// Bubble corner rounding: large [AppRadius.bubble] corners with the tail
/// corner ([AppRadius.bubbleTail]) on the sender side, and the adjacent
/// corner squared when the bubble continues a group. Directional, so the
/// tail flips automatically in RTL.
BorderRadiusDirectional chatBubbleRadius({
  required bool isMe,
  required bool continuesGroup,
}) {
  const big = Radius.circular(AppRadius.bubble);
  const small = Radius.circular(AppRadius.bubbleTail);
  if (isMe) {
    return BorderRadiusDirectional.only(
      topStart: big,
      topEnd: continuesGroup ? small : big,
      bottomStart: big,
      bottomEnd: small,
    );
  }
  return BorderRadiusDirectional.only(
    topStart: continuesGroup ? small : big,
    topEnd: big,
    bottomStart: small,
    bottomEnd: big,
  );
}

/// Cross-fades [child] swaps only while ambient animation is enabled.
///
/// The pre-existing tests pin single-frame state changes (a tick or photo
/// rung must be fully replaced on the very next pump), so under
/// `flutter test` the swap is instant; the running app gets the fade.
Widget _softSwap({required Widget child, Duration duration = AppMotion.fast}) {
  if (!AppMotion.ambientEnabled) return child;
  return AnimatedSwitcher(
    duration: duration,
    switchInCurve: AppMotion.standard,
    switchOutCurve: AppMotion.standard,
    child: child,
  );
}

/// A scrollable transcript of [entries] plus a text-input row.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.entries,
    required this.localSenderId,
    required this.onSend,
    this.deliveryStates = const {},
    this.attachmentProgress = const {},
    this.onPickAttachment,
    this.onSendPhoto,
    this.outgoingPhotos = const {},
    this.incomingPhotos = const {},
    this.onPlayAudio,
    this.captions = const [],
    this.captionLanguage = 'en',
    this.amplitudeSource,
    this.onSendVoiceNote,
    this.onSeekAudio,
  });

  /// Live captions to show in the strip above the transcript (empty hides
  /// the strip). Each is rendered via [Caption.textFor] in
  /// [captionLanguage].
  final List<Caption> captions;

  /// Viewer language for the caption strip.
  final String captionLanguage;

  /// Invoked when the user taps the attach button; the owner runs its
  /// injected picker and starts the transfer. Null hides the button.
  final VoidCallback? onPickAttachment;

  /// Invoked with the chosen source after the user picks one from the
  /// photo sheet; the owner captures, encodes, and delivers the staged
  /// photo. Null hides the photo button.
  final Future<void> Function(PhotoSource source)? onSendPhoto;

  /// Sender-side staged photo status by photoId (my bubbles).
  final Map<String, OutgoingPhotoStatus> outgoingPhotos;

  /// Receiver-side staged photo ladder by photoId (peer bubbles).
  final Map<String, StagedPhotoState> incomingPhotos;

  /// Invoked when the user taps a voice bubble (voice note / recovered
  /// audio); the owner decodes and plays the bytes through the platform
  /// audio output. Null renders voice bubbles without a play affordance.
  final void Function(Attachment attachment)? onPlayAudio;

  /// The full transcript, oldest first.
  final List<ChatEntry> entries;

  /// Delivery outcome per outbound message id, fed from the messenger's
  /// `deliveries` stream. An outbound text bubble whose id is absent here is
  /// still pending (sent, not yet acknowledged).
  final Map<String, DeliveryState> deliveryStates;

  /// Outbound transfer progress per attachment id, 0.0 → 1.0. While an
  /// attachment's fraction is present and < 1.0 its bubble shows a
  /// determinate progress bar.
  final Map<String, double> attachmentProgress;

  /// Sender id treated as "me" — determines bubble alignment.
  final String localSenderId;

  /// Invoked with the typed text when the user taps send. Empty input never
  /// triggers this.
  final ValueChanged<String> onSend;

  /// Live 0..1 microphone amplitude for the voice-note recorder. Null (the
  /// default) hides the mic affordance entirely — today's render is
  /// unchanged. Real capture wiring is a dated blocker (2026-08-10); the
  /// demo injects a synthetic envelope.
  final Stream<double>? amplitudeSource;

  /// Invoked with the recorded length when the user finishes a voice-note
  /// recording. Null disables finishing a recording into a send.
  final Future<void> Function(Duration length)? onSendVoiceNote;

  /// Seek handler for voice-note playback (0..1 fraction). The app has no
  /// playback-position stream yet, so null (the default) hides the scrub
  /// thumb and keeps the waveform non-interactive.
  final ValueChanged<double>? onSeekAudio;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  /// Message ids ever handed to this screen. Seeded with the FIRST build's
  /// entries so the initial transcript never animates (pumpAndSettle and
  /// scroll-jank budget); only later arrivals get an entrance.
  late final Set<String> _seenMessageIds = {
    for (final entry in widget.entries) entry.message.id,
  };

  /// Ids whose rows entered after first build — they keep their entrance
  /// wrapper across rebuilds so the one-shot animation completes.
  final Set<String> _entranceIds = {};

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          if (widget.captions.isNotEmpty)
            Semantics(
              label: 'Live captions',
              child: ExcludeSemantics(
                child: Container(
                  width: double.infinity,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  padding: const EdgeInsetsDirectional.symmetric(
                    horizontal: AppSpacing.s12,
                    vertical: AppSpacing.s8,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Last two caption lines: current + one of context.
                      for (final caption
                          in widget.captions.length <= 2
                              ? widget.captions
                              : widget.captions.sublist(
                                  widget.captions.length - 2,
                                ))
                        // Interim (not-yet-final) speech renders italic
                        // with a trailing ellipsis — the standard live-
                        // caption cue that the line is still forming.
                        Text(
                          caption.segment.isFinal
                              ? caption.textFor(widget.captionLanguage)
                              : '${caption.textFor(widget.captionLanguage)}…',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: caption.segment.isFinal
                              ? Theme.of(context).textTheme.bodySmall
                              : Theme.of(context).textTheme.bodySmall?.copyWith(
                                  fontStyle: FontStyle.italic,
                                ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: widget.entries.isEmpty
                ? Center(
                    child: Text(
                      'No messages yet',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsetsDirectional.all(AppSpacing.s12),
                    itemCount: widget.entries.length,
                    itemBuilder: (context, index) => _buildRow(context, index),
                  ),
          ),
          const Divider(height: 1),
          _Composer(
            onSend: widget.onSend,
            onPickAttachment: widget.onPickAttachment,
            onSendPhoto: widget.onSendPhoto,
            amplitudeSource: widget.amplitudeSource,
            onSendVoiceNote: widget.onSendVoiceNote,
          ),
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, int index) {
    final entry = widget.entries[index];
    final isMe = entry.message.senderId == widget.localSenderId;
    final photoId = entry.photoId;
    final id = entry.message.id;
    final continuesGroup = chatEntryContinuesGroup(widget.entries, index);
    if (!_seenMessageIds.contains(id)) {
      _seenMessageIds.add(id);
      _entranceIds.add(id);
    }
    final row = Padding(
      padding: EdgeInsetsDirectional.only(
        top: chatBubbleGapAbove(
          continuesGroup: continuesGroup,
          isFirst: index == 0,
        ),
      ),
      child: Align(
        alignment: isMe
            ? AlignmentDirectional.centerEnd
            : AlignmentDirectional.centerStart,
        child: RepaintBoundary(
          child: _Bubble(
            entry: entry,
            isMe: isMe,
            continuesGroup: continuesGroup,
            onPlayAudio: widget.onPlayAudio,
            onSeekAudio: widget.onSeekAudio,
            delivery: widget.deliveryStates[entry.message.id],
            transferProgress: entry.attachment == null
                ? null
                : widget.attachmentProgress[entry.attachment!.id],
            // Direction-gated: one photoId exists in BOTH maps
            // (sender status + receiver ladder); the bubble's
            // side decides which one it renders.
            outgoingPhoto: photoId == null || !isMe
                ? null
                : widget.outgoingPhotos[photoId],
            incomingPhoto: photoId == null || isMe
                ? null
                : widget.incomingPhotos[photoId],
          ),
        ),
      ),
    );
    if (_entranceIds.contains(id)) {
      return _BubbleEntrance(key: ValueKey('bubble-entrance-$id'), child: row);
    }
    return KeyedSubtree(key: ValueKey('bubble-$id'), child: row);
  }
}

/// One-shot entrance for a newly arrived bubble: 8dp rise + fade over
/// [AppMotion.base]. Semantics are always included so a bubble is
/// discoverable on its very first frame (tests read labels mid-flight).
class _BubbleEntrance extends StatelessWidget {
  const _BubbleEntrance({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.base,
      curve: AppMotion.standard,
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        alwaysIncludeSemantics: true,
        child: Transform.translate(
          offset: Offset(0, AppSpacing.s8 * (1 - t)),
          child: child,
        ),
      ),
    );
  }
}

/// The input row: attach/photo buttons, pill text field, and a trailing
/// button that morphs between mic (voice) and send by text-empty state.
/// While recording, the whole row is replaced by the recorder overlay.
class _Composer extends StatefulWidget {
  const _Composer({
    required this.onSend,
    this.onPickAttachment,
    this.onSendPhoto,
    this.amplitudeSource,
    this.onSendVoiceNote,
  });

  final ValueChanged<String> onSend;
  final VoidCallback? onPickAttachment;
  final Future<void> Function(PhotoSource source)? onSendPhoto;
  final Stream<double>? amplitudeSource;
  final Future<void> Function(Duration length)? onSendVoiceNote;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _controller = TextEditingController();

  bool _recording = false;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;
  bool _cancelArmed = false;
  double _cancelDrag = 0;

  @override
  void dispose() {
    _stopTicker();
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
  }

  Future<void> _pickPhotoSource() async {
    final onSendPhoto = widget.onSendPhoto;
    if (onSendPhoto == null) return;
    final source = await showModalBottomSheet<PhotoSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photo library'),
              onTap: () => Navigator.pop(context, PhotoSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(context, PhotoSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source != null) {
      await onSendPhoto(source);
    }
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _startRecording() {
    AppHaptics.medium();
    setState(() {
      _recording = true;
      _elapsed = Duration.zero;
      _cancelArmed = false;
      _cancelDrag = 0;
    });
    // Whole-second ticks; only this composer subtree rebuilds.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _elapsed += const Duration(seconds: 1));
    });
  }

  void _cancelRecording() {
    AppHaptics.warning();
    _stopTicker();
    setState(() {
      _recording = false;
      _cancelArmed = false;
      _cancelDrag = 0;
    });
  }

  void _finishRecording() {
    _stopTicker();
    final length = _elapsed;
    setState(() {
      _recording = false;
      _cancelArmed = false;
      _cancelDrag = 0;
    });
    final send = widget.onSendVoiceNote;
    if (send != null) {
      AppHaptics.light();
      unawaited(send(length));
    }
  }

  void _onCancelDragUpdate(DragUpdateDetails details) {
    _cancelDrag += details.delta.dx;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    // Slide toward the line start commits the cancel.
    final armed = rtl ? _cancelDrag > 64 : _cancelDrag < -64;
    if (armed != _cancelArmed) {
      if (armed) AppHaptics.warning();
      setState(() => _cancelArmed = armed);
    }
  }

  void _onCancelDragEnd(DragEndDetails details) {
    if (_cancelArmed) {
      _cancelRecording();
    } else {
      _cancelDrag = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = appTokensOf(context);
    return Container(
      color: tokens.surfaceGlass,
      padding: const EdgeInsetsDirectional.all(AppSpacing.s8),
      child: _recording ? _buildRecordingRow(context) : _buildComposeRow(),
    );
  }

  Widget _buildRecordingRow(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            onHorizontalDragUpdate: _onCancelDragUpdate,
            onHorizontalDragEnd: _onCancelDragEnd,
            child: VoiceNoteRecorderOverlay(
              amplitude: widget.amplitudeSource!,
              elapsed: _elapsed,
              cancelArmed: _cancelArmed,
              onCancel: _cancelRecording,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.s8),
        Semantics(
          label: 'Send voice note',
          button: true,
          child: ExcludeSemantics(
            child: IconButton.filled(
              onPressed: _finishRecording,
              icon: const Icon(Icons.send),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildComposeRow() {
    return Row(
      children: [
        if (widget.onPickAttachment != null) ...[
          Semantics(
            label: 'Attach file',
            button: true,
            child: ExcludeSemantics(
              child: IconButton(
                onPressed: widget.onPickAttachment,
                icon: const Icon(Icons.attach_file),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.s4),
        ],
        if (widget.onSendPhoto != null) ...[
          Semantics(
            label: 'Send photo',
            button: true,
            child: ExcludeSemantics(
              child: IconButton(
                onPressed: () => _pickPhotoSource(),
                icon: const Icon(Icons.photo_camera_outlined),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.s4),
        ],
        Expanded(
          child: TextField(
            controller: _controller,
            // Pill shape and fill come from the app InputDecorationTheme.
            decoration: const InputDecoration(hintText: 'Message'),
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _submit(),
          ),
        ),
        const SizedBox(width: AppSpacing.s8),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, _) {
            final showMic =
                widget.amplitudeSource != null && value.text.trim().isEmpty;
            return AnimatedSwitcher(
              duration: AppMotion.fast,
              switchInCurve: AppMotion.standard,
              switchOutCurve: AppMotion.standard,
              child: showMic
                  ? Semantics(
                      key: const ValueKey('composer-mic'),
                      label: 'Record voice note',
                      button: true,
                      child: ExcludeSemantics(
                        child: IconButton.filled(
                          onPressed: _startRecording,
                          icon: const Icon(Icons.mic),
                        ),
                      ),
                    )
                  : Semantics(
                      key: const ValueKey('composer-send'),
                      label: 'Send message',
                      button: true,
                      child: ExcludeSemantics(
                        child: IconButton.filled(
                          onPressed: _submit,
                          icon: const Icon(Icons.send),
                        ),
                      ),
                    ),
            );
          },
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.entry,
    required this.isMe,
    this.continuesGroup = false,
    this.delivery,
    this.transferProgress,
    this.onPlayAudio,
    this.onSeekAudio,
    this.outgoingPhoto,
    this.incomingPhoto,
  });

  final ChatEntry entry;
  final bool isMe;

  /// True when the previous transcript entry has the same sender (squares
  /// the adjacent corner).
  final bool continuesGroup;

  final void Function(Attachment attachment)? onPlayAudio;

  /// Voice playback seek (0..1); null hides the scrub thumb.
  final ValueChanged<double>? onSeekAudio;

  /// Ack outcome for this outbound message; null = still pending.
  final DeliveryState? delivery;

  /// Outbound attachment transfer fraction (0.0 → 1.0); a value < 1.0 shows
  /// a progress bar under the attachment content. Null = not tracked.
  final double? transferProgress;

  /// Staged-photo data sources; at most one is non-null per bubble.
  final OutgoingPhotoStatus? outgoingPhoto;
  final StagedPhotoState? incomingPhoto;

  /// Marker shown only on my own text bubbles — those are exactly the
  /// entries created by sendText, whose ids the delivery stream reports on.
  /// A visible text entry exists only after its frame was written, so the
  /// honest floor is "sent/pending", never an invented "sending" state.
  bool get _showsMarker =>
      isMe && entry.attachment == null && entry.photoId == null;

  String get _deliveryLabel => switch (delivery) {
    null => 'pending',
    DeliveryState.delivered => 'delivered',
    DeliveryState.failed => 'failed',
  };

  String get _outgoingPhotoLabel {
    final out = outgoingPhoto!;
    if (out.failed) return 'send failed';
    if (out.done) {
      return out.deduplicated
          ? 'delivered instantly — already held'
          : 'delivered · sha verified';
    }
    return switch (out.stage) {
      PhotoStage.announced => 'announcing…',
      PhotoStage.previewReady => 'sending preview…',
      PhotoStage.originalVerified => 'sending original…',
    };
  }

  String get _incomingPhotoLabel => switch (incomingPhoto!.stage) {
    PhotoStage.announced => 'blurred preview — receiving…',
    PhotoStage.previewReady => 'preview — receiving original…',
    PhotoStage.originalVerified => 'sha verified',
  };

  String get _semanticsLabel {
    final who = isMe ? 'You' : entry.message.senderId;
    if (outgoingPhoto != null) {
      return 'Photo from $who — $_outgoingPhotoLabel';
    }
    if (incomingPhoto != null) {
      return 'Photo from $who — $_incomingPhotoLabel';
    }
    final attachment = entry.attachment;
    if (attachment == null) {
      final marker = _showsMarker ? ', $_deliveryLabel' : '';
      return '$who: ${entry.message.text}$marker';
    }
    switch (attachment.kind) {
      case MediaKind.image:
        return 'Photo attachment from $who';
      case MediaKind.video:
        return 'Video attachment from $who, ${formatBytes(attachment.sizeBytes)}';
      case MediaKind.file:
        if (isVoiceAttachment(attachment)) {
          return '${voiceAttachmentLabel(attachment)} from $who, '
              'double tap to play';
        }
        return 'File attachment from $who, ${attachment.contentType}, '
            '${formatBytes(attachment.sizeBytes)}';
    }
  }

  bool get _isMediaBubble => entry.attachment != null || entry.photoId != null;

  @override
  Widget build(BuildContext context) {
    final tokens = appTokensOf(context);
    final fill = isMe ? tokens.bubbleMine : tokens.bubbleTheirs;
    final foreground = isMe ? tokens.onBubbleMine : tokens.onBubbleTheirs;
    return Semantics(
      label: _semanticsLabel,
      child: ExcludeSemantics(
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.78,
          ),
          padding: _isMediaBubble
              ? const EdgeInsetsDirectional.all(AppSpacing.s8)
              : const EdgeInsetsDirectional.symmetric(
                  horizontal: AppSpacing.s16,
                  vertical: AppSpacing.s12,
                ),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: chatBubbleRadius(
              isMe: isMe,
              continuesGroup: continuesGroup,
            ),
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: foreground),
            child: _content(context, foreground),
          ),
        ),
      ),
    );
  }

  /// The delivery tick for my own text bubbles. Icons and their meanings
  /// are pinned by the pre-existing tests (schedule/done/error_outline);
  /// the restyle recolors them from tokens and keeps that exact vocabulary.
  Widget _deliveryTick(BuildContext context, Color foreground) {
    final tokens = appTokensOf(context);
    return _softSwap(
      child: Icon(
        switch (delivery) {
          null => Icons.schedule,
          DeliveryState.delivered => Icons.done,
          DeliveryState.failed => Icons.error_outline,
        },
        key: ValueKey('tick-$_deliveryLabel'),
        size: 14,
        color: delivery == DeliveryState.failed
            ? tokens.danger
            : foreground.withValues(alpha: 0.8),
      ),
    );
  }

  Widget _content(BuildContext context, Color foreground) {
    if (entry.photoId != null) return _stagedPhotoContent(context, foreground);
    final attachment = entry.attachment;
    if (attachment == null) {
      if (!_showsMarker) return Text(entry.message.text);
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(child: Text(entry.message.text)),
          const SizedBox(width: AppSpacing.s4),
          _deliveryTick(context, foreground),
        ],
      );
    }
    final Widget content;
    switch (attachment.kind) {
      case MediaKind.image:
        content = ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.r12),
          child: Image.memory(
            Uint8List.fromList(attachment.bytes),
            width: 160,
            height: 120,
            fit: BoxFit.cover,
          ),
        );
      case MediaKind.video:
      case MediaKind.file:
        if (isVoiceAttachment(attachment)) {
          content = InkWell(
            onTap: onPlayAudio == null ? null : () => onPlayAudio!(attachment),
            borderRadius: BorderRadius.circular(AppRadius.r12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                VoiceNotePlayerBar(
                  peaks: decorativeWaveformPeaks(attachment.bytes),
                  // No length metadata on the wire yet — zero hides the
                  // clock instead of inventing a duration.
                  duration: Duration.zero,
                  onToggle: onPlayAudio == null
                      ? null
                      : () => onPlayAudio!(attachment),
                  onSeek: onSeekAudio,
                  color: foreground,
                ),
                const SizedBox(height: AppSpacing.s4),
                Text(
                  '${voiceAttachmentLabel(attachment)} · '
                  '${formatBytes(attachment.sizeBytes)}',
                  style: Theme.of(context).textTheme.labelSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          );
          break;
        }
        content = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              attachment.kind == MediaKind.video
                  ? Icons.videocam
                  : Icons.insert_drive_file,
              color: foreground,
            ),
            const SizedBox(width: AppSpacing.s8),
            Flexible(
              child: Text(
                '${attachment.contentType} · '
                '${formatBytes(attachment.sizeBytes)}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        );
    }
    final progress = transferProgress;
    if (progress == null || progress >= 1.0) return content;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        content,
        const SizedBox(height: AppSpacing.s8),
        _progressBar(context, value: progress),
      ],
    );
  }

  /// Progress rail styled from tokens: primary on a soft outline track.
  /// A null [value] means "climbing, fraction unknown" — that indeterminate
  /// sweep repeats, so under tests it renders as a static partial fill
  /// (the ambient gate), keeping every `pumpAndSettle` site settled.
  Widget _progressBar(BuildContext context, {double? value}) {
    final tokens = appTokensOf(context);
    return LinearProgressIndicator(
      value: value ?? (AppMotion.ambientEnabled ? null : 1 / 3),
      minHeight: 3,
      color: Theme.of(context).colorScheme.primary,
      backgroundColor: tokens.outlineSoft,
      borderRadius: BorderRadius.circular(1.5),
    );
  }

  /// The staged bubble: rung image + progress while climbing + a caption
  /// row whose verified pill appears only after the sha check.
  Widget _stagedPhotoContent(BuildContext context, Color foreground) {
    final theme = Theme.of(context);
    final tokens = appTokensOf(context);
    final out = outgoingPhoto;
    final inc = incomingPhoto;

    Widget image;
    String caption;
    bool climbing;
    bool verified;

    if (out != null) {
      image = ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.r12),
        child: Image.memory(
          out.displayBytes,
          width: 160,
          height: 120,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
      caption = _outgoingPhotoLabel;
      climbing = !out.done && !out.failed;
      verified = out.done;
    } else if (inc != null) {
      final preview = inc.preview;
      final original = inc.original;
      // Announced blur → preview → original cross-fade (ambient-gated: the
      // pre-existing ladder tests pin each rung on the very next frame).
      final Widget rung;
      if (original != null) {
        rung = ClipRRect(
          key: const ValueKey('rung-original'),
          borderRadius: BorderRadius.circular(AppRadius.r12),
          child: Image.memory(
            original,
            width: 160,
            height: 120,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
        );
      } else if (preview != null) {
        rung = ClipRRect(
          key: const ValueKey('rung-preview'),
          borderRadius: BorderRadius.circular(AppRadius.r12),
          child: Image.memory(
            preview,
            width: 160,
            height: 120,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
        );
      } else {
        rung = ClipRRect(
          key: const ValueKey('rung-thumb'),
          borderRadius: BorderRadius.circular(AppRadius.r12),
          child: ThumbHashPlaceholder(
            hash: inc.announcement.thumbHash,
            width: 160,
            height: 120,
          ),
        );
      }
      image = _softSwap(duration: AppMotion.gentle, child: rung);
      caption = _incomingPhotoLabel;
      climbing = inc.stage != PhotoStage.originalVerified;
      verified = inc.sha256Verified;
    } else {
      // Announced on the wire but no ladder state yet (first frame racing
      // the maps): a quiet placeholder box, upgraded on the next rebuild.
      return const SizedBox(width: 160, height: 120);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        image,
        if (climbing) ...[
          const SizedBox(height: AppSpacing.s8),
          _progressBar(context),
        ],
        const SizedBox(height: AppSpacing.s4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (verified)
              Flexible(
                child: Container(
                  padding: const EdgeInsetsDirectional.symmetric(
                    horizontal: AppSpacing.s8,
                    vertical: AppSpacing.s2,
                  ),
                  decoration: BoxDecoration(
                    color: tokens.verified,
                    borderRadius: BorderRadius.circular(AppRadius.r12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Icon pinned by the pre-existing sha tests.
                      Icon(
                        Icons.verified_outlined,
                        size: 12,
                        color: tokens.onVerified,
                      ),
                      const SizedBox(width: AppSpacing.s4),
                      Flexible(
                        child: Text(
                          caption,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: tokens.onVerified,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              Flexible(
                child: Text(
                  caption,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: foreground.withValues(alpha: 0.85),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Renders a [ThumbHash] as a blurred placeholder image — the rung-0
/// visual. Decoding is a pure-math rasterization into RGBA followed by an
/// async [ui.Image] upload; until it lands, a plain surface holds the box.
class ThumbHashPlaceholder extends StatefulWidget {
  const ThumbHashPlaceholder({
    super.key,
    required this.hash,
    required this.width,
    required this.height,
  });

  final Uint8List hash;
  final double width;
  final double height;

  @override
  State<ThumbHashPlaceholder> createState() => _ThumbHashPlaceholderState();
}

class _ThumbHashPlaceholderState extends State<ThumbHashPlaceholder> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  void _decode() {
    try {
      final t = ThumbHash.decodeToRgba(widget.hash);
      ui.decodeImageFromPixels(
        t.rgba,
        t.width,
        t.height,
        ui.PixelFormat.rgba8888,
        (image) {
          if (mounted) {
            setState(() => _image = image);
          } else {
            image.dispose();
          }
        },
      );
    } on ArgumentError {
      // A corrupt hash renders as the plain surface — never a crash.
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) {
      return Container(
        width: widget.width,
        height: widget.height,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      );
    }
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: image.width.toDouble(),
          height: image.height.toDouble(),
          child: RawImage(image: image, filterQuality: FilterQuality.low),
        ),
      ),
    );
  }
}
