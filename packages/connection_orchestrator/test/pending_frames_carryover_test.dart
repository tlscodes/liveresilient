import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:connection_orchestrator/src/media_queue.dart';
import 'package:test/test.dart';

/// A lane whose delivery outcomes are scripted per send call. Records every
/// payload it was asked to send, in call order.
class _ScriptedLane extends DomesticEdgeBridgeLane {
  _ScriptedLane({required this.failOnCallIndexes})
    : super(
        endpoints: [Uri.parse('https://203.0.113.99:443')],
        connector: (uri) async => throw StateError('never connected'),
      );

  /// Zero-based send-call indexes that report a transient failure.
  final Set<int> failOnCallIndexes;

  final List<Uint8List> sent = [];
  final List<bool> outcomes = [];

  @override
  Future<SendResult> send(List<int> payload) async {
    final index = sent.length;
    sent.add(Uint8List.fromList(payload));
    final fail = failOnCallIndexes.contains(index);
    outcomes.add(!fail);
    return fail
        ? const SendResult(SendStatus.transient)
        : const SendResult(SendStatus.ok);
  }
}

ResilientMediaTransport _transport(DomesticEdgeBridgeLane lane) {
  final transport = ResilientMediaTransport(
    queue: MediaTransferQueue(spareBudgetBytesPerSecond: 500),
    carriage: MediaCarriage(mtuBlockSize: 16, random: Random(3)),
    edgeBridge: lane,
  );
  transport.send(
    Uint8List.fromList(List<int>.generate(400, (i) => i & 0xFF)),
    MediaType.photo,
  );
  // Prime the queue's rate budget; these frames are discarded by the caller
  // identically in the reference and failing runs.
  transport.wireTick(nowMs: 0, voiceIsSpeaking: false);
  return transport;
}

void main() {
  test('undelivered remainder is carried to the next flush, in order, '
      'ahead of that tick\'s new frames', () async {
    // Reference run: identical seeds, no failures — the canonical wire
    // frame sequence for ticks at 1000ms and 2000ms.
    final refLane = _ScriptedLane(failOnCallIndexes: const {});
    final refTransport = _transport(refLane);
    await refTransport.flushWireTick(nowMs: 1000, voiceIsSpeaking: false);
    final tick1Count = refLane.sent.length;
    await refTransport.flushWireTick(nowMs: 2000, voiceIsSpeaking: false);
    final refFrames = refLane.sent;
    expect(
      tick1Count,
      greaterThanOrEqualTo(3),
      reason: 'test needs a tick producing 3+ frames',
    );
    expect(
      refFrames.length,
      greaterThan(tick1Count),
      reason: 'test needs the second tick to produce frames of its own',
    );

    // Failing run: same seeds, the lane fails on frame 2 (call index 1).
    final lane = _ScriptedLane(failOnCallIndexes: const {1});
    final transport = _transport(lane);

    final first = await transport.flushWireTick(
      nowMs: 1000,
      voiceIsSpeaking: false,
    );
    // Stop-at-first-failure is preserved: frame 2 failed, frame 3+ of the
    // tick were not attempted.
    expect(first, hasLength(2));
    expect(first.last.delivered, isFalse);
    expect(lane.sent, hasLength(2));

    final second = await transport.flushWireTick(
      nowMs: 2000,
      voiceIsSpeaking: false,
    );
    expect(second.every((r) => r.delivered), isTrue);

    // Delivered payloads, in delivery order, must equal the canonical
    // sequence exactly: frame 2 is retried first on the second flush,
    // then frame 3.. of tick 1, then tick 2's own frames.
    final delivered = <Uint8List>[
      for (var i = 0; i < lane.sent.length; i++)
        if (lane.outcomes[i]) lane.sent[i],
    ];
    expect(delivered.length, refFrames.length);
    for (var i = 0; i < refFrames.length; i++) {
      expect(
        delivered[i],
        equals(refFrames[i]),
        reason: 'delivered frame $i out of order',
      );
    }
    // Explicitly: frames 2 and 3 of tick 1 went out on the second flush,
    // in order, before the second tick's first frame.
    expect(delivered[1], equals(refFrames[1])); // frame 2, retried
    expect(delivered[2], equals(refFrames[2])); // frame 3, carried
    expect(delivered[tick1Count], equals(refFrames[tick1Count]));
  });
}
