/// Measures what size-shaping COSTS, against the two numbers the audit pinned
/// for this product:
///
///   media ceiling   200-500 bytes per second   (FINAL-REPORT section 7)
///   framing overhead  headers are 55% of bytes (FINAL-REPORT section 6)
///
/// The merge plan calls step 3 "medium cost" and says plainly that the figure
/// covers writing the code only — the bandwidth cost "has not been measured
/// anywhere". This tool measures it, and also emits a shaped trace in the
/// frozen CSV form so the leak side of the trade can be evaluated by the same
/// gate that produced the unshaped baseline.
///
/// Usage:
///   dart run tool/shaping_cost.dart [frames] [payloadBytes] [outCsv] [rootSeed]
///
/// [rootSeed] exists so a REFERENCE profile can be drawn from the same
/// distribution with an independent seed. Comparing a shaped trace against a
/// reference generated from the SAME seed would be circular — the two files
/// would be identical by construction and the divergence would be zero for a
/// reason that says nothing about shaping.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:seed_lineage/seed_lineage.dart';

/// Bytes per second the media budget allows, from the audit.
const int mediaCeilingLowBps = 200;
const int mediaCeilingHighBps = 500;

/// Share of wire bytes taken by framing headers, from the audit.
const double framingOverheadShare = 0.55;

/// Frames per second the voice path emits. 50 = one frame per 20 ms, which is
/// the tick the transport already uses.
const int framesPerSecond = 50;

void main(List<String> args) {
  final frames = args.isNotEmpty ? int.parse(args[0]) : 1000;
  final payloadBytes = args.length > 1 ? int.parse(args[1]) : 20;
  final outCsv = args.length > 2 ? args[2] : null;
  final rootSeed = args.length > 3 ? int.parse(args[3]) : 1337;

  final manifestHash = Uint8List.fromList(List<int>.generate(32, (i) => i));
  final targets = SizeTargets(rootSeed: rootSeed, manifestHash: manifestHash);

  final payload = Uint8List(payloadBytes);
  var rawTotal = 0;
  var shapedTotal = 0;
  final shapedSizes = <int>[];

  for (var i = 0; i < frames; i++) {
    final target = targets.nextTarget();
    final shaped = padTo(payload, target);
    rawTotal += payload.length;
    shapedTotal += shaped.length;
    shapedSizes.add(shaped.length);
  }

  final rawBps = rawTotal / frames * framesPerSecond;
  final shapedBps = shapedTotal / frames * framesPerSecond;
  final rawWireBps = rawBps / (1 - framingOverheadShare);
  final shapedWireBps = shapedBps / (1 - framingOverheadShare);

  String fits(double bps) => bps <= mediaCeilingHighBps
      ? 'within the ceiling'
      : 'OVER by ${(bps / mediaCeilingHighBps).toStringAsFixed(1)}x';

  stdout
    ..writeln('shaping cost, measured — not estimated')
    ..writeln('  frames                 $frames of $payloadBytes B payload')
    ..writeln('  frame rate             $framesPerSecond/s (20 ms tick)')
    ..writeln('')
    ..writeln('  payload only')
    ..writeln(
      '    mean frame           ${(rawTotal / frames).toStringAsFixed(1)} B',
    )
    ..writeln('    payload rate         ${rawBps.toStringAsFixed(0)} B/s')
    ..writeln(
      '    with 55% framing     ${rawWireBps.toStringAsFixed(0)} B/s  '
      '→ ${fits(rawWireBps)}',
    )
    ..writeln('')
    ..writeln('  shaped (padded to the web-profile targets)')
    ..writeln(
      '    mean frame           ${(shapedTotal / frames).toStringAsFixed(1)} B',
    )
    ..writeln('    payload rate         ${shapedBps.toStringAsFixed(0)} B/s')
    ..writeln(
      '    with 55% framing     ${shapedWireBps.toStringAsFixed(0)} B/s  '
      '→ ${fits(shapedWireBps)}',
    )
    ..writeln('')
    ..writeln(
      '  cost multiplier        '
      '${(shapedTotal / rawTotal).toStringAsFixed(1)}x the bytes',
    )
    ..writeln('')
    ..writeln(
      '  ceiling used: $mediaCeilingLowBps-$mediaCeilingHighBps B/s and a '
      '${(framingOverheadShare * 100).round()}% header share,',
    )
    ..writeln('  both quoted from the product audit, not measured here.');

  if (outCsv != null) {
    final buffer = StringBuffer('size_bytes,direction,delta_us\n');
    const deltaUs = 1000000 ~/ framesPerSecond;
    for (var i = 0; i < shapedSizes.length; i++) {
      buffer.writeln('${shapedSizes[i]},tx,${i == 0 ? 0 : deltaUs}');
    }
    File(outCsv).writeAsStringSync(buffer.toString());
    stdout.writeln('\nwrote ${shapedSizes.length} shaped records to $outCsv');
  }
}
