/// Aliveness gate on the REAL recorded corpus: epoch 0 normalizes to
/// exactly 1.0, epoch 1 must strictly beat it (the brains carried
/// experience), later epochs may plateau but never drop beyond numeric
/// noise, and the three persistent brains round-trip through JSON with
/// raw scores unchanged.
import 'dart:convert';
import 'dart:io';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:test/test.dart';

/// Walks up from [start] until a directory containing tools/t2 appears.
Directory? _repoRootFrom(Directory start) {
  var dir = start.absolute;
  while (true) {
    if (Directory('${dir.path}/tools/t2/replay_corpus').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

/// Robust to running from the package root or the repo root: tries the
/// working directory first, then the test script's own location.
Directory _repoRoot() {
  final fromCwd = _repoRootFrom(Directory.current);
  if (fromCwd != null) return fromCwd;
  final scriptDir = File.fromUri(Platform.script).parent;
  final fromScript = _repoRootFrom(scriptDir);
  if (fromScript != null) return fromScript;
  throw StateError(
    'tools/t2/replay_corpus not found above ${Directory.current.path} '
    'or ${scriptDir.path}',
  );
}

List<ReplayRun> _loadCorpus(Directory root) {
  final dir = Directory('${root.path}/tools/t2/replay_corpus');
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final file in files)
      if (jsonDecode(file.readAsStringSync())
          case final Map<String, Object?> decoded)
        if (ReplayRun.fromJson(decoded) case final ReplayRun run) run,
  ];
}

BrainSet _freshBrains() {
  var syntheticMs = 0;
  return BrainSet(
    atlas: NetworkAtlas(),
    laneChoice: LaneChoicePolicy(),
    calibrator: BudgetCalibrator(),
    journal: MeasurementJournal(nowMs: () => syntheticMs++),
  );
}

void main() {
  final root = _repoRoot();
  final runs = _loadCorpus(root);
  final outcomes = TsvOutcome.parseTable(
    File('${root.path}/tools/t2/h2_results.tsv').readAsStringSync(),
  );

  test('corpus loaded: the recorded history is actually present', () {
    // 23 corpus captures and 262 15-col + 10 early 9-col tsv rows were
    // recorded when this gate was built; the corpus only ever grows.
    expect(runs.length, greaterThanOrEqualTo(23));
    expect(outcomes.length, greaterThanOrEqualTo(272));
  });

  test('aliveness gate: epoch 1 strictly beats epoch 0, no later drop', () {
    final benchmark = ReplayBenchmark(runs: runs, outcomes: outcomes);
    final brains = _freshBrains();
    // 3: epoch 0 baseline + the mandatory rise + one plateau check.
    final reports = [for (var e = 0; e < 3; e++) benchmark.runEpoch(brains)];

    final epoch0 = reports[0];
    expect(epoch0.trendLeadTime.normalized, equals(1.0));
    expect(epoch0.laneChoiceRegret.normalized, equals(1.0));
    expect(epoch0.calibrator.normalized, equals(1.0));
    expect(epoch0.atlas.normalized, equals(1.0));
    expect(epoch0.score, equals(1.0));

    // 1e-9: strict-rise epsilon — the aliveness gate itself.
    expect(
      reports[1].score,
      greaterThan(1.0 + 1e-9),
      reason:
          'epoch 1 must beat epoch 0: the persistent brains carried '
          'no usable experience across the replay',
    );
    for (var e = 2; e < reports.length; e++) {
      // 0.005: numerical-noise allowance — a plateau is fine, a real
      // drop is red.
      expect(
        reports[e].score,
        greaterThanOrEqualTo(reports[e - 1].score - 0.005),
        reason: 'epoch $e dropped more than noise below epoch ${e - 1}',
      );
    }

    // The detector component is epoch-constant by design and the report
    // must say so.
    expect(reports[1].trendLeadTime.raw, equals(epoch0.trendLeadTime.raw));
    expect(reports[0].notes.join(' '), contains('epoch-constant'));
  });

  test('brain JSONs round-trip through BrainSet with scores unchanged', () {
    final benchmark = ReplayBenchmark(runs: runs, outcomes: outcomes);
    final brains = _freshBrains();
    // 2: train through two epochs so all three brains hold real state.
    benchmark.runEpoch(brains);
    benchmark.runEpoch(brains);

    final saved = jsonEncode(brains.toJson());
    final restored = BrainSet.fromJson(
      jsonDecode(saved) as Map<String, Object?>,
      journal: _freshBrains().journal,
    );
    // Byte-identical re-serialization: nothing was lost or reordered.
    expect(jsonEncode(restored.toJson()), equals(saved));

    // The next epoch scores the same whether it runs on the live brains
    // or on the restored copy (raw component scores compared — the
    // normalized ones intentionally re-baseline in a fresh benchmark).
    final continued = benchmark.runEpoch(brains);
    final replayed = ReplayBenchmark(
      runs: runs,
      outcomes: outcomes,
    ).runEpoch(restored);
    expect(replayed.trendLeadTime.raw, equals(continued.trendLeadTime.raw));
    expect(
      replayed.laneChoiceRegret.raw,
      equals(continued.laneChoiceRegret.raw),
    );
    expect(replayed.calibrator.raw, equals(continued.calibrator.raw));
    expect(replayed.atlas.raw, equals(continued.atlas.raw));
  });

  test('epoch report serializes with every component present', () {
    final benchmark = ReplayBenchmark(runs: runs, outcomes: outcomes);
    final report = benchmark.runEpoch(_freshBrains());
    final json = report.toJson();
    expect(json['epoch'], equals(0));
    for (final key in [
      'trendLeadTime',
      'laneChoiceRegret',
      'calibrator',
      'atlas',
    ]) {
      final component = json[key];
      expect(component, isA<Map<String, Object?>>(), reason: key);
      final map = component as Map<String, Object?>;
      expect(map['raw'], isA<double>(), reason: key);
      expect(map['normalized'], equals(1.0), reason: key);
    }
    expect(json['whatChanged'], isA<List<String>>());
    // Every whatChanged line cites the journal id it logged.
    for (final line in report.whatChanged) {
      expect(line, matches(r'\[m\d+\]$'), reason: line);
    }
  });
}
