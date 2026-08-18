/// CLI wrapper for the offline replay benchmark (the aliveness gate).
///
/// Loads the recorded corpus and the full tsv history, runs N epochs of
/// [ReplayBenchmark] over one persistent [BrainSet], saves the brains
/// after every epoch, and writes the evolution report.
///
/// Usage:
///   dart run tool/intelligence_replay.dart \
///     --epochs 5 --corpus <dir> --tsv <file> --out <file> --brains <dir>
library;

import 'dart:convert';
import 'dart:io';

import 'package:connection_orchestrator/connection_orchestrator.dart';

/// 5: default epoch count — enough to show the rise and the plateau.
const int defaultEpochs = 5;

String? _flag(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}

Never _usageError(String message) {
  stderr.writeln(message);
  stderr.writeln(
    'usage: dart run tool/intelligence_replay.dart '
    '[--epochs N] --corpus DIR --tsv FILE --out FILE --brains DIR',
  );
  exit(2);
}

List<ReplayRun> _loadCorpus(String dirPath) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) _usageError('corpus dir not found: $dirPath');
  final runs = <ReplayRun>[];
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FormatException {
      stderr.writeln('skipping unparseable json: ${file.path}');
      continue;
    }
    if (decoded is! Map<String, Object?>) continue;
    // Non-run files (the corpus index) have no tsvRow and parse to null.
    final run = ReplayRun.fromJson(decoded);
    if (run != null) runs.add(run);
  }
  return runs;
}

void main(List<String> args) {
  final epochs = int.tryParse(_flag(args, '--epochs') ?? '$defaultEpochs');
  final corpusDir = _flag(args, '--corpus');
  final tsvPath = _flag(args, '--tsv');
  final outPath = _flag(args, '--out');
  final brainsDir = _flag(args, '--brains');
  if (epochs == null || epochs < 1) _usageError('--epochs must be >= 1');
  if (corpusDir == null) _usageError('--corpus is required');
  if (tsvPath == null) _usageError('--tsv is required');
  if (outPath == null) _usageError('--out is required');
  if (brainsDir == null) _usageError('--brains is required');

  final tsvFile = File(tsvPath);
  if (!tsvFile.existsSync()) _usageError('tsv not found: $tsvPath');
  final runs = _loadCorpus(corpusDir);
  final outcomes = TsvOutcome.parseTable(tsvFile.readAsStringSync());

  // Synthetic clock for the journal: deterministic, no wall-clock reads.
  var syntheticMs = 0;
  final brains = BrainSet(
    atlas: NetworkAtlas(),
    laneChoice: LaneChoicePolicy(),
    calibrator: BudgetCalibrator(),
    journal: MeasurementJournal(nowMs: () => syntheticMs++),
  );
  final benchmark = ReplayBenchmark(runs: runs, outcomes: outcomes);

  const encoder = JsonEncoder.withIndent(' ');
  final epochReports = <Map<String, Object?>>[];
  for (var epoch = 0; epoch < epochs; epoch++) {
    final report = benchmark.runEpoch(brains);
    epochReports.add(report.toJson());

    final epochDir = Directory('$brainsDir/epoch$epoch')
      ..createSync(recursive: true);
    final brainJson = brains.toJson();
    File(
      '${epochDir.path}/atlas.json',
    ).writeAsStringSync(encoder.convert(brainJson['atlas']));
    File(
      '${epochDir.path}/lane_choice.json',
    ).writeAsStringSync(encoder.convert(brainJson['laneChoice']));
    File(
      '${epochDir.path}/calibrator.json',
    ).writeAsStringSync(encoder.convert(brainJson['calibrator']));

    stdout.writeln(
      'epoch $epoch score ${report.score.toStringAsFixed(3)} '
      '(trend ${report.trendLeadTime.normalized.toStringAsFixed(3)}, '
      'lane ${report.laneChoiceRegret.normalized.toStringAsFixed(3)}, '
      'calib ${report.calibrator.normalized.toStringAsFixed(3)}, '
      'atlas ${report.atlas.normalized.toStringAsFixed(3)})',
    );
  }

  File(outPath).writeAsStringSync(
    encoder.convert({
      'generatedBy': 'connection_orchestrator/tool/intelligence_replay.dart',
      'epochs': epochReports,
      'corpus': {'runs': runs.length, 'outcomes': outcomes.length},
    }),
  );
}
