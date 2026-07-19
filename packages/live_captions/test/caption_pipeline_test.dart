import 'dart:async';

import 'package:live_captions/live_captions.dart';
import 'package:test/test.dart';

TranscriptSegment seg(
  String id,
  int seq,
  String text, {
  String lang = 'en',
  bool isFinal = true,
}) => TranscriptSegment(
  id: id,
  seq: seq,
  lang: lang,
  text: text,
  isFinal: isFinal,
  startMs: seq * 1000,
);

/// Resolves each translation only when the test releases it — proves the
/// pipeline preserves segment order under out-of-order translator latency.
final class GatedTranslator implements Translator {
  final _gates = <String, Completer<void>>{};

  Completer<void> gate(String text) =>
      _gates.putIfAbsent(text, Completer<void>.new);

  @override
  Future<String> translate(
    String text, {
    required String sourceLang,
    required String targetLang,
  }) async {
    await gate(text).future;
    return '[$targetLang] $text';
  }
}

final class ThrowingTranslator implements Translator {
  final Set<String> failLangs;
  ThrowingTranslator(this.failLangs);

  @override
  Future<String> translate(
    String text, {
    required String sourceLang,
    required String targetLang,
  }) async {
    if (failLangs.contains(targetLang)) throw StateError('engine down');
    return '[$targetLang] $text';
  }
}

void main() {
  group('CaptionPipeline', () {
    test('translates into every target language, skipping the source '
        'language', () async {
      final pipeline = CaptionPipeline(
        translator: const FixedMapTranslator({'fa:hello': 'سلام'}),
        targetLanguages: ['fa', 'es', 'en'],
      );
      final got = <Caption>[];
      pipeline.captions.listen(got.add);

      pipeline.add(seg('s1', 0, 'hello'));
      await pumpEventQueue();

      expect(got, hasLength(1));
      final caption = got.single;
      expect(caption.translations['fa'], 'سلام');
      expect(caption.translations['es'], '[es] hello');
      expect(caption.translations.containsKey('en'), isFalse); // source lang
      expect(caption.textFor('fa'), 'سلام');
      expect(caption.textFor('en'), 'hello');

      await pipeline.close();
    });

    test('emits in segment order even when the translator resolves out of '
        'order', () async {
      final translator = GatedTranslator();
      final pipeline = CaptionPipeline(
        translator: translator,
        targetLanguages: ['fa'],
      );
      final got = <Caption>[];
      pipeline.captions.listen(got.add);

      pipeline.add(seg('s1', 0, 'first'));
      pipeline.add(seg('s2', 1, 'second'));
      await pumpEventQueue();

      // Release the SECOND segment's translation first.
      translator.gate('second').complete();
      await pumpEventQueue();
      expect(got, isEmpty); // second may not overtake first

      translator.gate('first').complete();
      await pumpEventQueue();

      expect(got.map((c) => c.segment.text).toList(), ['first', 'second']);
      await pipeline.close();
    });

    test('a failing language falls back to the original text and is marked; '
        'the caption still ships', () async {
      final pipeline = CaptionPipeline(
        translator: ThrowingTranslator({'de'}),
        targetLanguages: ['fa', 'de'],
      );
      final got = <Caption>[];
      pipeline.captions.listen(got.add);

      pipeline.add(seg('s1', 0, 'hello'));
      await pumpEventQueue();

      final caption = got.single;
      expect(caption.translations['fa'], '[fa] hello');
      expect(caption.failedLanguages, {'de'});
      expect(caption.textFor('de'), 'hello'); // fallback, not dropped
      await pipeline.close();
    });

    test(
      'bounded queue drops the OLDEST pending segment beyond the cap',
      () async {
        final translator = GatedTranslator();
        final pipeline = CaptionPipeline(
          translator: translator,
          targetLanguages: ['fa'],
          maxPendingSegments: 2,
        );
        final got = <Caption>[];
        pipeline.captions.listen(got.add);

        pipeline.add(seg('s1', 0, 'a')); // dequeued immediately for translation
        pipeline.add(seg('s2', 1, 'b'));
        pipeline.add(seg('s3', 2, 'c'));
        pipeline.add(seg('s4', 3, 'd')); // cap 2: 'b' is evicted
        expect(pipeline.droppedCount, 1);

        for (final t in ['a', 'b', 'c', 'd']) {
          translator.gate(t).complete();
        }
        await pumpEventQueue();

        expect(got.map((c) => c.segment.text).toList(), ['a', 'c', 'd']);
        await pipeline.close();
      },
    );

    test('add() after close() throws; close is idempotent', () async {
      final pipeline = CaptionPipeline(
        translator: const IdentityTranslator(),
        targetLanguages: ['fa'],
      );
      await pipeline.close();
      await pipeline.close();
      expect(() => pipeline.add(seg('s1', 0, 'x')), throwsStateError);
    });

    test('bind() feeds a source stream through the pipeline', () async {
      final pipeline = CaptionPipeline(
        translator: const IdentityTranslator(),
        targetLanguages: ['en'],
      );
      final got = <Caption>[];
      pipeline.captions.listen(got.add);

      final source = StreamController<TranscriptSegment>();
      pipeline.bind(source.stream);
      source.add(seg('s1', 0, 'streamed'));
      await pumpEventQueue();

      expect(got.single.segment.text, 'streamed');
      await source.close();
      await pipeline.close();
    });
  });

  group('CaptionLog', () {
    Caption cap(String id, String text, {bool isFinal = true}) =>
        Caption(segment: seg(id, 0, text, isFinal: isFinal));

    test('partial revisions replace in place; new ids append', () {
      final log = CaptionLog();
      log.apply(cap('s1', 'hel', isFinal: false));
      log.apply(cap('s2', 'other'));
      log.apply(cap('s1', 'hello', isFinal: true));

      expect(log.entries.map((c) => c.segment.text).toList(), [
        'hello',
        'other',
      ]);
    });

    test('a late partial never downgrades a committed entry', () {
      final log = CaptionLog();
      log.apply(cap('s1', 'hello', isFinal: true));
      log.apply(cap('s1', 'hel', isFinal: false));
      expect(log.entries.single.segment.text, 'hello');
    });

    test('evicts oldest beyond maxEntries', () {
      final log = CaptionLog(maxEntries: 2);
      log.apply(cap('s1', 'a'));
      log.apply(cap('s2', 'b'));
      log.apply(cap('s3', 'c'));
      expect(log.entries.map((c) => c.segment.text).toList(), ['b', 'c']);
    });
  });

  group('model validation', () {
    test(
      'TranscriptSegment rejects empty id/lang and negative seq/startMs',
      () {
        expect(() => seg('', 0, 'x'), throwsArgumentError);
        expect(() => seg('s', -1, 'x'), throwsArgumentError);
        expect(() => seg('s', 0, 'x', lang: ''), throwsArgumentError);
        expect(
          () => TranscriptSegment(
            id: 's',
            seq: 0,
            lang: 'en',
            text: 'x',
            isFinal: true,
            startMs: -5,
          ),
          throwsArgumentError,
        );
      },
    );

    test('CaptionPipeline rejects maxPendingSegments < 1', () {
      expect(
        () => CaptionPipeline(
          translator: const IdentityTranslator(),
          targetLanguages: ['fa'],
          maxPendingSegments: 0,
        ),
        throwsArgumentError,
      );
    });
  });
}
