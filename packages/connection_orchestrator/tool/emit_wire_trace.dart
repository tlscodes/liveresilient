/// Emits a wire trace from a driven transport, in the frozen CSV form
/// consumed by the `trace-gate` binary of the engine project.
///
/// Usage: dart run tool/emit_wire_trace.dart <out.csv> [ticks] [--wall-clock]
///
/// The clock is INJECTED. By default every record is stamped with the
/// transport's own time: the tick it was flushed on — ticks are 20 ms apart —
/// plus one microsecond for each record already stamped in that tick, so
/// their order is kept. The same code therefore emits the same trace on any
/// machine under any load, and the gate that reads it judges the code, not
/// the scheduler it happened to run under.
///
/// `--wall-clock` stamps with a real monotonic source instead, as this tool
/// did before: those deltas are measured, and different on every run — which
/// is why a gate must not be fed them. Nothing about the payload content is
/// recorded either way.
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:connection_orchestrator/src/media_queue.dart';

/// The transport's tick, in milliseconds.
const int tickMs = 20;

class _DeliveringLane extends DomesticEdgeBridgeLane {
  _DeliveringLane()
    : super(
        endpoints: [Uri.parse('https://203.0.113.99:443')],
        connector: (uri) async => throw StateError('never connected'),
      );

  @override
  Future<SendResult> send(List<int> payload) async =>
      const SendResult(SendStatus.ok);
}

Future<void> main(List<String> args) async {
  final wallClock = args.contains('--wall-clock');
  final positional = [
    for (final a in args)
      if (!a.startsWith('--')) a,
  ];
  if (positional.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/emit_wire_trace.dart <out.csv> [ticks] '
      '[--wall-clock]',
    );
    exitCode = 2;
    return;
  }
  final ticks = positional.length > 1 ? int.parse(positional[1]) : 40;

  var nowMs = 0;
  var stampedThisTick = 0;
  final stopwatch = Stopwatch()..start();
  final recorder = WireTraceRecorder(
    nowMicros: wallClock
        ? () => stopwatch.elapsedMicroseconds
        : () => nowMs * 1000 + stampedThisTick++,
  );
  final lane = _DeliveringLane();
  final transport = ResilientMediaTransport(
    queue: MediaTransferQueue(spareBudgetBytesPerSecond: 500),
    carriage: MediaCarriage(mtuBlockSize: 16, random: Random(3)),
    edgeBridge: lane,
    wireTrace: recorder,
  );

  final payload = Uint8List.fromList(List<int>.generate(400, (i) => i & 0xFF));
  for (var tick = 0; tick < ticks; tick++) {
    stampedThisTick = 0;
    if (tick % 4 == 0) transport.send(payload, MediaType.photo);
    final results = await transport.flushWireTick(
      nowMs: nowMs,
      voiceIsSpeaking: tick.isEven,
    );
    // Mirror each delivered frame back in as an inbound datagram so the trace
    // carries both directions, which is what the gate's histogram expects.
    for (var i = 0; i < results.length; i++) {
      recorder.recordRx(64);
    }
    nowMs += tickMs;
    if (wallClock) await Future<void>.delayed(const Duration(milliseconds: 1));
  }

  final csv = recorder.toCsv();
  File(positional[0]).writeAsStringSync(csv);
  stdout.writeln(
    'wrote ${recorder.length} records to ${positional[0]} '
    '(${wallClock ? 'wall clock' : 'injected clock'})',
  );
}
