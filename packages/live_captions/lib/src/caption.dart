import 'transcript_segment.dart';

/// A transcript segment plus its translations — the unit the UI renders and
/// the wire carries.
class Caption {
  final TranscriptSegment segment;

  /// Target-language → translated text. Only languages that translated
  /// successfully appear here.
  final Map<String, String> translations;

  /// Languages whose translation failed for this segment; [textFor] falls
  /// back to the original text for these instead of dropping the caption.
  final Set<String> failedLanguages;

  Caption({
    required this.segment,
    Map<String, String> translations = const {},
    Set<String> failedLanguages = const {},
  }) : translations = Map.unmodifiable(translations),
       failedLanguages = Set.unmodifiable(failedLanguages);

  /// The best text to show a [lang] viewer: the translation when available,
  /// otherwise the original segment text.
  String textFor(String lang) => translations[lang] ?? segment.text;
}
