/// Voice without sending audio: speak the post's own text on the device
/// that reads it.
///
/// This exists because the alternative is worse in three separate ways,
/// and this one is better in all three at once.
///
///  * **Honesty.** At the rates this project targets, transmitted speech
///    is reconstructed, not recorded — no timbre or delivery survives four
///    bytes per second. A listener who hears a voice believes they have
///    heard the person. Speaking the signed text locally makes no such
///    claim: nothing pretends to be a recording, so there is nothing to
///    label and nothing to mistake.
///  * **Dependency.** Transmitted tokens need a neural audio codec on both
///    ends. Local speech needs a text-to-speech engine, which every phone
///    platform already ships. One of those is a research dependency; the
///    other is an API call.
///  * **Bytes.** The words were already sent. This plan is a handful of
///    bytes on top of a layer that had to exist anyway.
///
/// What it costs, stated plainly: the listener hears a synthetic reading,
/// not the author. For a message whose authenticity rests on a signature
/// rather than on a voice, that is the honest trade — and it is the same
/// trade a transmitted low-rate voice makes, without the illusion.
library;

import 'dart:typed_data';

/// Where a rendered post's audio comes from.
enum VoiceProvenance {
  /// Speech synthesized on this device from the signed text.
  ///
  /// Not the author's voice, and never presented as one.
  synthesizedFromText,

  /// Decoded from transmitted neural-codec tokens.
  ///
  /// Also a reconstruction rather than a recording: at these rates the
  /// speaker's identity is not in the payload. A user interface must say
  /// so — this value is not a licence to imply otherwise.
  reconstructedFromTokens,
}

/// Longest language tag accepted, in bytes.
const int maxLanguageTagLength = 16;

/// Bounds on the requested speaking rate, in words per minute.
const int minWordsPerMinute = 60;
const int maxWordsPerMinute = 400;

/// The default reading pace when a plan does not ask for one.
const int defaultWordsPerMinute = 160;

/// An instruction to read the post's text aloud.
class SpokenTextPlan {
  SpokenTextPlan({
    required this.language,
    this.wordsPerMinute = defaultWordsPerMinute,
  }) {
    if (language.isEmpty || language.length > maxLanguageTagLength) {
      throw ArgumentError.value(
        language,
        'language',
        'must be 1..$maxLanguageTagLength characters',
      );
    }
    for (final unit in language.codeUnits) {
      // A BCP-47 tag is letters, digits and hyphens. Refusing anything
      // else keeps a tag from carrying bytes that mean something to a
      // platform API but nothing to this format.
      final isLetter =
          (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A);
      final isDigit = unit >= 0x30 && unit <= 0x39;
      if (!isLetter && !isDigit && unit != 0x2D) {
        throw ArgumentError.value(
          language,
          'language',
          'only letters, digits and hyphens',
        );
      }
    }
    if (wordsPerMinute < minWordsPerMinute ||
        wordsPerMinute > maxWordsPerMinute) {
      throw ArgumentError.value(
        wordsPerMinute,
        'wordsPerMinute',
        'must be $minWordsPerMinute..$maxWordsPerMinute',
      );
    }
  }

  /// BCP-47 tag naming the language the text is in, so the reading device
  /// picks a voice that can pronounce it.
  final String language;

  /// Requested pace. A hint: an engine that cannot honour it should read
  /// at its own default rather than refuse.
  final int wordsPerMinute;

  /// `u8 rate/4 · u8 tagLength · tag`
  ///
  /// The rate is quantized to four words per minute because no listener
  /// can tell those apart and it saves a byte.
  Uint8List encode() {
    final tag = Uint8List.fromList(language.codeUnits);
    final out = Uint8List(2 + tag.length)
      ..[0] = wordsPerMinute ~/ 4
      ..[1] = tag.length
      ..setRange(2, 2 + tag.length, tag);
    return out;
  }

  static SpokenTextPlan? decode(Uint8List body) {
    if (body.length < 3) return null;
    final rate = body[0] * 4;
    final tagLength = body[1];
    if (tagLength == 0 || tagLength > maxLanguageTagLength) return null;
    if (body.length != 2 + tagLength) return null;
    if (rate < minWordsPerMinute || rate > maxWordsPerMinute) return null;
    try {
      return SpokenTextPlan(
        language: String.fromCharCodes(
          Uint8List.sublistView(body, 2, 2 + tagLength),
        ),
        wordsPerMinute: rate,
      );
    } on ArgumentError {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SpokenTextPlan &&
      other.language == language &&
      other.wordsPerMinute == wordsPerMinute;

  @override
  int get hashCode => Object.hash(language, wordsPerMinute);
}

/// Everything a text-to-speech engine needs for one post.
class SpokenTextRequest {
  const SpokenTextRequest({
    required this.text,
    required this.language,
    required this.wordsPerMinute,
  });

  /// The verified text of the post. Never anything else: an engine must
  /// not be handed bytes that failed a signature or hash check.
  final String text;

  final String language;
  final int wordsPerMinute;
}

/// The seam a host app fills with the platform's speech synthesizer.
///
/// Left as an interface for the same reason the crypto and the transport
/// are: this package stays pure Dart, and every phone platform already
/// has an engine that a few lines of channel code can reach.
abstract interface class SpeechSynthesizer {
  /// Whether a voice for [language] is available right now.
  Future<bool> canSpeak(String language);

  /// Read [request] aloud. Completes when the reading finishes or is
  /// stopped.
  Future<void> speak(SpokenTextRequest request);

  /// Stop any reading in progress.
  Future<void> stop();
}
