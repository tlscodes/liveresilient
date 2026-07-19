/// One unit of recognized speech from a speech-to-text engine.
///
/// Engines emit a stream of segments: zero or more *partial* revisions
/// (`isFinal == false`) followed by one *final* segment, all sharing the same
/// [id]. Consumers replace by [id]; [seq] orders segments globally within a
/// session.
class TranscriptSegment {
  final String id;

  /// Monotonic position within the transcription session. Used to keep
  /// captions in spoken order end-to-end.
  final int seq;

  /// Source language tag of [text] (e.g. `en`, `fa`, `es-419`).
  final String lang;

  final String text;

  /// False for an in-progress revision that a later segment with the same
  /// [id] will replace; true once the engine has committed the text.
  final bool isFinal;

  /// Speech start, in milliseconds on the speaker's clock.
  final int startMs;

  TranscriptSegment({
    required this.id,
    required this.seq,
    required this.lang,
    required this.text,
    required this.isFinal,
    required this.startMs,
  }) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'Must not be empty');
    }
    if (lang.isEmpty) {
      throw ArgumentError.value(lang, 'lang', 'Must not be empty');
    }
    if (seq < 0) {
      throw ArgumentError.value(seq, 'seq', 'Must be >= 0');
    }
    if (startMs < 0) {
      throw ArgumentError.value(startMs, 'startMs', 'Must be >= 0');
    }
  }
}
