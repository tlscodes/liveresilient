/// CLI runner for the structured-mutation fuzz engine (Phase 11 security
/// slice). Runs every registered parser target for a fixed, seeded
/// iteration count and prints one JSON summary line per target.
///
/// Usage:
///   dart run tool/fuzz/fuzz_parsers.dart --target all --iterations 50000 --seed 7
///   dart run tool/fuzz/fuzz_parsers.dart --target envelope --iterations 1000 --seed 1
///
/// Exit code is non-zero iff any target recorded a non-contract exception
/// (a hang cannot be caught here — CI should also apply a wall-clock
/// timeout around the whole invocation).
library;

import 'dart:convert';
import 'dart:io';

import 'fuzz_engine.dart';
import 'targets_device_link.dart';
import 'targets_signaling_server.dart';
import 'targets_signed_config.dart';

List<FuzzTarget> _allTargets() => [
  ...deviceLinkFuzzTargets(),
  ...signedConfigFuzzTargets(),
  ...signalingServerFuzzTargets(),
];

Future<void> main(List<String> args) async {
  var targetFilter = 'all';
  var iterations = 10000;
  var seed = 1;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--target':
        targetFilter = args[++i];
      case '--iterations':
        iterations = int.parse(args[++i]);
      case '--seed':
        seed = int.parse(args[++i]);
      default:
        stderr.writeln('Unknown argument: ${args[i]}');
        _usage();
        exit(64);
    }
  }

  final allTargets = _allTargets();
  final selected = targetFilter == 'all'
      ? allTargets
      : allTargets.where((t) => t.name == targetFilter).toList();

  if (selected.isEmpty) {
    stderr.writeln(
      'No target named "$targetFilter". Known targets: '
      '${allTargets.map((t) => t.name).join(', ')}',
    );
    exit(64);
  }

  var anyOtherExceptions = false;
  for (final target in selected) {
    final summary = await runFuzzTarget(
      target,
      iterations: iterations,
      seed: seed,
    );
    stdout.writeln(
      jsonEncode({
        'target': summary.target,
        'iterations': summary.iterations,
        'contractRejects': summary.rejects,
        'accepts': summary.accepts,
        'otherExceptions': summary.otherExceptions,
        'elapsedMs': summary.elapsedMs,
        if (summary.failures.isNotEmpty)
          'failures': [for (final f in summary.failures) f.toJson()],
      }),
    );
    if (summary.otherExceptions > 0) anyOtherExceptions = true;
  }

  exit(anyOtherExceptions ? 1 : 0);
}

void _usage() {
  stderr.writeln(
    'Usage: dart run tool/fuzz/fuzz_parsers.dart '
    '[--target all|<name>] [--iterations N] [--seed N]',
  );
}
