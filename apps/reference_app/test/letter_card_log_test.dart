import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/intelligence/device_bindings.dart'
    show intelligenceStorageDirectory;
import 'package:reference_app/src/letter_card.dart';

LetterCard _card({required String outcome, String? rung, String? session}) =>
    LetterCard(
      at: DateTime.utc(2026, 10, 3, 18, 22, 33),
      source: 'phone',
      session: session,
      bytes: 107,
      outcome: outcome,
      bestLane: 'resilient.wss',
      rung: rung,
    );

void main() {
  group('disk() shares the one intelligence folder', () {
    late File target;
    String? original;

    setUp(() {
      target = File(
        '${intelligenceStorageDirectory().path}/letter_cards.jsonl',
      );
      original = target.existsSync() ? target.readAsStringSync() : null;
    });

    tearDown(() {
      // Non-destructive: restore the folder exactly as the test found it.
      if (original != null) {
        target.writeAsStringSync(original!);
      } else if (target.existsSync()) {
        target.deleteSync();
      }
    });

    test(
      'disk() writes letter_cards.jsonl into intelligenceStorageDirectory',
      () async {
        await LetterCardLog.disk().append(
          _card(outcome: 'sentLive', rung: 'weak', session: 'DISK1'),
        );
        expect(target.existsSync(), isTrue);
        final mine = target
            .readAsLinesSync()
            .map((line) => jsonDecode(line) as Map<String, Object?>)
            .where((m) => m['session'] == 'DISK1')
            .toList();
        expect(mine, hasLength(1));
        expect(mine.single['outcome'], 'sentLive');
        expect(mine.single['lab'], true);
      },
    );
  });

  group('card writer', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('letter_card_log_test');
    });

    tearDown(() {
      dir.deleteSync(recursive: true);
    });

    List<Map<String, Object?>> readLines() =>
        File('${dir.path}/letter_cards.jsonl')
            .readAsLinesSync()
            .map((line) => jsonDecode(line) as Map<String, Object?>)
            .toList();

    test('a sentLive card with a rung writes that rung', () async {
      final log = LetterCardLog(() => dir);
      await log.append(_card(outcome: 'sentLive', rung: 'weak'));
      final lines = readLines();
      expect(lines, hasLength(1));
      expect(lines.single['outcome'], 'sentLive');
      expect(lines.single['rung'], 'weak');
      expect(lines.single['lab'], true);
    });

    test('a queued card with no rung writes rung null', () async {
      final log = LetterCardLog(() => dir);
      await log.append(_card(outcome: 'queued'));
      final lines = readLines();
      expect(lines, hasLength(1));
      expect(lines.single['outcome'], 'queued');
      expect(lines.single['rung'], isNull);
    });

    test('later cards append after earlier ones, never overwrite', () async {
      final log = LetterCardLog(() => dir);
      await log.append(_card(outcome: 'sentLive', rung: 'normal'));
      await log.append(_card(outcome: 'queued', session: 'S9'));
      final lines = readLines();
      expect(lines.map((l) => l['outcome']), ['sentLive', 'queued']);
      expect(lines.last['session'], 'S9');
    });
  });

  test(
    'the fabric and app outcome words normalize to the three card words',
    () {
      expect(normalizeLetterOutcome('sentLive'), 'sentLive');
      expect(normalizeLetterOutcome('arrived'), 'sentLive');
      expect(normalizeLetterOutcome('queuedForLater'), 'queued');
      expect(normalizeLetterOutcome('queued'), 'queued');
      expect(normalizeLetterOutcome('rejected'), 'notDelivered');
    },
  );
}
