/// The retransmission window is a model of the frame on the path: a
/// serialization term at the lane's rate plus a round-trip term that is
/// seeded from the transport before any ack was sampled, backed off from
/// the first attempt; a frame still queued in the transport is never
/// resent; failure is a time budget on the live clock that pauses with the
/// path; every failure carries its numbers.
///
/// Born on the rig's narrow profile (2026-09-04): a 16.6 KB attachment
/// chunk on a 570 B/s share was resent twelve times at a fixed 2 s and
/// failed ten seconds before its first copy could have been acknowledged.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

/// A port whose delivery to the peer happens only when the test says so,
/// with a controllable transport buffer reading.
class _Port implements DataChannelPort {
  _Port(this._now);
  final DateTime Function() _now;
  final _inbound = StreamController<List<int>>.broadcast();
  _Port? peer;
  bool drop = false;
  int sent = 0;
  int sentBytes = 0;
  final _queue = <(DateTime, List<int>)>[];

  @override
  Stream<List<int>> get inbound => _inbound.stream;

  @override
  Future<void> send(List<int> frame) async {
    sent++;
    sentBytes += frame.length;
    if (drop) return;
    _queue.add((_now(), frame));
  }

  /// Delivers every queued frame to the peer.
  void deliverAll() {
    final due = _queue.toList();
    _queue.clear();
    for (final (_, frame) in due) {
      peer?._inbound.add(frame);
    }
  }

  int get queued => _queue.length;

