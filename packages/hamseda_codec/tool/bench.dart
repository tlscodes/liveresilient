// Real-time audit: encode/decode throughput and state size on the
// user's real voice tokens. A frame is 13.3ms of speech — the codec is
// real-time only if per-frame cost stays far under that.
import 'dart:convert';
import 'dart:io';

import 'package:hamseda_codec/hamseda_codec.dart';

void main(List<String> args) {
  final d =
      jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final cols = [for (final c in d['cols'] as List) List<int>.from(c as List)];
  final nRows = d['n_rows'] as int;
  final sec = (d['sec'] as num).toDouble();

  final st = HamsedaState(nRows);
  final sw = Stopwatch()..start();
  final cold = encodeColumns(cols, st);
  final coldMs = sw.elapsedMilliseconds;

  sw.reset();
  final warm = encodeColumns(cols, st);
  final warmMs = sw.elapsedMilliseconds;

  final dec = HamsedaState(nRows);
  sw.reset();
  decodeColumns(cold, cols.length, dec);
  decodeColumns(warm, cols.length, dec);
  final decMs = sw.elapsedMilliseconds;

  final stateBytes = jsonEncode(st.toJson()).length;
  final rtFactorCold = (sec * 1000) / (coldMs == 0 ? 1 : coldMs);
  final rtFactorWarm = (sec * 1000) / (warmMs == 0 ? 1 : warmMs);
  stdout.writeln('frames=${cols.length} audio=${sec.toStringAsFixed(1)}s');
  stdout.writeln(
    'cold encode: ${coldMs}ms  (${rtFactorCold.toStringAsFixed(1)}x real-time)',
  );
  stdout.writeln(
    'warm encode: ${warmMs}ms  (${rtFactorWarm.toStringAsFixed(1)}x real-time)',
  );
  stdout.writeln('decode both: ${decMs}ms');
  stdout.writeln(
    'state size (json): $stateBytes bytes '
    '(${(stateBytes / 1024).toStringAsFixed(1)} KB)',
  );
  stdout.writeln(
    'dict entries: ${st.dict.cols.length} · '
    'ctx tables: ${st.ctx.length} · ctx2 tables: ${st.ctx2.length}',
  );
}
