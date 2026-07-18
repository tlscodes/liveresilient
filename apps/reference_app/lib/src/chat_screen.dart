/// Chat screen: renders a list of [ChatEntry] (text or attachment) plus an
/// input row. Plain data in, a `send` callback out — no live messenger
/// required, so it is fully widget-testable.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
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

/// A scrollable transcript of [entries] plus a text-input row.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.entries,
    required this.localSenderId,
    required this.onSend,
  });

  /// The full transcript, oldest first.
  final List<ChatEntry> entries;

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
                        child: _Bubble(entry: entry, isMe: isMe),
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(Spacing.s8),
            child: Row(
              children: [
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
  const _Bubble({required this.entry, required this.isMe});

  final ChatEntry entry;
  final bool isMe;

  String get _semanticsLabel {
    final who = isMe ? 'You' : entry.message.senderId;
    final attachment = entry.attachment;
    if (attachment == null) {
      return '$who: ${entry.message.text}';
    }
    switch (attachment.kind) {
      case MediaKind.image:
        return 'Photo attachment from $who';
      case MediaKind.video:
        return 'Video attachment from $who, ${formatBytes(attachment.sizeBytes)}';
      case MediaKind.file:
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
      return Text(entry.message.text);
    }
    switch (attachment.kind) {
      case MediaKind.image:
        return ClipRRect(
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
        return Row(
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
  }
}
