// A desktop kept its parked letters and its card file in a purgeable temp
// folder. They now live beside the identity file, carried over once.
// Folders are made for the test; nothing touches a real home.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/intelligence/device_bindings.dart';
import 'package:reference_app/src/letter_card.dart';
import 'package:reference_app/src/letter_queue.dart';

void main() {
  group('a desktop keeps its letters and cards outside the temp folder', () {
    late Directory root;
    late Directory old;
    late Directory home;

    setUp(() {
      root = Directory.systemTemp.createTempSync('desktop_storage_test');
      old = Directory('${root.path}/tmp/voice_call_kit_intelligence')
        ..createSync(recursive: true);
      home = Directory('${root.path}/support/voice_call_kit_intelligence');
    });
    tearDown(() => root.deleteSync(recursive: true));

    LetterCard card(String session) => LetterCard(
      at: DateTime.utc(2026, 10, 5),
      source: 'test',
      session: session,
      bytes: 12,
      outcome: 'sent',
    );

    test('the queue and the card file are carried over once, never over '
        'what is there, and the old ones stay', () async {
      await LetterCardLog(() => old).append(card('OLD001'));
      Directory('${old.path}/letters').createSync();
      File(
        '${old.path}/letters/${SealedFileLetterQueueStore.fileName}',
      ).writeAsBytesSync([1, 2, 3]);
      File(
        '${old.path}/letters/${FileLetterQueueStore.fileName}',
      ).writeAsStringSync('[]');

      expect(adoptDesktopFiles(from: old, to: home), 3);
      expect(
        File('${home.path}/letter_cards.jsonl').readAsStringSync(),
        contains('OLD001'),
      );
      expect(
        File(
          '${home.path}/letters/${SealedFileLetterQueueStore.fileName}',
        ).readAsBytesSync(),
        [1, 2, 3],
      );
      expect(File('${old.path}/letter_cards.jsonl').existsSync(), isTrue);
      expect(
        File(
          '${old.path}/letters/${SealedFileLetterQueueStore.fileName}',
        ).existsSync(),
        isTrue,
      );

      // A second carry-over changes nothing, even if the old side moved on.
      await LetterCardLog(() => old).append(card('OLD002'));
      expect(adoptDesktopFiles(from: old, to: home), 0);
      expect(
        File('${home.path}/letter_cards.jsonl').readAsStringSync(),
        isNot(contains('OLD002')),
      );
    });

    test('nothing to carry, or the same folder, copies nothing', () {
      expect(adoptDesktopFiles(from: old, to: home), 0);
      expect(adoptDesktopFiles(from: home, to: home), 0);
      expect(
        adoptDesktopFiles(from: Directory('${root.path}/absent'), to: home),
        0,
      );
    });

    test('a second boot reads the same record from the new folder', () async {
      await LetterCardLog(() => old).append(card('OLD001'));
      adoptDesktopFiles(from: old, to: home);

      // First boot in the new home: the carried card, then a new one.
      await LetterCardLog(() => home).append(card('NEW001'));
      // Second boot: a fresh log object over the same folder.
      final lines = File(
        '${home.path}/letter_cards.jsonl',
      ).readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
      expect(lines, hasLength(2));
      expect(lines.first, contains('OLD001'));
      expect(lines.last, contains('NEW001'));

      // And the parked-letter queue: saved by one store, loaded by another.
      final letters = Directory('${home.path}/letters')
        ..createSync(recursive: true);
      final first = FileLetterQueueStore(letters);
      await first.save(await first.load());
      expect(await FileLetterQueueStore(letters).load(), isEmpty);
      expect(
        File('${letters.path}/${FileLetterQueueStore.fileName}').existsSync(),
        isTrue,
      );
    });

    test('under flutter test nothing leaves the temp folder', () {
      expect(
        intelligenceStorageDirectory().path,
        legacyDesktopStorageDirectory().path,
      );
      expect(
        identityStorageDirectory().path,
        intelligenceStorageDirectory().path,
      );
      expect(
        letterQueueDirectory().parent.path,
        intelligenceStorageDirectory().path,
      );
    });
  });
}
