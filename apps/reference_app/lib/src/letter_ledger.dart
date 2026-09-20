// What was carried: every letter the courier saw arrive, kept as the same
// bytes that left, so the Chats list and its thread show the letter and
// not a log line about it. Pure — no fabric, no I/O, no widget.
import 'dart:convert';

import 'package:flutter/foundation.dart';

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
String letterPreview(LetterRecord record) {
  switch (record.kind) {
    case 'voice':
      final duration = record.duration;
      return duration == null
          ? 'Voice letter · ${record.bytes.length} B'
          : 'Voice letter · ${duration.inSeconds} s';
    case 'photo':
      return 'Thumbnail · ${record.bytes.length} B';
    default:
      try {
        return utf8.decode(record.bytes);
      } on FormatException {
        return '<binary, ${record.bytes.length} B>';
      }
  }
}

/// The Chats row for the letters, or null when none has arrived: an empty
/// ledger puts nothing in the list, so the row never shows before a letter
/// exists to open.
ConversationSummary? letterSummary(List<LetterRecord> records) {
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
