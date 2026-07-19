import 'dart:async';
import 'dart:convert';

import 'package:messaging/messaging.dart';

import 'caption.dart';
import 'transcript_segment.dart';

/// JSON text-frame codec so captions ride the same [ReliableMessenger] the
/// chat and attachment chunks use. Mirrors `AttachmentChunk`'s discipline:
/// self-describing `'t'` tag, strict type checks, and hard size caps so a
/// hostile peer cannot inflate memory through the caption path.
class CaptionFrame {
  /// Hard cap on original/translated text length, checked on decode.
  static const int maxTextChars = 4096;

  /// Hard cap on the number of carried translations, checked on decode.
  static const int maxTranslations = 16;

  static String encode(Caption caption) => jsonEncode({
    't': 'caption',
    'id': caption.segment.id,
    'seq': caption.segment.seq,
    'lang': caption.segment.lang,
    'text': caption.segment.text,
    'fin': caption.segment.isFinal,
    'start': caption.segment.startMs,
    'tr': caption.translations,
    'fl': caption.failedLanguages.toList(),
  });

  /// Decodes a caption frame, or null if [text] is not one (plain chat, an
  /// attachment chunk, or malformed/hostile input).
  static Caption? tryDecode(String text) {
    try {
      final obj = jsonDecode(text);
      if (obj is! Map || obj['t'] != 'caption') return null;
      final id = obj['id'];
      final seq = obj['seq'];
      final lang = obj['lang'];
      final body = obj['text'];
      final fin = obj['fin'];
      final start = obj['start'];
      final tr = obj['tr'];
      final fl = obj['fl'];
      if (id is! String || id.isEmpty) return null;
      if (seq is! int || seq < 0) return null;
      if (lang is! String || lang.isEmpty) return null;
      if (body is! String || body.length > maxTextChars) return null;
      if (fin is! bool) return null;
      if (start is! int || start < 0) return null;
      if (tr is! Map || tr.length > maxTranslations) return null;
      final translations = <String, String>{};
      for (final entry in tr.entries) {
        final k = entry.key;
        final v = entry.value;
        if (k is! String || k.isEmpty) return null;
        if (v is! String || v.length > maxTextChars) return null;
        translations[k] = v;
      }
      if (fl is! List || fl.length > maxTranslations) return null;
      final failed = <String>{};
      for (final f in fl) {
        if (f is! String || f.isEmpty) return null;
        failed.add(f);
      }
      return Caption(
        segment: TranscriptSegment(
          id: id,
          seq: seq,
          lang: lang,
          text: body,
          isFinal: fin,
          startMs: start,
        ),
        translations: translations,
        failedLanguages: failed,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Sends one caption over an existing [ReliableMessenger] — same reliable
/// delivery/ack path the chat text uses.
Future<void> sendCaption(ReliableMessenger messenger, Caption caption) async {
  await messenger.send(CaptionFrame.encode(caption));
}

/// Consumes incoming chat text: routes caption frames to [received] and
/// leaves everything else to the caller (attachment chunks, plain chat).
class CaptionReceiver {
  final _received = StreamController<Caption>.broadcast();

  /// Captions decoded off the wire, in arrival order.
  Stream<Caption> get received => _received.stream;

  /// Offers one incoming text. Returns true if it was a caption frame
  /// (consumed here), false if the caller should keep routing it.
  bool offer(String text) {
    final caption = CaptionFrame.tryDecode(text);
    if (caption == null) return false;
    _received.add(caption);
    return true;
  }

  Future<void> close() => _received.close();
}
