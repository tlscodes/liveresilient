import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adaptive_transport/adaptive_transport.dart'
    show ForgedAnswerException, TxtProbeAnswer, TxtProbeOutcome;
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/intelligence/device_bindings.dart'
    show intelligenceStorageDirectory;
import 'package:reference_app/src/letter_card.dart';

LetterCard _card({
  required String outcome,
  String? rung,
  String? reason,
  String? session,
}) => LetterCard(
  at: DateTime.utc(2026, 10, 3, 18, 22, 33),
  source: 'phone',
  session: session,
  bytes: 107,
  outcome: outcome,
  bestLane: 'resilient.wss',
  rung: rung,
  reason: reason,
);

void main() {
  group('the proof line', () {
    final at = DateTime.utc(2026, 10, 4, 20);
    TxtProbeAnswer miss(int i, String label, Object? error) =>
        TxtProbeAnswer(index: i, label: label, nonce: 'n$i', error: error);

    test('names what was asked, what returned, and each miss by its cause', () {
      final proof = LetterProof.fromProbe(
        TxtProbeOutcome(
          groupId: 'g7',
          answers: [
            const TxtProbeAnswer(
              index: 0,
              label: 'a',
              nonce: 'n0',
              winnerNonce: 'n0',
              rank: 1,
            ),
            miss(1, 'b', TimeoutException('silent')),
            miss(
              2,
              'c',
              ForgedAnswerException('x', InternetAddress('10.0.0.1')),
            ),
            miss(3, 'd', const FormatException('garbled')),
            miss(4, 'e', null),
          ],
          winnerIndex: 0,
        ),
        at: at,
      );
      expect(
        jsonEncode(proof.toJson()),
        '{"event":"letter_proof","v":1,"at":"2026-10-04T20:00:00.000Z",'
        '"session":"g7","asked":["a","b","c","d","e"],"returned":["a"],'
        '"failed":{"b":"timeout","c":"forged","d":"error","e":"timeout"},'
        '"lab":true}',
      );
    });

    test('is one more line in the same journal file as the cards', () async {
      final dir = Directory.systemTemp.createTempSync('letter_proof_log');
      addTearDown(() => dir.deleteSync(recursive: true));
      final log = LetterCardLog(() => dir);
      await log.appendProof(
        LetterProof(
          at: at,
          session: 'g7',
          asked: const ['a'],
          returned: const [],
          failed: const {'a': 'forged'},
        ),
      );
      await log.append(_card(outcome: 'queued', reason: 'forged'));
      final lines = File(
        '${dir.path}/letter_cards.jsonl',
      ).readAsLinesSync().map((l) => jsonDecode(l) as Map).toList();
      expect(lines.map((l) => l['event']), ['letter_proof', 'letter_card']);
      expect(lines.first['failed'], {'a': 'forged'});
    });
  });

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

    test('a sentLive card with a rung and reason writes both', () async {
      final log = LetterCardLog(() => dir);
      await log.append(
        _card(outcome: 'sentLive', rung: 'weak', reason: 'slow'),
      );
      final lines = readLines();
      expect(lines, hasLength(1));
      expect(lines.single['outcome'], 'sentLive');
      expect(lines.single['rung'], 'weak');
      expect(lines.single['reason'], 'slow');
      expect(lines.single['lab'], true);
    });

    test('a queued card with no rung writes rung and reason null', () async {
      final log = LetterCardLog(() => dir);
      await log.append(_card(outcome: 'queued'));
      final lines = readLines();
      expect(lines, hasLength(1));
      expect(lines.single['outcome'], 'queued');
      expect(lines.single['rung'], isNull);
      expect(lines.single['reason'], isNull);
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
