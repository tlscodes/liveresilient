/// Pins this evaluator against the Rust one it was written from.
///
/// Two implementations of the same specification agreeing is a much stronger
/// statement than either passing its own tests, which is why this gate was
/// re-implemented rather than the Rust binary vendored. The expectations below
/// are the Rust evaluator's own output, recorded on 2026-09-02 by running it on
/// these exact inputs:
///
///   cargo run -q -p trace-gate -- <observed> <reference> --kl-threshold T
///
/// The committed baseline in `tools/leak_gate_baseline.env` corroborates it
/// independently: kl = 0.997831 was measured with the Rust evaluator on
/// 2026-08-01, a month before this file existed, and this implementation
/// reproduces it to six decimals.
///
/// If a test here fails, the two implementations have diverged. That is the
/// alarm — do not adjust an expectation to silence it.
library;

import 'dart:io';

import 'package:test/test.dart';

import '../bin/trace_gate.dart';

/// Repository root, from this file's location.
final String _repo = Directory.current.path.endsWith('tools/trace_gate')
    ? Directory.current.parent.parent.path
    : Directory.current.path;

String get _reference => '$_repo/tools/leak_gate_reference_synthetic.csv';

List<String> _capture(List<String> argv, void Function(int) onCode) {
  final lines = <String>[];
  onCode(run(argv, out: lines.add));
  return lines;
}

void main() {
  group('CSV contract', () {
    test('rejects a wrong header rather than guessing', () {
      expect(
        () => parseCsv('a,b,c\n1,tx,0\n', 'x.csv'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a direction that is neither tx nor rx', () {
      expect(
        () => parseCsv('size_bytes,direction,delta_us\n10,up,0\n', 'x.csv'),
        throwsA(isA<FormatException>()),
      );
    });

    test('drops only the first delta, which is a placeholder', () {
      final rs = parseCsv(
        'size_bytes,direction,delta_us\n1,tx,0\n2,rx,50\n3,tx,60\n',
        'x.csv',
      );
      expect(interArrivals(rs), [50, 60]);
    });
  });

  group('histogram', () {
    test('clamps out-of-range values instead of dropping them', () {
      // Mass must be conserved or the divergence stops being comparable.
      final h = histogram([-100, 0, 750, 1500, 9999], 3, 0, 1500);
      expect(h.fold<int>(0, (a, b) => a + b), 5);
      expect(h.first, 2); // -100 clamps to lo, 0 lands in the first bin
      expect(h.last, 2); // 1500 is the top edge, 9999 clamps onto it
    });

    test('divergence of a series against itself is zero', () {
      final h = histogram([10, 20, 30, 1000], 8, 0, 1500);
      expect(klDivergence(h, h, 0.5), closeTo(0.0, 1e-12));
    });

    test('rejects mismatched shapes and non-positive smoothing', () {
      final a = histogram([1], 4, 0, 10);
      final b = histogram([1], 8, 0, 10);
      expect(klDivergence(a, b, 0.5), isNull);
      expect(klDivergence(a, a, 0.0), isNull);
    });
  });

  group('spectral scan', () {
    test('a strongly periodic series exceeds a low threshold', () {
      final periodic = [for (var i = 0; i < 32; i++) i.isEven ? 100 : 900];
      final v = scanForPeriodicPeak(periodic, 8.0);
      expect(v.peakRatio, greaterThan(8.0));
      expect(v.isClean, isFalse);
    });

    test('needs at least four samples', () {
      expect(() => scanForPeriodicPeak([1, 2, 3], 8.0), throwsArgumentError);
    });
  });

  group('CROSS-CHECK against the Rust evaluator — do not edit to pass', () {
    test('reference against itself matches rustc output exactly', () {
      var code = -1;
      final out = _capture([_reference, _reference], (c) => code = c);
      expect(code, 0);
      expect(out, contains('kl                 = 0.000000 nats'));
      expect(
        out,
        contains(
          'spectral peak_bin  = 72  peak_ratio = 5.520067  '
          'threshold = 8.000000  clean = true',
        ),
      );
    });

    test('an emitted trace reproduces the 2026-08-01 committed baseline', () {
      // tools/leak_gate_baseline.env records BASELINE_KL=0.997831, measured
      // with the Rust evaluator against this reference at 60 emitter ticks.
      final observed = File(
        '$_repo/tools/trace_gate/test/fixture_observed.csv',
      );
      if (!observed.existsSync()) {
        markTestSkipped('fixture missing — regenerate with emit_wire_trace');
        return;
      }
      var code = -1;
      final out = _capture([
        observed.path,
        _reference,
        '--kl-threshold',
        '1.097831',
      ], (c) => code = c);
      expect(code, 0);
      expect(out, contains('kl                 = 0.997831 nats'));
      expect(
        out,
        contains(
          'spectral peak_bin  = 10  peak_ratio = 7.620473  '
          'threshold = 8.000000  clean = true',
        ),
      );
    });
  });
}
