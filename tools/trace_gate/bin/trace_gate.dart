/// A second implementation of the on-wire leakage gate, so it can run here.
///
/// The gate itself is not new: a Rust evaluator has existed in a separate
/// engine repository since 2026-08. That repository is not published, so
/// `tools/leak_gate.sh` has been exiting 3 — NOT RUN — on every CI run since
/// this project went public. The workflow surfaced that honestly as a warning
/// rather than a pass, which is why it was findable at all, but a gate nobody
/// can execute is a gate that measures nothing.
///
/// This is the same evaluation, written from the Rust source's algorithm rather
/// than transliterated, in a language this repository already builds. Two
/// independent implementations agreeing on the committed fixtures is a stronger
/// statement than either alone — the same reason the safety number's golden
/// vector was derived twice. `tools/trace_gate/test/cross_check_test.dart`
/// pins the agreement.
///
/// What it measures, and what it does not: how distinguishable an observed
/// trace is from a reference profile, by two measures — the KL divergence of
/// the packet-size histogram, and a spectral scan of inter-arrival times for a
/// periodic tell. The reference committed in this repository is SYNTHETIC. A
/// pass is a no-regression signal against a recorded baseline, not evidence of
/// resistance to real traffic analysis, and the gate script says so on every
/// run.
///
/// CSV contract, frozen and shared with the Rust implementation: UTF-8, LF, a
/// header line `size_bytes,direction,delta_us`, then one record per line.
/// `delta_us` is microseconds since the previous record; the first record's
/// value is a placeholder 0 and is excluded from the inter-arrival series.
///
/// Exit codes match the Rust CLI exactly, because the shell script branches on
/// them: 0 gate passes, 1 gate fails, 2 usage or parse error.
library;

import 'dart:io';
import 'dart:math' as math;

// Frozen defaults. These are the Rust CLI's constants; changing one here
// without changing it there would make the two implementations disagree, which
// the cross-check test would catch.
const int defaultNBins = 32;
const double defaultSizeLo = 0.0;
const double defaultSizeHi = 1500.0; // typical Ethernet MTU upper edge
const double defaultAlpha = 0.5; // Laplace smoothing
const double defaultKlThreshold = 0.25; // nats
const double defaultSpectralThreshold = 8.0; // peak-to-mean power ratio

const String _usage = '''
usage: trace_gate <observed.csv> <reference.csv>
         [--n-bins N] [--size-lo F] [--size-hi F] [--alpha F]
         [--kl-threshold F] [--spectral-threshold F]
''';

class Record {
  const Record(this.sizeBytes, this.deltaUs);
  final int sizeBytes;
  final int deltaUs;
}

/// A fixed-edge histogram. The edges are frozen so two series binned for
/// comparison share an axis, which KL divergence requires.
///
/// Values are clamped into range rather than dropped, so mass is conserved and
/// the divergence stays finite.
List<int> histogram(List<double> series, int nBins, double lo, double hi) {
  if (nBins < 1) throw ArgumentError('nBins must be >= 1');
  if (hi <= lo) throw ArgumentError('hi must exceed lo');
  final counts = List<int>.filled(nBins, 0);
  final span = hi - lo;
  for (final x in series) {
    final clamped = x < lo ? lo : (x > hi ? hi : x);
    var idx = ((clamped - lo) / span * nBins).toInt();
    if (idx >= nBins) idx = nBins - 1; // the top edge falls in the last bin
    counts[idx] += 1;
  }
  return counts;
}

/// Laplace-smoothed probabilities: alpha is added to every bin so none is zero,
/// which KL requires of the reference side.
List<double> _smoothed(List<int> counts, double alpha) {
  final total = counts.fold<int>(0, (a, b) => a + b);
  final denom = total + alpha * counts.length;
  return [for (final c in counts) (c + alpha) / denom];
}

/// KL(observed || reference) in nats. Null if the shapes disagree or alpha is
/// not positive — the same rejection the Rust version reports.
double? klDivergence(List<int> observed, List<int> reference, double alpha) {
  if (observed.length != reference.length || alpha <= 0.0) return null;
  final p = _smoothed(observed, alpha);
  final q = _smoothed(reference, alpha);
  var kl = 0.0;
  for (var i = 0; i < p.length; i++) {
    kl += p[i] * math.log(p[i] / q[i]);
  }
  // Non-negative in exact arithmetic; clamp floating-point noise.
  return kl < 0.0 ? 0.0 : kl;
}

class SpectralVerdict {
  const SpectralVerdict(this.peakBin, this.peakRatio, this.threshold);
  final int peakBin;
  final double peakRatio;
  final double threshold;
  bool get isClean => peakRatio <= threshold;
}

/// Scans an inter-arrival series for a periodic component, by the peak-to-mean
/// ratio of the discrete Fourier power spectrum of the mean-centred series.
///
/// A direct transform rather than a fast one: the traces this gates are tens of
/// records, the shape must match the reference implementation exactly, and an
/// FFT's bit-reversal ordering is one more place for the two to diverge.
SpectralVerdict scanForPeriodicPeak(List<int> delaysUs, double threshold) {
  final n = delaysUs.length;
  if (n < 4) throw ArgumentError('need at least 4 samples for a spectral scan');
  final mean = delaysUs.fold<double>(0, (a, b) => a + b) / n;
  final centered = [for (final d in delaysUs) d - mean];

  final half = n ~/ 2;
  final powers = <double>[];
  for (var k = 1; k <= half; k++) {
    var re = 0.0;
    var im = 0.0;
    for (var t = 0; t < centered.length; t++) {
      final angle = -2.0 * math.pi * k * t / n;
      re += centered[t] * math.cos(angle);
      im += centered[t] * math.sin(angle);
    }
    powers.add(re * re + im * im);
  }

  final total = powers.fold<double>(0, (a, b) => a + b);
  final meanPower = total / powers.length;
  var peakBin = 0;
  var peakPower = 0.0;
  for (var i = 0; i < powers.length; i++) {
    if (powers[i] > peakPower) {
      peakPower = powers[i];
      peakBin = i + 1;
    }
  }
  final peakRatio = meanPower > 0.0 ? peakPower / meanPower : 0.0;
  return SpectralVerdict(peakBin, peakRatio, threshold);
}

