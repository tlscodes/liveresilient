/// Gate 2c — the replay total on the corpus the gate names.
///
/// WHAT THIS FILE IS, exactly. Gate 2c reads: *replay v4 on the same corpus,
/// total score >= 1.107*. The replay takes minutes and writes an artifact, so
/// this test does NOT re-derive the measurement; it pins the artifact and the
/// inputs the artifact says it consumed. That distinction is the whole honesty
/// of the file: it proves the record still says what the gate claims, not that
/// the number was recomputed on this machine at this second. The commands that
/// produced both artifacts are in `docs/GATE_2C_REPLAY.md` and their full
/// output is in `tools/t2/gate_2c/replay_2c_S1.log` and `..._S2.log`, beside the
/// exact table (`h2_results_asof_0810.tsv`) and the 23 corpus filenames
/// (`corpus_asof_0810.txt`) the run consumed — names, not timestamps, because
/// file dates do not survive a clone and names do.
///
/// WHICH INPUTS THE GATE NAMES, and why it is not a convenient choice made
/// after seeing a number. `replay_benchmark_test.dart` line 74 has recorded,
/// since the day this gate was built, that the corpus was *23 captures and 272
/// tsv rows*. S2 consumed exactly 23 and 272. The restoration was checked
/// against a record that predates today's measurement, not chosen to suit it.
///
/// THE NEGATIVE CONTROL IS HALF THE FILE. S1 is the same code over the same 23
/// captures with the table as it stands today — 287 rows, 15 of them added
/// after the bar was observed — and it must FAIL the bar. A pin that can only
/// ever pass is not evidence of anything, so the same predicate is asserted in
/// both directions, and the pair also proves what the difference was: one
/// input, the table.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/repo_root.dart';

/// The gate's threshold, quoted from `docs/PLAN_five_tickets_v4.md` line 383.
const double kGate2cBar = 1.107;

/// Committed on purpose, and this is not a detail: `tools/suite-logs/` is in
/// .gitignore, so an artifact left there is invisible to a fresh clone and to
/// CI — the pin would throw on every machine but this one, which is a broken
/// gate wearing a green badge. The evidence a gate rests on has to live where
/// the gate can see it.
const String kEvidenceDir = 'tools/t2/gate_2c';

Map<String, Object?> _artifact(Directory root, String tag) {
  final file = File('${root.path}/$kEvidenceDir/replay_2c_$tag.json');
  if (!file.existsSync()) {
    throw StateError(
      'missing ${file.path} — gate 2c is pinned to a recorded artifact; if it '
      'is gone the gate is unproven again, and re-running the replay is the '
      'only way back. Do not weaken this test to make it pass.',
    );
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

({int runs, int outcomes}) _inputs(Map<String, Object?> artifact) {
  final corpus = artifact['corpus'] as Map<String, Object?>;
  return (runs: corpus['runs']! as int, outcomes: corpus['outcomes']! as int);
}

List<Map<String, Object?>> _epochs(Map<String, Object?> artifact) =>
    (artifact['epochs']! as List<Object?>).cast<Map<String, Object?>>();

double _finalScore(Map<String, Object?> artifact) =>
    (_epochs(artifact).last['score']! as num).toDouble();

void main() {
  final root = repoRoot();

  test('2c the recorded replay over the gate\'s corpus clears the bar', () {
    final s2 = _artifact(root, 'S2');
    final inputs = _inputs(s2);

    // The inputs first. A score is meaningless without them, and asserting
    // them here is what stops a future run over different data from being
    // dropped into the same filename and inheriting this gate.
    expect(inputs.runs, 23, reason: 'the corpus the gate names');
    expect(inputs.outcomes, 272, reason: 'the table as of 2026-08-10');

    final epochs = _epochs(s2);
    expect(epochs.length, 5, reason: 'the gate says five epochs');
    expect(
      (epochs.first['score']! as num).toDouble(),
      1.0,
      reason: 'epoch 0 is the normalization anchor and is exactly 1.0',
    );
    expect(_finalScore(s2), greaterThanOrEqualTo(kGate2cBar));
  });

  test('2c negative control: the same predicate fails on the grown table', () {
    final s1 = _artifact(root, 'S1');
    final s2 = _artifact(root, 'S2');

    // Same corpus, bigger table: the ONLY difference between the two runs.
    expect(_inputs(s1).runs, _inputs(s2).runs);
    expect(_inputs(s1).outcomes, greaterThan(_inputs(s2).outcomes));

    // And on that bigger table the bar is not met. This is the direction that
    // makes the first test mean something.
    expect(
      _finalScore(s1),
      lessThan(kGate2cBar),
      reason:
          'if this ever passes, the bar no longer separates the two runs '
          'and gate 2c needs re-deriving rather than re-asserting',
    );
  });

  test('2c the trend component is flat by construction, not by accident', () {
    // Recorded because it is the finding the measurement bought for free, and
    // because a later reader will otherwise read 1.000000 as a broken score.
    // The detector is built fresh per run and holds no state across epochs
    // (`replay_benchmark.dart` lines 297-299 and 679), so it cannot rise. The
    // plan to make it learnable is v4 section 6, blocked on richer rig rows.
    for (final tag in ['S1', 'S2']) {
      for (final epoch in _epochs(_artifact(root, tag))) {
        final trend = epoch['trendLeadTime']! as Map<String, Object?>;
        expect(
          (trend['normalized']! as num).toDouble(),
          1.0,
          reason:
              '$tag epoch ${epoch['epoch']}: a moving trend score would '
              'mean the detector gained state — welcome, but it invalidates '
              'this note and the epoch-constant claim in the artifact',
        );
      }
    }
  });
}
