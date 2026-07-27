// Cross-language parity probe: encode the user's real voice tokens
// (dumped by tools/dump_tokens.py) and print sizes + FNV-1a hashes of
// the cold and warm encodings for comparison with the Python reference.
import 'dart:convert';
import 'dart:io';

import 'package:hamseda_codec/hamseda_codec.dart';

String fnv(List<int> bytes) {
  var h = 0xcbf29ce484222325;
  for (final b in bytes) {
    h ^= b;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return (BigInt.from(h) & BigInt.parse('FFFFFFFFFFFFFFFF', radix: 16))
      .toRadixString(16);
}

void main(List<String> args) {
  final d =
      jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final cols = [for (final c in d['cols'] as List) List<int>.from(c as List)];
  final nRows = d['n_rows'] as int;
  final sec = (d['sec'] as num).toDouble();
  final st = HamsedaState(nRows);
  final cold = encodeColumns(cols, st);
  final dec = HamsedaState(nRows);
  final out = decodeColumns(cold, cols.length, dec);
  var exact = true;
  for (var i = 0; i < cols.length; i++) {
    for (var r = 0; r < nRows; r++) {
      if (out[i][r] != cols[i][r]) exact = false;
    }
  }
  final warm = encodeColumns(cols, st);
  stdout.writeln('bit_exact=$exact');
  stdout.writeln('cold_bytes=${cold.length} fnv=${fnv(cold)}');
  stdout.writeln('warm_bytes=${warm.length} fnv=${fnv(warm)}');
  stdout.writeln(
    'cold_bps=${(cold.length * 8 / sec).toStringAsFixed(1)} '
    'warm_bps=${(warm.length * 8 / sec).toStringAsFixed(1)}',
  );
}