  @override
  Future<void> close() async {
    if (!_inbound.isClosed) await _inbound.close();
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late DateTime now;
  late _Port a;
  late _Port b;

  setUp(() {
    now = DateTime.utc(2026, 9, 4, 13);
    a = _Port(() => now);
    b = _Port(() => now);
    a.peer = b;
    b.peer = a;
  });

  Clock fake() => Clock(() => now);

  test('the transport round trip seeds the window before any ack: 3R, then '
      'doubled per retransmission, capped at 30 s', () async {
    final alice = ReliableMessenger(
      a,
      peerId: 'alice',
      clock: fake(),
      retryAfter: const Duration(seconds: 2),
      maxAttempts: 12,
      transportRttMs: () => 3000,
    );
    addTearDown(alice.close);
    expect(alice.currentRetryAfter, const Duration(seconds: 9));
    a.drop = true; // nothing reaches bob; acks never come
    await alice.send('hello');
    expect(a.sent, 1);
    now = now.add(const Duration(seconds: 8));
    await alice.tick();
    expect(a.sent, 1, reason: 'no 2 s resend on a 3 s path');
    now = now.add(const Duration(seconds: 1)); // +9 s
    await alice.tick();
    expect(a.sent, 2);
    now = now.add(const Duration(seconds: 17)); // +17 s since attempt 2
    await alice.tick();
    expect(a.sent, 2, reason: 'window doubled to 18 s');
    now = now.add(const Duration(seconds: 1)); // +18 s
    await alice.tick();
    expect(a.sent, 3);
    now = now.add(const Duration(seconds: 29)); // 36 s would be the double
    await alice.tick();
    expect(a.sent, 3, reason: 'capped at 30 s');
    now = now.add(const Duration(seconds: 1));
    await alice.tick();
    expect(a.sent, 4);
    expect(alice.duplicateFrames, 3);
    expect(alice.smoothedRttMs, isNull);
  });

  test('a large frame on a slow share waits its serialization time: one '
      'transmission, and the sample excludes the drain', () async {
    final alice = ReliableMessenger(
      a,
      peerId: 'alice',
      clock: fake(),
      retryAfter: const Duration(seconds: 2),
      maxAttempts: 12,
      sendBudgetBytesPerSec: () => 570,
      transportRttMs: () => 3000,
    );
    final bob = ReliableMessenger(b, peerId: 'bob', clock: fake());
    addTearDown(() async {
      await alice.close();
      await bob.close();
    });
    final big = 'x' * 16480; // the frame lands near 16.6 KB, as chunk 0 did
    await alice.send(big);
    final frameBytes = a.sentBytes;
    expect(frameBytes, greaterThan(16000));
    // serialization = frame x 1.08 / 570 B/s ≈ 31.4 s; window ≈ 31.4 + 9 s.
    final serializationMs = (frameBytes * 1.08 / 570 * 1000).round();
    now = now.add(const Duration(seconds: 35));
    await alice.tick();
    expect(a.sent, 1, reason: 'the first copy is still draining: no copy');
    // The ack arrives at 35 s: delivered after ONE transmission.
    a.deliverAll();
    await _settle();
    b.deliverAll();
    await _settle();
    expect(alice.pendingCount, 0);
    expect(alice.duplicateFrames, 0);
    // srtt ≈ 35 s − 31.4 s ≈ 3.6 s, not 35 s.
    expect(alice.smoothedRttMs, closeTo(35000 - serializationMs, 50));
    // The next small text waits srtt + 4·rttvar ≈ 11 s, not two minutes.
    expect(
      alice.currentRetryAfter.inMilliseconds,
      inInclusiveRange(9000, 12000),
    );
    // And a copy would have gone out only after the window: +45 s.
    a.drop = true;
    await alice.send(big);
    now = now.add(const Duration(seconds: 40));
    await alice.tick();
    expect(a.sent, 2);
    now = now.add(const Duration(seconds: 6));
    await alice.tick();
    expect(a.sent, 3);
  });

  test('a frame still queued in the transport is never retransmitted; it '
      'is once the buffer drained', () async {
    var buffered = 0;
    final alice = ReliableMessenger(
      a,
      peerId: 'alice',
      clock: fake(),
      retryAfter: const Duration(seconds: 2),
      maxAttempts: 12,
      deliveryBudget: const Duration(seconds: 300),
      transportBufferedBytes: () => buffered,
    );
    addTearDown(alice.close);
    a.drop = true;
    await alice.send('queued');
    buffered = a.sentBytes; // the whole frame still sits in the transport
    for (var i = 0; i < 10; i++) {
      now = now.add(const Duration(seconds: 2));
      await alice.tick();
    }
    expect(a.sent, 1, reason: 'ten windows, zero copies while queued');
    buffered = 0; // drained
    await alice.tick();
    expect(a.sent, 2);
    expect(alice.duplicateFrames, 1);
  });

  test('failure is a time budget on the live clock: a pause consumes '
      'nothing and the record carries the numbers', () async {
    final failures = <DeliveryFailure>[];
    final alice = ReliableMessenger(
      a,
      peerId: 'alice',
      clock: fake(),
      retryAfter: const Duration(seconds: 2),
      maxAttempts: 12,
      deliveryBudget: const Duration(seconds: 60),
    );
    addTearDown(alice.close);
    alice.failures.listen(failures.add);
    final states = <DeliveryState>[];
    alice.deliveries.listen((d) => states.add(d.$2));
    a.drop = true;
    final msg = await alice.send('never acked');
    for (var i = 0; i < 20; i++) {
      now = now.add(const Duration(seconds: 2)); // 40 s
      await alice.tick();
    }
    expect(alice.pendingCount, 1, reason: 'not failed before the budget');
    final attemptsBeforePause = a.sent;
    alice.pause();
    expect(alice.isPaused, isTrue);
    for (var i = 0; i < 15; i++) {
      now = now.add(const Duration(seconds: 2)); // 30 s paused
      await alice.tick();
    }
    expect(a.sent, attemptsBeforePause, reason: 'no attempts while paused');
    alice.resume();
    for (var i = 0; i < 9; i++) {
      now = now.add(const Duration(seconds: 2)); // live 58 s
      await alice.tick();
    }
    expect(alice.pendingCount, 1, reason: 'the pause consumed no budget');
    now = now.add(const Duration(seconds: 2)); // live 60 s
    await alice.tick();
    await _settle();
    expect(alice.pendingCount, 0);
    expect(states, [DeliveryState.failed]);
    expect(failures, hasLength(1));
    final f = failures.single;
    expect(alice.lastFailure, same(f));
    expect(f.messageId, msg.id);
    expect(f.reason, contains('budget'));
    expect(f.elapsedMs, 90000);
    expect(f.elapsedLiveMs, 60000);
    expect(f.srttMs, isNull);
    expect(f.seedSource, 'floor');
    expect(f.leftBuffer, isTrue);
    expect(f.attempts, greaterThan(1));
    expect(f.attempts, lessThanOrEqualTo(12));
    expect(f.windowsMs, isNotEmpty);
    expect(f.windowsMs.first, 2000);
    expect(f.windowsMs.length, f.attempts - 1);
    expect('$f', contains('reason=delivery budget'));
  });

  test('without a budget the count-based failure and the backoff both '
      'hold: 2, 4, 8 s then failed at maxAttempts', () async {
    final alice = ReliableMessenger(
      a,
      peerId: 'alice',
      clock: fake(),
      retryAfter: const Duration(seconds: 2),
      maxAttempts: 4,
    );
    addTearDown(alice.close);
    final states = <DeliveryState>[];
    alice.deliveries.listen((d) => states.add(d.$2));
    a.drop = true;
    await alice.send('x');
    final marks = <int>[];
    for (var t = 1; t <= 40; t++) {
      now = now.add(const Duration(seconds: 1));
      final before = a.sent;
      await alice.tick();
      if (a.sent > before) marks.add(t);
    }
    expect(marks, [2, 6, 14]); // windows 2, 4, 8 s
    await _settle();
    expect(states, [DeliveryState.failed]);
    expect(alice.lastFailure!.reason, contains('attempts exhausted'));
  });

  test('suggestedPayloadBytes follows the lane rate and the round trip', () {
    int? rate;
    final alice = ReliableMessenger(
      a,
      peerId: 'alice',
      clock: fake(),
      sendBudgetBytesPerSec: () => rate,
      transportRttMs: () => 3000,
    );
    addTearDown(alice.close);
    const framing = AttachmentChunk.framingOverhead;
    expect(alice.suggestedPayloadBytes(framingOverhead: framing), 12 * 1024);
    rate = 570;
    // target 4·3 s → capped 10 s; wire 570 × 10 × 0.75 = 4275 B;
    // payload 4275 / (1.35 × 1.08) ≈ 2932 B.
    expect(
      alice.suggestedPayloadBytes(framingOverhead: framing),
      closeTo(2932, 5),
    );
    rate = 32000;
    expect(alice.suggestedPayloadBytes(framingOverhead: framing), 12 * 1024);
    rate = 100;
    expect(alice.suggestedPayloadBytes(framingOverhead: framing), 1024);
  });

  test('startAttachmentSend sizes its chunks from the rate model by default '
      'and the failure text carries the record', () async {
    final alice = ReliableMessenger(
      a,
      peerId: 'alice',
      clock: fake(),
      retryAfter: const Duration(seconds: 2),
      maxAttempts: 12,
      deliveryBudget: const Duration(seconds: 120),
      sendBudgetBytesPerSec: () => 570,
      transportRttMs: () => 3000,
    );
    final bob = ReliableMessenger(b, peerId: 'bob', clock: fake());
    addTearDown(() async {
      await alice.close();
      await bob.close();
    });
    final receiver = AttachmentReceiver();
    var chunkFrames = 0;
    bob.incoming.listen((m) {
      if (receiver.offer(m.text)) chunkFrames++;
    });
    final received = Completer<Attachment>();
    receiver.completed.listen(received.complete);
    final note = Attachment(
      id: 'voice-1',
      kind: MediaKind.file,
      contentType: 'audio/wav',
      bytes: List<int>.generate(24000, (i) => i & 0xff),
    );
    final handle = startAttachmentSend(alice, note);
    var done = false;
    unawaited(handle.done.then((_) => done = true));
    for (var i = 0; i < 200 && !done; i++) {
      await _settle();
      a.deliverAll();
      await _settle();
      b.deliverAll();
      await _settle();
    }
    expect(done, isTrue);
    expect(chunkFrames, (24000 / 2932).ceil()); // 9 chunks, not 2
    expect((await received.future).bytes, note.bytes);
    expect(alice.duplicateFrames, 0);

    // A chunk that can never be delivered fails with the record in the text.
    a.drop = true;
    final failing = startAttachmentSend(
      alice,
      Attachment(
        id: 'voice-2',
        kind: MediaKind.file,
        contentType: 'audio/wav',
        bytes: List<int>.filled(3000, 1),
      ),
      deliveryBudget: const Duration(seconds: 30),
    );
    Object? error;
    unawaited(failing.done.then((_) {}, onError: (Object e) => error = e));
    for (var i = 0; i < 20; i++) {
      now = now.add(const Duration(seconds: 2));
      await alice.tick();
      await _settle();
    }
    expect(error, isA<StateError>());
    expect('$error', contains('chunk 0 failed delivery (failed)'));
    expect('$error', contains('reason=delivery budget 30000ms'));
    expect('$error', contains('rate=570B/s'));
  });

  test('onBytesAcked fires once per acknowledged frame with that frame\'s '
      'wire length', () async {
    final acked = <int>[];
    final alice = ReliableMessenger(
      a,
      peerId: 'alice',
      clock: fake(),
      onBytesAcked: acked.add,
    );
    final bob = ReliableMessenger(b, peerId: 'bob', clock: fake());
    addTearDown(() async {
      await alice.close();
      await bob.close();
    });
    await alice.send('first');
    final firstFrame = a.sentBytes;
    a.deliverAll();
    await _settle();
    b.deliverAll();
    await _settle();
    expect(acked, [firstFrame]);
    await alice.send('second, longer than the first one');
    final secondFrame = a.sentBytes - firstFrame;
    a.deliverAll();
    await _settle();
    b.deliverAll();
    await _settle();
    expect(acked, [firstFrame, secondFrame]);
    expect(alice.pendingCount, 0);
  });

  test('the rate is the MIN of the governor budget and the own acked rate: '
      'a governor at its 4 MB/s cap over a 570 B/s delivery sizes chunks '
      'for 570 B/s', () async {
    const governorCap = 4194304; // the governor's maxBytesPerSec
    final alice = ReliableMessenger(
      a,
      peerId: 'alice',
      clock: fake(),
      sendBudgetBytesPerSec: () => governorCap,
      transportRttMs: () => 3000,
    );
    final bob = ReliableMessenger(b, peerId: 'bob', clock: fake());
    addTearDown(() async {
      await alice.close();
      await bob.close();
    });
    const framing = AttachmentChunk.framingOverhead;
    // No own rate yet: the governor's number stands alone.
    expect(alice.rateBytesPerSec, governorCap);
    expect(alice.suggestedPayloadBytes(framingOverhead: framing), 12 * 1024);
    final start = now;
    // Three frames, each acknowledged 3 s after it was sent (the samples
    // seed srtt at 3 s, as the transport said).
    for (var i = 0; i < 3; i++) {
      await alice.send('x' * 2000);
      now = now.add(const Duration(seconds: 3));
      a.deliverAll();
      await _settle();
      b.deliverAll();
      await _settle();
    }
    expect(alice.pendingCount, 0);
    // Two clean 3 s samples; the third ack is the one that makes the own
    // rate exist (3 acks over 9 s ≈ 690 B/s), so its sample is reduced by
    // the frame's serialization at that rate. srtt stays above 2.5 s, the
    // point where 4·rtt reaches the 10 s target cap.
    expect(alice.smoothedRttMs, inInclusiveRange(2500, 3000));
    // Every frame alice sent was acked once: a.sentBytes is the acked total.
    // Place the clock so that total / elapsed is exactly 570 B/s.
    final elapsedMs = a.sentBytes * 1000 ~/ 570;
    expect(elapsedMs, greaterThan(9000), reason: 'monotone clock');
    now = start.add(Duration(milliseconds: elapsedMs));
    // The delivery-rate estimator: bytes acked after the oldest ack over
    // the interval between the oldest and newest ack (two 2.1 KB frames
    // over 6 s ≈ 700 B/s), well under the governor's 4 MiB/s.
    expect(alice.rateBytesPerSec, inInclusiveRange(500, 800));
    // The 570 B/s answer of the rate test above: 2932 B.
    expect(
      alice.suggestedPayloadBytes(framingOverhead: framing),
      inInclusiveRange(2500, 4200),
      reason: 'sized for 500-800 B/s, not for 4 MiB/s',
    );
  });
}