/// Parses the frozen CSV. Throws [FormatException] with the offending line, so
/// a malformed fixture is a usage error rather than a wrong verdict.
List<Record> parseCsv(String text, String path) {
  final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
  if (lines.isEmpty) throw FormatException('$path: empty');
  final header = lines.first.trim();
  if (header != 'size_bytes,direction,delta_us') {
    throw FormatException('$path: unexpected header: $header');
  }
  final records = <Record>[];
  for (var i = 1; i < lines.length; i++) {
    final parts = lines[i].trim().split(',');
    if (parts.length != 3) {
      throw FormatException('$path:${i + 1}: expected 3 fields: ${lines[i]}');
    }
    final size = int.tryParse(parts[0]);
    final delta = int.tryParse(parts[2]);
    if (size == null || delta == null) {
      throw FormatException('$path:${i + 1}: non-numeric field: ${lines[i]}');
    }
    if (parts[1] != 'tx' && parts[1] != 'rx') {
      throw FormatException('$path:${i + 1}: direction must be tx or rx');
    }
    records.add(Record(size, delta));
  }
  return records;
}

/// The first record's delta is a placeholder, not a measured gap.
List<int> interArrivals(List<Record> records) => [
  for (var i = 1; i < records.length; i++) records[i].deltaUs,
];

int run(List<String> argv, {required void Function(String) out}) {
  final positional = <String>[];
  var nBins = defaultNBins;
  var sizeLo = defaultSizeLo;
  var sizeHi = defaultSizeHi;
  var alpha = defaultAlpha;
  var klThreshold = defaultKlThreshold;
  var spectralThreshold = defaultSpectralThreshold;

  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (!a.startsWith('--')) {
      positional.add(a);
      continue;
    }
    if (i + 1 >= argv.length) {
      out('$a: missing value\n$_usage');
      return 2;
    }
    final v = argv[++i];
    switch (a) {
      case '--n-bins':
        final parsed = int.tryParse(v);
        if (parsed == null) {
          out('$a: not an integer\n$_usage');
          return 2;
        }
        nBins = parsed;
      case '--size-lo':
      case '--size-hi':
      case '--alpha':
      case '--kl-threshold':
      case '--spectral-threshold':
        final parsed = double.tryParse(v);
        if (parsed == null) {
          out('$a: not a number\n$_usage');
          return 2;
        }
        switch (a) {
          case '--size-lo':
            sizeLo = parsed;
          case '--size-hi':
            sizeHi = parsed;
          case '--alpha':
            alpha = parsed;
          case '--kl-threshold':
            klThreshold = parsed;
          default:
            spectralThreshold = parsed;
        }
      default:
        out('unknown flag: $a\n$_usage');
        return 2;
    }
  }

  if (positional.length != 2) {
    out(_usage);
    return 2;
  }
  if (nBins < 1 || sizeHi <= sizeLo || alpha <= 0.0) {
    out(
      'invalid params: need n_bins >= 1, size_hi > size_lo, alpha > 0\n$_usage',
    );
    return 2;
  }

  final List<Record> observed;
  final List<Record> reference;
  try {
    observed = parseCsv(File(positional[0]).readAsStringSync(), positional[0]);
    reference = parseCsv(File(positional[1]).readAsStringSync(), positional[1]);
  } on FormatException catch (e) {
    out('${e.message}');
    return 2;
  } on FileSystemException catch (e) {
    out('${e.path}: ${e.message}');
    return 2;
  }

  final deltas = interArrivals(observed);
  if (deltas.length < 4) {
    out(
      '${positional[0]}: need at least 5 records '
      '(4 inter-arrival gaps) for the spectral scan',
    );
    return 2;
  }

  final obs = histogram(
    [for (final r in observed) r.sizeBytes.toDouble()],
    nBins,
    sizeLo,
    sizeHi,
  );
  final ref = histogram(
    [for (final r in reference) r.sizeBytes.toDouble()],
    nBins,
    sizeLo,
    sizeHi,
  );
  final kl = klDivergence(obs, ref, alpha);
  if (kl == null) {
    out('evaluate rejected the parameters');
    return 2;
  }
  final spectral = scanForPeriodicPeak(deltas, spectralThreshold);

  out('kl                 = ${kl.toStringAsFixed(6)} nats');
  out('kl_threshold       = ${klThreshold.toStringAsFixed(6)}');
  out(
    'spectral peak_bin  = ${spectral.peakBin}  '
    'peak_ratio = ${spectral.peakRatio.toStringAsFixed(6)}  '
    'threshold = ${spectral.threshold.toStringAsFixed(6)}  '
    'clean = ${spectral.isClean}',
  );

  final passes = kl <= klThreshold && spectral.isClean;
  out(passes ? 'GATE PASS' : 'GATE FAIL');
  return passes ? 0 : 1;
}

void main(List<String> argv) {
  exitCode = run(argv, out: stdout.writeln);
}
