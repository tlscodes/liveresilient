/// Machine-translation seam. The pipeline never knows which engine is
/// behind it — a cloud MT API, an on-device model, or a test fake.
abstract interface class Translator {
  /// Translates [text] from [sourceLang] to [targetLang]. May throw; the
  /// pipeline treats a throw as "this language failed for this segment" and
  /// falls back to the original text (never drops the caption).
  Future<String> translate(
    String text, {
    required String sourceLang,
    required String targetLang,
  });
}

/// Returns the input unchanged — a placeholder engine for demos and for
/// pipelines whose only target language equals the source.
final class IdentityTranslator implements Translator {
  const IdentityTranslator();

  @override
  Future<String> translate(
    String text, {
    required String sourceLang,
    required String targetLang,
  }) async => text;
}

/// Test/demo translator backed by a fixed phrase table, keyed by
/// `'$targetLang:$text'`. Unknown phrases fall back to
/// `'[$targetLang] $text'` so output is always traceable to its input.
final class FixedMapTranslator implements Translator {
  const FixedMapTranslator([this.phrases = const {}]);

  final Map<String, String> phrases;

  @override
  Future<String> translate(
    String text, {
    required String sourceLang,
    required String targetLang,
  }) async => phrases['$targetLang:$text'] ?? '[$targetLang] $text';
}
