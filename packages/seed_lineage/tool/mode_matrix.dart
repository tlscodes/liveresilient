/// Sweeps the operating-mode space and reports, for every combination, the
/// measured byte cost and the shaped-size trace it produces.
///
/// WHY THIS EXISTS. The merge plan calls shaping "medium cost" and admits the
/// bandwidth figure was never measured. A single measurement is not enough
/// either: cost and leak move in opposite directions, so the useful answer is
/// the FRONTIER — which combinations buy the most leak reduction per byte.
///
/// WHAT THE NUMBERS MEAN, precisely — this matters because an earlier pass got
/// it wrong. The 200-500 B/s figure in the audit is the SPARE MEDIA budget
/// (media_queue.dart:1-8, :53-57): background file/photo transfer, emitted only
/// while the voice path is silent. It is NOT the voice budget. The voice path
/// has no configured byte budget in this repo at all. So this tool reports the
/// raw wire rate each combination costs and leaves the comparison to whatever
/// budget the reader actually has; it prints the spare-media band only as a
/// reference line, labelled as such.
///
/// Dimensions swept:
///   frameRate      frames per second on the voice path
///   shapedShare    fraction of frames padded to a web-profile target
///   payloadBytes   bytes of real payload per frame
///   fanout         copies sent per frame (path_selector.dart:185-188 sends the
///                  FULL payload to every channel in a fanout batch, so this is
///                  a straight multiplier; NetworkConditionPolicy uses 1, 2, 3)
///
/// Usage: dart run tool/mode_matrix.dart [outDir]
/// Writes one CSV trace per combination into outDir so trace-gate can score
/// each one, and prints the cost table.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:seed_lineage/seed_lineage.dart';

/// Reference band only — the SPARE MEDIA budget, not the voice budget.
const int spareMediaLowBps = 200;
const int spareMediaHighBps = 500;

/// Share of wire bytes taken by framing headers, from the audit.
const double framingOverheadShare = 0.55;

/// How many frames each combination is measured over. Large enough that the
/// shaped mean is stable: the target distribution has a heavy 200-1400 B mode
/// that a short run samples badly.
const int framesPerCombination = 4000;

const List<int> frameRates = [50, 25, 12, 6];
const List<double> shapedShares = [0.0, 0.25, 0.5, 1.0];
const List<int> payloadSizes = [20, 40];
const List<int> fanouts = [1, 2, 3];

class Combination {
  Combination(this.frameRate, this.shapedShare, this.payloadBytes, this.fanout);
  final int frameRate;
  final double shapedShare;
  final int payloadBytes;
  final int fanout;

  String get id =>
      'fr${frameRate}_sh${(shapedShare * 100).round()}_pl${payloadBytes}_fo$fanout';
}

class Result {
  Result(this.combination, this.meanFrameBytes, this.wireBps, this.sizes);
  final Combination combination;
  final double meanFrameBytes;
  final double wireBps;
  final List<int> sizes;
}

Result measure(Combination c) {
  final manifestHash = Uint8List.fromList(List<int>.generate(32, (i) => i));
  final targets = SizeTargets(rootSeed: 1337, manifestHash: manifestHash);
  // A second, independent stream decides WHICH frames get shaped, so the
  // choice is reproducible without consuming targets for unshaped frames —
  // which would silently change the target sequence between shares.
  final chooser = SeedStream.forPath(
    rootSeed: 20260801,
    manifestHash: manifestHash,
    logicalPath: 'matrix/shaped-share/v1',
  );

  final payload = Uint8List(c.payloadBytes);
  final sizes = <int>[];
  var total = 0;

  for (var i = 0; i < framesPerCombination; i++) {
    final shapeThis = chooser.nextBelow(1000) < (c.shapedShare * 1000).round();
    final bytes = shapeThis
        ? padTo(payload, targets.nextTarget()).length
        : payload.length;
    // Fanout duplicates the whole payload per extra channel.
    for (var copy = 0; copy < c.fanout; copy++) {
      sizes.add(bytes);
      total += bytes;
    }
  }

  final meanFrame = total / framesPerCombination;
  final payloadBps = meanFrame * c.frameRate;
  final wireBps = payloadBps / (1 - framingOverheadShare);
  return Result(c, meanFrame, wireBps, sizes);
}

void writeTrace(String dir, Result r) {
  final deltaUs = 1000000 ~/ r.combination.frameRate;
  final buffer = StringBuffer('size_bytes,direction,delta_us\n');
  for (var i = 0; i < r.sizes.length; i++) {
    buffer.writeln('${r.sizes[i]},tx,${i == 0 ? 0 : deltaUs}');
  }
  File('$dir/${r.combination.id}.csv').writeAsStringSync(buffer.toString());
}

void main(List<String> args) {
  final outDir = args.isNotEmpty ? args[0] : '.';
  Directory(outDir).createSync(recursive: true);

  final results = <Result>[];
  for (final fr in frameRates) {
    for (final sh in shapedShares) {
      for (final pl in payloadSizes) {
        for (final fo in fanouts) {
          final r = measure(Combination(fr, sh, pl, fo));
          results.add(r);
          writeTrace(outDir, r);
        }
      }
    }
  }

  stdout
    ..writeln(
      'mode matrix — ${results.length} combinations, '
      '$framesPerCombination frames each',
    )
    ..writeln(
      'reference band (SPARE MEDIA budget, not the voice budget): '
      '$spareMediaLowBps-$spareMediaHighBps B/s',
    )
    ..writeln('')
    ..writeln('id                       mean_frame_B   wire_B/s   x_over_500')
    ..writeln('${'-' * 62}');

  results.sort((a, b) => a.wireBps.compareTo(b.wireBps));
  for (final r in results) {
    final over = r.wireBps / spareMediaHighBps;
    stdout.writeln(
      '${r.combination.id.padRight(24)}'
      '${r.meanFrameBytes.toStringAsFixed(1).padLeft(12)}'
      '${r.wireBps.toStringAsFixed(0).padLeft(11)}'
      '${over.toStringAsFixed(1).padLeft(13)}',
    );
  }

  stdout.writeln('\ntraces written to $outDir — score each with trace-gate');
}
