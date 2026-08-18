/// Emits a real wire trace from a driven transport, in the frozen CSV form
/// consumed by the `trace-gate` binary of the engine project.
///
/// Usage: dart run tool/emit_wire_trace.dart <out.csv> [ticks]
///
/// The clock is a real monotonic microsecond source here (unlike the unit
/// tests, which inject a fake one), so the emitted deltas are measured, not
/// scripted. Nothing about the payload content is recorded.
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:connection_orchestrator/src/media_queue.dart';

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
  if (args.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/emit_wire_trace.dart <out.csv> [ticks]',
    );
    exitCode = 2;
    return;
  }
  final ticks = args.length > 1 ? int.parse(args[1]) : 40;
  final stopwatch = Stopwatch()..start();
  final recorder = WireTraceRecorder(
    nowMicros: () => stopwatch.elapsedMicroseconds,
  );
  final lane = _DeliveringLane();
  final transport = ResilientMediaTransport(
    queue: MediaTransferQueue(spareBudgetBytesPerSecond: 500),
    carriage: MediaCarriage(mtuBlockSize: 16, random: Random(3)),
    edgeBridge: lane,
    wireTrace: recorder,
  );

  final payload = Uint8List.fromList(List<int>.generate(400, (i) => i & 0xFF));
  var nowMs = 0;
  for (var tick = 0; tick < ticks; tick++) {
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
    nowMs += 20;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }

  final csv = recorder.toCsv();
  File(args[0]).writeAsStringSync(csv);
  stdout.writeln('wrote ${recorder.length} records to ${args[0]}');
}
