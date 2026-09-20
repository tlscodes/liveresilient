// The queue's file store on a real temp directory: a round trip keeps the
// bytes, kind and a voice take's length; the write goes through a sibling
// and a rename, so a torn file is read as no letter, never as half of one;
// and the queue's cap keeps the file from growing without bound.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/letter_queue.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('letter_queue_store_test');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  QueuedLetter letter(String id, String text, {Duration? duration}) =>
      QueuedLetter(
        id: id,
        bytes: Uint8List.fromList(text.codeUnits),
        kind: duration == null ? 'typed' : 'voice',
        queuedAt: DateTime.utc(2026, 9, 20, 12),
        duration: duration,
      );

  test('an absent file is an empty queue', () async {
    expect(await FileLetterQueueStore(dir).load(), isEmpty);
  });

  test('save then load round-trips bytes, kind and duration', () async {
    final store = FileLetterQueueStore(dir);
    await store.save([
      letter('a', 'hello'),
      letter('b', 'take', duration: const Duration(milliseconds: 2400)),
    ]);
    final file = File('${dir.path}/${FileLetterQueueStore.fileName}');
    expect(file.existsSync(), isTrue);
    expect(File('${file.path}.tmp').existsSync(), isFalse, reason: 'renamed');

    final back = await FileLetterQueueStore(dir).load();
    expect(back.map((l) => l.id), ['a', 'b']);
    expect(back.first.bytes, 'hello'.codeUnits);
    expect(back.first.kind, 'typed');
    expect(back.first.duration, isNull);
    expect(back.last.kind, 'voice');
    expect(back.last.duration, const Duration(milliseconds: 2400));
    expect(back.last.queuedAt, DateTime.utc(2026, 9, 20, 12));
  });

  test('a torn or foreign file reads as no letter', () async {
    final file = File('${dir.path}/${FileLetterQueueStore.fileName}');
    file.writeAsStringSync('[{"id":"a","bytes":"aGVsbG8=","ki');
    expect(await FileLetterQueueStore(dir).load(), isEmpty);
    file.writeAsStringSync('{"not":"a list"}');
    expect(await FileLetterQueueStore(dir).load(), isEmpty);
  });

  test('a save over an old list replaces it whole', () async {
    final store = FileLetterQueueStore(dir);
    await store.save([letter('a', 'one'), letter('b', 'two')]);
    await store.save([letter('b', 'two')]);
    final back = await store.load();
    expect(back.map((l) => l.id), ['b']);
  });

  test(
    'the queue over the file store is capped: the letter past the cap is refused',
    () async {
      final queue = LetterQueue(FileLetterQueueStore(dir), maxLetters: 2);
      expect(await queue.enqueue(letter('a', 'one')), isTrue);
      expect(await queue.enqueue(letter('b', 'two')), isTrue);
      expect(queue.isFull, isTrue);
      expect(await queue.enqueue(letter('c', 'three')), isFalse);
      expect(
        await queue.enqueue(letter('b', 'two')),
        isTrue,
        reason: 'same id',
      );
      expect(queue.length, 2);
      final back = await FileLetterQueueStore(dir).load();
      expect(back.map((l) => l.id), ['a', 'b']);

      await queue.remove('a');
      expect(queue.isFull, isFalse);
      expect(await queue.enqueue(letter('c', 'three')), isTrue);
      expect((await FileLetterQueueStore(dir).load()).map((l) => l.id), [
        'b',
        'c',
      ]);
      queue.dispose();
    },
  );

  test(
    'a new queue over the same directory rehydrates what was parked',
    () async {
      final first = LetterQueue(FileLetterQueueStore(dir));
      await first.enqueue(letter('a', 'survive'));
      first.dispose();
      final second = LetterQueue(FileLetterQueueStore(dir));
      await second.ensureLoaded();
      expect(second.length, 1);
      expect(second.take()!.bytes, 'survive'.codeUnits);
      expect(second.take(), isNull, reason: 'in flight, not offered twice');
      await second.remove('a');
      expect(await FileLetterQueueStore(dir).load(), isEmpty);
      second.dispose();
    },
  );
}
