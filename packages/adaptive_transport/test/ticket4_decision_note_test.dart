/// Gate 4c — the decision note exists and contains what the gate asks for.
///
/// The gate, quoted from `docs/PLAN_five_tickets_v4.md:687`: a decision note
/// with the 2 ms number and the reason the two other options were rejected.
///
/// WHAT THIS TEST CAN AND CANNOT DO, said before the assertions rather than
/// after. It checks that the note CONTAINS the three things — the figure with the
/// measurement it came from, and a stated rejection for each of the two options.
/// It cannot check that the reasoning is sound; no test can. That is what review
/// is for, and the note is written to be argued with: every number in it carries
/// the file and line it was measured at, so a reader can go and disagree with the
/// source rather than with a summary.
///
/// Why a content check is the honest mechanization here, when this repository
/// rejected a text search as the gate for 4e: the two gates ask different kinds
/// of question. 4e asks whether a claim can be made anywhere in a running app —
/// a search over source cannot answer that, because the claim can be assembled
/// at run time, translated, or made by an icon. 4c asks whether a specific
/// document says specific things. The unit of measurement and the question match.
///
/// Each predicate is also run over a counterexample it has never seen, so a
/// regex that matches nothing cannot pass silently.
import 'dart:io';

import 'package:test/test.dart';

File _decisionNote() {
  var dir = Directory.current.absolute;
  while (true) {
    final file = File('${dir.path}/docs/TICKET4_DECISION.md');
    if (file.existsSync()) return file;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError(
        'docs/TICKET4_DECISION.md not found above '
        '${Directory.current.path}',
      );
    }
    dir = parent;
  }
}

/// The figure AND where it was measured. The number alone would pass on a note
/// that simply asserted "about 2 ms", which is the habit the whole gate exists
/// to break.
bool _statesTheFigureWithItsProvenance(String note) =>
    RegExp(r'\b2\s?ms\b', caseSensitive: false).hasMatch(note) &&
    note.contains('1876') &&
    note.contains('reality_handshake.dart:37-39');

/// Two options, each with the word REJECTED attached to its own heading. Counted
/// positionally: the predicate does not care what the options are called, only
/// that two of them are marked rejected in their own right.
int _rejectedOptionCount(String note) => RegExp(
  r'^#{1,4}\s+Option\s+\w+.*REJECTED',
  multiLine: true,
  caseSensitive: false,
).allMatches(note).length;

/// A rejection with no reason is a verdict, not a note. Each rejected option
/// must be followed by prose containing "Rejected" as a sentence opener — the
/// paragraph that says why.
bool _eachRejectionGivesAReason(String note) {
  final sections = note.split(RegExp(r'^#{1,4}\s+Option\s+', multiLine: true));
  if (sections.length < 3) return false; // preamble + two options
  for (final section in sections.skip(1)) {
    if (!RegExp(
      r'Rejected (because|for)',
      caseSensitive: false,
    ).hasMatch(section)) {
      return false;
    }
  }
  return true;
}

void main() {
  final note = _decisionNote().readAsStringSync();

  test('4c the note states the 2 ms figure with the measurement behind it', () {
    expect(_statesTheFigureWithItsProvenance(note), isTrue);

    // The predicate must be able to fail. A note that asserts the number with
    // no source is exactly the case it has to catch.
    expect(
      _statesTheFigureWithItsProvenance(
        'The Dart path costs about 2 ms per handshake, so it was rejected.',
      ),
      isFalse,
      reason: 'a bare figure with no measured source must not satisfy the gate',
    );
  });

  test('4c two options are marked rejected, each with a reason', () {
    expect(_rejectedOptionCount(note), 2);
    expect(_eachRejectionGivesAReason(note), isTrue);

    const oneOptionOnly = '''
### Option A — through the standard library. REJECTED.
Rejected because the API does not exist.
''';
    expect(
      _rejectedOptionCount(oneOptionOnly),
      1,
      reason: 'the counter must count, not merely match',
    );

    const verdictWithoutReason = '''
### Option A — REJECTED.
Not suitable.
### Option B — REJECTED.
Also not suitable.
''';
    expect(
      _eachRejectionGivesAReason(verdictWithoutReason),
      isFalse,
      reason: 'a verdict with no reason must not satisfy the gate',
    );
  });

  test('4c the note names what was chosen and points at its evidence', () {
    // A note that rejects two options and never says what was taken instead
    // leaves the reader to infer the decision, which is how a decision stops
    // being reviewable.
    expect(note, contains('What was chosen instead'));
    expect(note, contains('TICKET4_FIRST_RECORD'));
  });

  test('4c the note states its own limits', () {
    // Section 6 of that document requires every figure in it to be bounded by
    // what it does not prove. The 4c section is not exempt from its own
    // document's rule, and this is the cheapest possible check that it complied.
    expect(note, contains('What this section does not claim'));
  });
}
