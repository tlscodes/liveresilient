import 'dart:typed_data';

import 'package:broadcast_media/broadcast_media.dart';
import 'package:hamseda_codec/hamseda_codec.dart';
import 'package:test/test.dart';

const String _body = 'اینترنت قطع است و این پیام امضا شده است.';

void main() {
  const composer = BroadcastMediaComposer();
  const renderer = BroadcastMediaRenderer();

  group('the plan on the wire', () {
    test('is a handful of bytes, because the words were already sent', () {
      final plan = SpokenTextPlan(language: 'fa');
      expect(plan.encode().length, 4);

      final layers = composer.compose(body: _body, spokenText: plan);
      // The whole voice layer costs less than a short word of text.
      expect(layers.voice!.length, lessThan(16));
    });

    test('round-trips language and pace', () {
      final plan = SpokenTextPlan(language: 'fa-IR', wordsPerMinute: 140);
      final decoded = SpokenTextPlan.decode(plan.encode());
      expect(decoded, plan);
      expect(decoded!.language, 'fa-IR');
      expect(decoded.wordsPerMinute, 140);
    });

    test('the pace is quantized to four words per minute', () {
      // No listener can tell those apart, and it saves a byte.
      final decoded = SpokenTextPlan.decode(
        SpokenTextPlan(language: 'en', wordsPerMinute: 163).encode(),
      );
      expect(decoded!.wordsPerMinute, 160);
    });

    test('defaults to a readable pace', () {
      expect(SpokenTextPlan(language: 'en').wordsPerMinute, 160);
    });
  });

  group('refusals', () {
    test('a tag that is not a language tag is refused', () {
      for (final tag in ['', 'fa_IR', 'fa IR', 'fa/../x', 'a' * 17]) {
        expect(
          () => SpokenTextPlan(language: tag),
          throwsArgumentError,
          reason: 'must refuse "$tag"',
        );
      }
    });

    test('a pace outside the sane range is refused', () {
      expect(
        () => SpokenTextPlan(language: 'en', wordsPerMinute: 10),
        throwsArgumentError,
      );
      expect(
        () => SpokenTextPlan(language: 'en', wordsPerMinute: 900),
        throwsArgumentError,
      );
    });

    test('malformed bytes decode to null rather than a default', () {
      expect(SpokenTextPlan.decode(Uint8List(0)), isNull);
      expect(SpokenTextPlan.decode(Uint8List(2)), isNull);
      // Declared tag length longer than the buffer.
      expect(
        SpokenTextPlan.decode(Uint8List.fromList([40, 9, 0x66, 0x61])),
        isNull,
      );
      // Zero-length tag.
      expect(SpokenTextPlan.decode(Uint8List.fromList([40, 0, 0])), isNull);
      // Rate below the floor.
      expect(
        SpokenTextPlan.decode(Uint8List.fromList([1, 2, 0x66, 0x61])),
        isNull,
      );
      // A tag byte that is not allowed in a tag.
      expect(
        SpokenTextPlan.decode(Uint8List.fromList([40, 2, 0x20, 0x61])),
        isNull,
      );
    });

    test('trailing bytes after the tag are refused', () {
      expect(
        SpokenTextPlan.decode(Uint8List.fromList([40, 2, 0x66, 0x61, 0x00])),
        isNull,
      );
    });
  });

  group('composing', () {
    test('a reading with no text to read is refused', () {
      expect(
        () => composer.compose(spokenText: SpokenTextPlan(language: 'fa')),
        throwsArgumentError,
      );
      expect(
        () => composer.compose(
          body: '',
          spokenText: SpokenTextPlan(language: 'fa'),
        ),
        throwsArgumentError,
      );
    });

    test('a post has one voice layer, not two', () {
      expect(
        () => composer.compose(
          body: _body,
          spokenText: SpokenTextPlan(language: 'fa'),
          voiceTokens: VoiceTokenBlock(
            columns: const [
              [1, 2],
            ],
            rows: 2,
          ),
          voiceSession: HamsedaSession(2),
        ),
        throwsArgumentError,
      );
    });

    test('the plan is named in the report', () {
      final layers = composer.compose(
        body: _body,
        spokenText: SpokenTextPlan(language: 'fa'),
      );
      expect(
        layers.report.included.map((p) => p.name),
        contains('voice.spoken-text'),
      );
    });
  });

  group('rendering', () {
    test('produces a request built from the verified text', () {
      final layers = composer.compose(
        body: _body,
        spokenText: SpokenTextPlan(language: 'fa', wordsPerMinute: 120),
      );
      final rendered = renderer.render(
        textLayer: layers.text,
        voiceLayer: layers.voice,
      );
      expect(rendered.spokenText, isNotNull);
      expect(rendered.spokenText!.text, _body);
      expect(rendered.spokenText!.language, 'fa');
      expect(rendered.spokenText!.wordsPerMinute, 120);
      expect(rendered.hasAudio, isTrue);
      expect(rendered.unreadableParts, 0);
    });

    test('provenance says the audio is synthesized, never a recording', () {
      // The whole reason this layer exists. A user interface reads this
      // and must not imply the author was heard.
      final layers = composer.compose(
        body: _body,
        spokenText: SpokenTextPlan(language: 'fa'),
      );
      final rendered = renderer.render(
        textLayer: layers.text,
        voiceLayer: layers.voice,
      );
      expect(rendered.voiceProvenance, VoiceProvenance.synthesizedFromText);
    });

    test('transmitted tokens are also marked as a reconstruction', () {
      // At these rates no speaker identity survives, so this path carries
      // the same warning rather than a stronger claim.
      const rows = 2;
      final sender = HamsedaSession(rows);
      final receiver = HamsedaSession(rows);
      final columns = [
        for (var i = 0; i < 20; i++) [i % 1024, (i * 7) % 1024],
      ];
      final layers = composer.compose(
        voiceTokens: VoiceTokenBlock(columns: columns, rows: rows),
        voiceSession: sender,
      );
      final rendered = renderer.render(
        voiceLayer: layers.voice,
        voiceSession: receiver,
      );
      expect(rendered.voiceProvenance, VoiceProvenance.reconstructedFromTokens);
    });

    test('a plan without its text layer produces nothing to speak', () {
      // An engine must never be handed bytes that did not survive
      // verification, and the text is what carries the words.
      final layers = composer.compose(
        body: _body,
        spokenText: SpokenTextPlan(language: 'fa'),
      );
      final rendered = renderer.render(voiceLayer: layers.voice);
      expect(rendered.spokenText, isNull);
      expect(rendered.voiceProvenance, isNull);
      expect(rendered.unreadableParts, 1);
    });

    test('a corrupt plan is counted, not defaulted', () {
      final rendered = renderer.render(
        textLayer: composer.compose(body: _body).text,
        voiceLayer: PayloadEnvelope(
          kind: PayloadKind.spokenText,
          body: Uint8List.fromList([0, 0, 0]),
        ).encode(),
      );
      expect(rendered.body, _body);
      expect(rendered.spokenText, isNull);
      expect(rendered.unreadableParts, 1);
    });

    test('a post with no voice layer has no provenance and no audio', () {
      final rendered = renderer.render(
        textLayer: composer.compose(body: _body).text,
      );
      expect(rendered.hasAudio, isFalse);
      expect(rendered.voiceProvenance, isNull);
    });
  });

  test('a spoken-text post costs almost nothing over the text alone', () {
    // The byte argument, measured: the reading is free next to the words.
    final textOnly = composer.compose(body: _body);
    final withVoice = composer.compose(
      body: _body,
      spokenText: SpokenTextPlan(language: 'fa'),
    );
    final overhead = withVoice.voice!.length;
    expect(overhead, lessThan(textOnly.text!.length ~/ 4));
  });
}
