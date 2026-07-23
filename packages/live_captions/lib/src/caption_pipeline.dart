import 'dart:async';
import 'dart:collection';

import 'caption.dart';
import 'transcript_segment.dart';
import 'translator.dart';

/// Turns a stream of [TranscriptSegment]s into a stream of translated
/// [Caption]s.
///
/// Guarantees:
/// - **Order**: captions are emitted in segment-arrival order even when the
///   translator resolves out of order (segments are processed one at a
///   time; the per-segment language fan-out runs concurrently).
/// - **Never drops on failure**: a language whose translation throws is
///   reported in [Caption.failedLanguages] and falls back to the original
///   text; the caption still ships.
/// - **Bounded**: at most [maxPendingSegments] segments wait for the
///   translator; beyond that the OLDEST pending segment is dropped
///   ([droppedCount]) — for live captions the newest speech matters most.
class CaptionPipeline {
  CaptionPipeline({
    required Translator translator,
    required List<String> targetLanguages,
    this.maxPendingSegments = 64,
    this.translatePartials = false,
  }) : _translator = translator,
       targetLanguages = List.unmodifiable(targetLanguages) {
    if (maxPendingSegments < 1) {
      throw ArgumentError.value(
        maxPendingSegments,
        'maxPendingSegments',
        'Must be >= 1',
      );
    }
  }

  final Translator _translator;

  /// Languages every caption is translated into (the segment's own language
  /// is skipped — those viewers already understand the original).
  final List<String> targetLanguages;

  final int maxPendingSegments;

  /// Whether in-progress (non-final) segments go through the translator.
  ///
  /// OFF by default — the modern live-caption fast path: a partial is
  /// emitted IMMEDIATELY with the original text only (viewers see words as
  /// they are spoken), and the translator spends its budget exclusively on
  /// final segments, whose translation then replaces the partial in the UI
  /// by segment id. Turning this on restores full translation of every
  /// revision (higher translator load and latency).
  final bool translatePartials;

  final _queue = Queue<TranscriptSegment>();
  final _captions = StreamController<Caption>.broadcast();
  bool _draining = false;
  bool _closed = false;
  int _droppedCount = 0;

  /// Translated captions, in segment-arrival order.
  Stream<Caption> get captions => _captions.stream;

  /// Segments accepted but not yet translated.
  int get pendingCount => _queue.length;

  /// Segments discarded because the translator could not keep up.
  int get droppedCount => _droppedCount;

  /// Accepts one segment. Non-final segments take the zero-latency fast
  /// path (no translation, immediate emission) unless [translatePartials]
  /// is on; final segments are queued for ordered translation.
  void add(TranscriptSegment segment) {
    if (_closed) throw StateError('CaptionPipeline is closed');
    if (!segment.isFinal && !translatePartials) {
      _captions.add(Caption(segment: segment));
      return;
    }
    _queue.add(segment);
    while (_queue.length > maxPendingSegments) {
      _queue.removeFirst();
      _droppedCount++;
    }
    if (!_draining) unawaited(_drain());
  }

  /// Convenience: feeds every segment of [source] through [add].
  StreamSubscription<TranscriptSegment> bind(
    Stream<TranscriptSegment> source,
  ) => source.listen(add);

  Future<void> _drain() async {
    _draining = true;
    try {
      while (_queue.isNotEmpty && !_closed) {
        final segment = _queue.removeFirst();
        final caption = await _translateSegment(segment);
        if (_closed) return;
        _captions.add(caption);
      }
    } finally {
      _draining = false;
    }
  }

  Future<Caption> _translateSegment(TranscriptSegment segment) async {
    final translations = <String, String>{};
    final failed = <String>{};
    await Future.wait(
      targetLanguages.map((lang) async {
        if (lang == segment.lang) return;
        try {
          translations[lang] = await _translator.translate(
            segment.text,
            sourceLang: segment.lang,
            targetLang: lang,
          );
        } catch (_) {
          failed.add(lang);
        }
      }),
    );
    return Caption(
      segment: segment,
      translations: translations,
      failedLanguages: failed,
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _queue.clear();
    await _captions.close();
  }
}

/// Bounded, ordered caption state for a UI: same-segment revisions replace
/// in place, new segments append, and the oldest entries are evicted past
/// [maxEntries]. A committed (final) entry is never downgraded by a late
/// out-of-order partial.
class CaptionLog {
  CaptionLog({this.maxEntries = 200}) {
    if (maxEntries < 1) {
      throw ArgumentError.value(maxEntries, 'maxEntries', 'Must be >= 1');
    }
  }

  final int maxEntries;
  final _entries = <Caption>[];

  List<Caption> get entries => List.unmodifiable(_entries);

  void apply(Caption caption) {
    final i = _entries.indexWhere((c) => c.segment.id == caption.segment.id);
    if (i >= 0) {
      if (_entries[i].segment.isFinal && !caption.segment.isFinal) {
        return; // late partial must not overwrite the committed text
      }
      _entries[i] = caption;
      return;
    }
    _entries.add(caption);
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
  }

  void clear() => _entries.clear();
}
