// Measures warm independent-block sizes for various block lengths, so
// the micro-datagram window can be sized from data, not guesses.
import 'dart:convert';
import 'dart:io';

import 'package:hamseda_codec/hamseda_codec.dart';

void main(List<String> args) {
  final d = jsonDecode(File(args[0]).readAsStringSync())
      as Map<String, dynamic>;
  final cols = [for (final c in d['cols'] as List) List<int>.from(c as List)];
  final warmSrc = HamsedaState(d['n_rows'] as int);
  encodeColumns(cols, warmSrc);
  final warm = HamsedaState.fromJson(warmSrc.toJson());
  for (final n in [3, 5, 8, 10, 15, 25, 40, 75]) {
    var total = 0;
    var count = 0;
    for (var i = 0; i + n <= cols.length; i += n) {
      total += encodeColumns(cols.sublist(i, i + n), warm.clone()).length;
      count++;
    }
    final avg = total / count;
    stdout.writeln('block=$n frames (${(n / 75 * 1000).round()}ms): '
        'avg ${avg.toStringAsFixed(1)} B  '
        '(${(avg * 8 * 75 / n).toStringAsFixed(0)} bps)');
  }
}
