import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:connection_orchestrator/src/media_queue.dart';
import 'package:test/test.dart';

/// A lane that delivers everything and records each payload it sent.
class _CountingLane extends DomesticEdgeBridgeLane {
  _CountingLane()
    : super(
        endpoints: [Uri.parse('https://203.0.113.99:443')],
        connector: (uri) async => throw StateError('never connected'),
      );

  final List<Uint8List> sent = [];

  @override
  Future<SendResult> send(List<int> payload) async {
    sent.add(Uint8List.fromList(payload));
    return const SendResult(SendStatus.ok);
  }
}

/// Deterministic microsecond clock: returns scripted times in order.
class _FakeClock {
  _FakeClock(this.times);
  final List<int> times;
  int _next = 0;
  int call() => times[_next++];
}

ResilientMediaTransport _transport(
  DomesticEdgeBridgeLane lane, {
  WireTraceRecorder? wireTrace,
}) {
  final transport = ResilientMediaTransport(
    queue: MediaTransferQueue(spareBudgetBytesPerSecond: 500),
    carriage: MediaCarriage(mtuBlockSize: 16, random: Random(3)),
    edgeBridge: lane,
    wireTrace: wireTrace,
  );
  transport.send(
    Uint8List.fromList(List<int>.generate(400, (i) => i & 0xFF)),
    MediaType.photo,
  );
  // Prime the queue's rate budget.
  transport.wireTick(nowMs: 0, voiceIsSpeaking: false);
  return transport;
}

void main() {
  test('recorder with no records emits the header only', () {
    final recorder = WireTraceRecorder(nowMicros: _FakeClock(const []).call);
    expect(recorder.toCsv(), 'size_bytes,direction,delta_us\n');
  });

  test('emitted CSV matches the frozen form exactly: header, first delta 0, '
      'subsequent deltas in microseconds', () {
    final clock = _FakeClock(const [1000, 1250, 2000]);
    final recorder = WireTraceRecorder(nowMicros: clock.call);
    recorder.recordTx(10);
    recorder.recordRx(20);
    recorder.recordTx(30);
    expect(
      recorder.toCsv(),
      'size_bytes,direction,delta_us\n'
      '10,tx,0\n'
      '20,rx,250\n'
      '30,tx,750\n',
    );
  });

  test('retention cap drops oldest first and the emitted file stays '
      'self-consistent (its first record is 0)', () {
    final clock = _FakeClock(const [100, 200, 350]);
    final recorder = WireTraceRecorder(nowMicros: clock.call, maxRecords: 2);
    recorder.recordTx(1);
    recorder.recordTx(2);
    recorder.recordRx(3);
    expect(recorder.length, 2);
    expect(
      recorder.toCsv(),
      'size_bytes,direction,delta_us\n'
      '2,tx,0\n'
      '3,rx,150\n',
    );
  });

  test('transport built without a recorder has recording disabled and '
      'flushes normally', () async {
    final lane = _CountingLane();
    final transport = _transport(lane);
    expect(transport.wireTrace, isNull);
    final results = await transport.flushWireTick(
      nowMs: 1000,
      voiceIsSpeaking: false,
    );
    expect(results, isNotEmpty);
    expect(lane.sent, isNotEmpty);
  });

  test(
    'transport records one tx per frame handed to the lane and one rx '
    'per datagram entering receiveFromWire, sizes and directions exact',
    () async {
      // Reference run to learn the frame count this seed produces.
      final refLane = _CountingLane();
      final refTransport = _transport(refLane);
      await refTransport.flushWireTick(nowMs: 1000, voiceIsSpeaking: false);
      final frameCount = refLane.sent.length;
      expect(frameCount, greaterThanOrEqualTo(2));

      // Traced run: identical seeds, clock ticks 100us apart per record.
      final clock = _FakeClock([
        for (var i = 0; i <= frameCount; i++) 5000 + 100 * i,
      ]);
      final recorder = WireTraceRecorder(nowMicros: clock.call);
      final lane = _CountingLane();
      final transport = _transport(lane, wireTrace: recorder);
      await transport.flushWireTick(nowMs: 1000, voiceIsSpeaking: false);
      expect(lane.sent.length, frameCount);

      // Feed the first sent frame back in as an inbound datagram.
      transport.receiveFromWire(lane.sent.first);

      final expected = StringBuffer('size_bytes,direction,delta_us\n');
      for (var i = 0; i < frameCount; i++) {
        expected.write('${lane.sent[i].length},tx,${i == 0 ? 0 : 100}\n');
      }
      expected.write('${lane.sent.first.length},rx,100\n');
      expect(recorder.toCsv(), expected.toString());
    },
  );
}
