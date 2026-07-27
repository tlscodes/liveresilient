/// Chat screen: renders a list of [ChatEntry] (text or attachment) plus an
/// input row. Plain data in, a `send` callback out — no live messenger
/// required, so it is fully widget-testable.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:live_captions/live_captions.dart';
import 'package:messaging/messaging.dart';

import 'theme.dart';

/// A minimal valid 1x1 transparent PNG — real decodable bytes so
/// [Image.memory] never fails, with no network/asset image involved. Shared
/// by the in-app chat demo and widget tests.
final List<int> demoTinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY'
  '42YAAAAASUVORK5CYII=',
);

/// One row in the chat transcript: a [message] and, for a completed
/// attachment transfer, the [attachment] it carries. `attachment == null`
/// means a plain text bubble.
class ChatEntry {
  const ChatEntry({required this.message, this.attachment});

  final ChatMessage message;
  final Attachment? attachment;
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
    this.onPlayAudio,
    this.captions = const [],
    this.captionLanguage = 'en',
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

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
  }

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
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.s12,
                    vertical: Spacing.s8,
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
                    padding: const EdgeInsets.all(Spacing.s12),
                    itemCount: widget.entries.length,
                    itemBuilder: (context, index) {
                      final entry = widget.entries[index];
                      final isMe =
                          entry.message.senderId == widget.localSenderId;
                      return Align(
                        alignment: isMe
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: _Bubble(
                          entry: entry,
                          isMe: isMe,
                          onPlayAudio: widget.onPlayAudio,
                          delivery: widget.deliveryStates[entry.message.id],
                          transferProgress: entry.attachment == null
                              ? null
                              : widget.attachmentProgress[entry.attachment!.id],
                        ),
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(Spacing.s8),
            child: Row(
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
                  const SizedBox(width: Spacing.s4),
                ],
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'Message',
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                const SizedBox(width: Spacing.s8),
                Semantics(
                  label: 'Send message',
                  button: true,
                  child: ExcludeSemantics(
                    child: IconButton.filled(
                      onPressed: _submit,
                      icon: const Icon(Icons.send),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.entry,
    required this.isMe,
    this.delivery,
    this.transferProgress,
    this.onPlayAudio,
  });

  final ChatEntry entry;
  final bool isMe;
  final void Function(Attachment attachment)? onPlayAudio;

  /// Ack outcome for this outbound message; null = still pending.
  final DeliveryState? delivery;

  /// Outbound attachment transfer fraction (0.0 → 1.0); a value < 1.0 shows
  /// a progress bar under the attachment content. Null = not tracked.
  final double? transferProgress;

  /// Marker shown only on my own text bubbles — those are exactly the
  /// entries created by sendText, whose ids the delivery stream reports on.
  bool get _showsMarker => isMe && entry.attachment == null;

  String get _deliveryLabel => switch (delivery) {
    null => 'pending',
    DeliveryState.delivered => 'delivered',
    DeliveryState.failed => 'failed',
  };

  String get _semanticsLabel {
    final who = isMe ? 'You' : entry.message.senderId;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isMe
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    return Semantics(
      label: _semanticsLabel,
      child: ExcludeSemantics(
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          margin: const EdgeInsets.symmetric(vertical: Spacing.s4),
          padding: const EdgeInsets.all(Spacing.s12),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(Spacing.s12),
          ),
          child: _content(context),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final attachment = entry.attachment;
    if (attachment == null) {
      if (!_showsMarker) return Text(entry.message.text);
      final theme = Theme.of(context);
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(child: Text(entry.message.text)),
          const SizedBox(width: Spacing.s4),
          Icon(
            switch (delivery) {
              null => Icons.schedule,
              DeliveryState.delivered => Icons.done,
              DeliveryState.failed => Icons.error_outline,
            },
            size: 14,
            color: delivery == DeliveryState.failed
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
          ),
        ],
      );
    }
    final Widget content;
    switch (attachment.kind) {
      case MediaKind.image:
        content = ClipRRect(
          borderRadius: BorderRadius.circular(Spacing.s8),
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
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.play_circle_outline),
                const SizedBox(width: Spacing.s8),
                Flexible(
                  child: Text(
                    '${voiceAttachmentLabel(attachment)} · '
                    '${formatBytes(attachment.sizeBytes)}',
                    overflow: TextOverflow.ellipsis,
                  ),
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
            ),
            const SizedBox(width: Spacing.s8),
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
        const SizedBox(height: Spacing.s8),
        LinearProgressIndicator(value: progress),
      ],
    );
  }
}
