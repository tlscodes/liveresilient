import 'dart:async';
import 'dart:convert';

import 'package:live_captions/live_captions.dart';
import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

/// Loopback data channel, same pattern as messaging's own tests.
class MemPort implements DataChannelPort {
  final _in = StreamController<List<int>>.broadcast();
  MemPort? peer;
  @override
  Stream<List<int>> get inbound => _in.stream;
  @override
  Future<void> send(List<int> frame) async => peer?._in.add(frame);
  @override
  Future<void> close() async {
    if (!_in.isClosed) await _in.close();
  }
}

Caption cap(String id, int seq, String text) => Caption(
  segment: TranscriptSegment(
    id: id,
    seq: seq,
    lang: 'en',
    text: text,
    isFinal: true,
    startMs: seq * 100,
  ),
  translations: {'fa': 'ترجمه‌ی $text'},
  failedLanguages: {'de'},
);

void main() {
  group('CaptionFrame', () {
    test('encode -> tryDecode round-trips all fields', () {
      final original = cap('c1', 3, 'hello');
      final back = CaptionFrame.tryDecode(CaptionFrame.encode(original))!;

      expect(back.segment.id, 'c1');
      expect(back.segment.seq, 3);
      expect(back.segment.lang, 'en');
      expect(back.segment.text, 'hello');
      expect(back.segment.isFinal, isTrue);
      expect(back.segment.startMs, 300);
      expect(back.translations, {'fa': 'ترجمه‌ی hello'});
      expect(back.failedLanguages, {'de'});
    });

    test('plain chat and attachment frames are not captions', () {
      expect(CaptionFrame.tryDecode('hello there'), isNull);
      final attachmentFrame = jsonEncode({'t': 'attach', 'aid': 'a1'});
      expect(CaptionFrame.tryDecode(attachmentFrame), isNull);
    });

    test('hostile input is rejected, never thrown', () {
      String frame(Map<String, Object?> overrides) {
        final base = <String, Object?>{
          't': 'caption',
          'id': 'c1',
          'seq': 0,
          'lang': 'en',
          'text': 'x',
          'fin': true,
          'start': 0,
          'tr': const <String, String>{},
          'fl': const <String>[],
        };
        base.addAll(overrides);
        return jsonEncode(base);
      }

      expect(CaptionFrame.tryDecode(frame({'id': ''})), isNull);
      expect(CaptionFrame.tryDecode(frame({'id': 7})), isNull);
      expect(CaptionFrame.tryDecode(frame({'seq': -1})), isNull);
      expect(CaptionFrame.tryDecode(frame({'lang': ''})), isNull);
      expect(CaptionFrame.tryDecode(frame({'fin': 'yes'})), isNull);
      expect(CaptionFrame.tryDecode(frame({'start': -1})), isNull);
      expect(
        CaptionFrame.tryDecode(
          frame({'text': 'x' * (CaptionFrame.maxTextChars + 1)}),
        ),
        isNull,
      );
      expect(
        CaptionFrame.tryDecode(
          frame({
            'tr': {
              for (var i = 0; i <= CaptionFrame.maxTranslations; i++)
                'l$i': 'x',
            },
          }),
        ),
        isNull,
      );
      expect(
        CaptionFrame.tryDecode(
          frame({
            'tr': {'fa': 'x' * (CaptionFrame.maxTextChars + 1)},
          }),
        ),
        isNull,
      );
      expect(
        CaptionFrame.tryDecode(
          frame({
            'tr': {'': 'x'},
          }),
        ),
        isNull,
      );
      expect(
        CaptionFrame.tryDecode(
          frame({
            'fl': [7],
          }),
        ),
        isNull,
      );
      expect(CaptionFrame.tryDecode('{not json'), isNull);
    });
  });

  group('CaptionReceiver', () {
    test('consumes caption frames only; everything else keeps routing', () {
      final receiver = CaptionReceiver();
      final got = <Caption>[];
      receiver.received.listen(got.add);

      expect(receiver.offer(CaptionFrame.encode(cap('c1', 0, 'hi'))), isTrue);
      expect(receiver.offer('plain chat'), isFalse);
      expect(receiver.offer(jsonEncode({'t': 'attach'})), isFalse);
    });
  });

  test('end-to-end: captions ride a real ReliableMessenger pair beside chat '
      'text, in order', () async {
    final a = MemPort();
    final b = MemPort();
    a.peer = b;
    b.peer = a;
    final speaker = ReliableMessenger(a, peerId: 'speaker');
    final listener = ReliableMessenger(b, peerId: 'listener');

    final receiver = CaptionReceiver();
    final captions = <Caption>[];
    final chats = <String>[];
    receiver.received.listen(captions.add);
    listener.incoming.listen((m) {
      if (!receiver.offer(m.text)) chats.add(m.text);
    });

    final pipeline = CaptionPipeline(
      translator: const FixedMapTranslator({'fa:good morning': 'صبح بخیر'}),
      targetLanguages: ['fa'],
    );
    pipeline.captions.listen((c) => unawaited(sendCaption(speaker, c)));

    pipeline.add(
      TranscriptSegment(
        id: 'c1',
        seq: 0,
        lang: 'en',
        text: 'good morning',
        isFinal: true,
        startMs: 0,
      ),
    );
    await speaker.send('welcome everyone'); // plain chat interleaved
    pipeline.add(
      TranscriptSegment(
        id: 'c2',
        seq: 1,
        lang: 'en',
        text: 'second line',
        isFinal: true,
        startMs: 1000,
      ),
    );
    await pumpEventQueue();

    expect(chats, ['welcome everyone']);
    expect(captions.map((c) => c.segment.id).toList(), ['c1', 'c2']);
    expect(captions.first.textFor('fa'), 'صبح بخیر');

    await pipeline.close();
    await receiver.close();
    await speaker.close();
    await listener.close();
  });
}
