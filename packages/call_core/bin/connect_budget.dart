/// Prints the connect budget for a set of network conditions.
///
/// The test harness needs the same number the app computes, to size its own
/// wall-clock timeout. Rather than transcribe the formula into shell — where it
/// would drift the first time either side changed — the shell asks this.
///
///     dart run call_core:connect_budget --rtt-ms=1800 --loss=0.6
///     dart run call_core:connect_budget --rtt-ms=4 --bandwidth-bps=16000
///
/// Prints, one per line: `budget_s`, `attempt_s`, `expected_connect_s`,
/// `max_attempts`. `--field=budget_s` prints just that value, for `$(...)`.
library;

import 'dart:io';

import 'package:call_core/call_core.dart';

int? _intArg(List<String> args, String name) {
  final prefix = '--$name=';
  for (final a in args) {
    if (a.startsWith(prefix)) return int.tryParse(a.substring(prefix.length));
  }
  return null;
}

double? _doubleArg(List<String> args, String name) {
  final prefix = '--$name=';
  for (final a in args) {
    if (a.startsWith(prefix)) {
      return double.tryParse(a.substring(prefix.length));
    }
  }
  return null;
}

String? _stringArg(List<String> args, String name) {
  final prefix = '--$name=';
  for (final a in args) {
    if (a.startsWith(prefix)) return a.substring(prefix.length);
  }
  return null;
}

void main(List<String> args) {
  final budget = AdaptiveConnectionBudget.fromConditions(
    NetworkConditions(
      rtt: Duration(milliseconds: _intArg(args, 'rtt-ms') ?? 0),
      loss: _doubleArg(args, 'loss') ?? 0,
      bandwidthBps: _intArg(args, 'bandwidth-bps'),
    ),
  );

  // Ceiling, not rounding: a budget printed as 55s when the model says 55.2s
  // would cut the last attempt short, which is the whole class of bug here.
  int ceilSeconds(Duration d) => (d.inMilliseconds + 999) ~/ 1000;

  final fields = <String, String>{
    'budget_s': '${ceilSeconds(budget.maxElapsed)}',
    'attempt_s': '${ceilSeconds(budget.attemptCost)}',
    'expected_connect_s': '${ceilSeconds(budget.expectedConnectBy)}',
    'max_attempts': '${budget.maxAttempts}',
  };

  final only = _stringArg(args, 'field');
  if (only != null) {
    final value = fields[only];
    if (value == null) {
      stderr.writeln(
        'unknown field "$only"; '
        'known: ${fields.keys.join(', ')}',
      );
      exit(2);
    }
    stdout.writeln(value);
    return;
  }
  fields.forEach((k, v) => stdout.writeln('$k=$v'));
}
