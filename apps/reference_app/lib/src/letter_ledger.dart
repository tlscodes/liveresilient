// What was carried: every letter the courier saw arrive, kept as the same
// bytes that left, so the Chats list and its thread show the letter and
// not a log line about it. Pure — no fabric, no I/O, no widget.
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'letter_queue.dart' show QueuedLetter;
import 'ui/conversations_screen.dart' show ConversationSummary;
import 'ui/network_truth.dart' show MessageTruthStatus;

/// The conversation id the ledger's row carries in the Chats list.
const String letterConversationId = 'letter';

/// The Chats row's title, the same words the Send window and the app-bar
/// action use.
const String letterConversationTitle = 'Letter through the door';

/// One letter that arrived, exactly as it was carried.
@immutable
class LetterRecord {
  const LetterRecord({
    required this.bytes,
    required this.kind,
    required this.sentAt,
    this.laneId,
    this.sessionId,
    this.duration,
  });

  /// The payload the fabric delivered — the letter itself.
  final Uint8List bytes;

  /// `typed`, `voice` or `photo`: the composer's own names.
  final String kind;

  /// When the fabric reported it sent live.
  final DateTime sentAt;

  /// The lane that ranked first when it was carried, null when none did.
  final String? laneId;

  /// The door's session id when the door carried it, else null.
  final String? sessionId;

  /// The encoded length of a voice take, when the composer knew it.
  final Duration? duration;
}

/// Every delivered letter, newest last. One per courier, one per app.
class LetterLedger {
  final ValueNotifier<List<LetterRecord>> records =
      ValueNotifier<List<LetterRecord>>(const []);

  void add(LetterRecord record) {
    records.value = List<LetterRecord>.unmodifiable([...records.value, record]);
  }

  void dispose() => records.dispose();
}

/// The line a letter shows for itself: the text when it is text, a label
/// for a take or a picture. Strict UTF-8 on purpose — a lenient decode
/// would print an opaque payload as garbage and read as a corrupted letter.
String letterPreview(LetterRecord record) =>
    letterPreviewOf(record.kind, record.bytes, record.duration);

/// [letterPreview] for any letter — a record or one still in the queue.
String letterPreviewOf(String kind, Uint8List bytes, Duration? duration) {
  switch (kind) {
    case 'voice':
      return duration == null
          ? 'Voice letter · ${bytes.length} B'
          : 'Voice letter · ${duration.inSeconds} s';
    case 'photo':
      return 'Thumbnail · ${bytes.length} B';
    default:
      try {
        return utf8.decode(bytes);
      } on FormatException {
        return '<binary, ${bytes.length} B>';
      }
  }
}

/// The Chats row for the letters, or null when there is none: nothing
/// arrived and nothing is parked, so the row never shows before a letter
/// exists to open.
///
/// A letter still in the queue is the newer act and owns the row: its
/// preview and its queued time, with "queued, door down" in the text and
/// NO status badge — the sending badge is a spinner, and a letter parked
/// for hours behind a down door is not "in flight". The courier carries it
/// once, when the door answers again; then the newest arrived record takes
/// the row back with the delivered badge.
ConversationSummary? letterSummary(
  List<LetterRecord> records, {
  List<QueuedLetter> pending = const [],
}) {
  if (pending.isNotEmpty) {
    final parked = pending.last;
    return ConversationSummary(
      id: letterConversationId,
      title: letterConversationTitle,
      lastMessage:
          '${letterPreviewOf(parked.kind, parked.bytes, parked.duration)}'
          ' · queued, door down',
      lastAt: parked.queuedAt,
      avatarSeed: 0xD00E,
      lastIsMine: true,
    );
  }
  if (records.isEmpty) return null;
  final newest = records.last;
  return ConversationSummary(
    id: letterConversationId,
    title: letterConversationTitle,
    lastMessage: letterPreview(newest),
    lastAt: newest.sentAt,
    avatarSeed: 0xD00E,
    lastIsMine: true,
    // sentLive is the fabric's word that a lane took every byte; through
    // the door that is the responder's answer to the last chunk.
    lastStatus: MessageTruthStatus.delivered,
  );
}
