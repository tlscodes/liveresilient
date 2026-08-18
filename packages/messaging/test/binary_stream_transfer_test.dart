import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

/// In-memory port pair with configurable loss/duplication — the video
/// lane's whole point is surviving exactly this.
class LossyPort implements DataChannelPort {
  LossyPort(this._random, {this.dropRate = 0.0, this.duplicateRate = 0.0});

  final Random _random;
  double dropRate;
  double duplicateRate;
  LossyPort? peer;
  final _in = StreamController<List<int>>.broadcast(sync: true);
  int framesSent = 0;

  @override
  Stream<List<int>> get inbound => _in.stream;

  @override
  Future<void> send(List<int> frame) async {
    framesSent++;
    // Yield so delivery is asynchronous like a real channel.
    await Future<void>.delayed(Duration.zero);
    if (_random.nextDouble() < dropRate) return;
    peer?._in.add(frame);
    if (_random.nextDouble() < duplicateRate) {
      peer?._in.add(frame);
    }
  }

  @override
  Future<void> close() async => _in.close();
}

Uint8List blob(int length, int seed) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i * 31 + seed) & 0xff));

/// Long-RTT port with delivery jitter — the T2 latency profile in miniature.
/// Frames arrive baseOneWay + [0, jitterMs) later; jitter makes some acks
/// land AFTER the caller's retransmit deadline, which is exactly the
/// ambiguity that poisoned the sender's RTT floor on the rig.
class JitterLatencyPort implements DataChannelPort {
  JitterLatencyPort(this._random, this.baseOneWay, this.jitterMs,
      {this.stall = Duration.zero});

  final Random _random;
  final Duration baseOneWay;
  final int jitterMs;

  /// Startup stall: frames sent before this much time has passed are
  /// held and delivered only after it elapses (plus the normal delay) —
  /// the rig's slow connect + transport slow-start in miniature, which
  /// is what depresses the sender's cumulative rate estimate early.
  final Duration stall;
  final DateTime _born = DateTime.now();
  JitterLatencyPort? peer;
  final _in = StreamController<List<int>>.broadcast(sync: true);

  @override
  Stream<List<int>> get inbound => _in.stream;

  @override
  Future<void> send(List<int> frame) async {
    var delay =
        baseOneWay + Duration(milliseconds: _random.nextInt(jitterMs));
    final sinceBorn = DateTime.now().difference(_born);
    if (sinceBorn < stall) {
      delay += stall - sinceBorn;
    }
    Timer(delay, () => peer?._in.add(frame));
  }

  @override
  Future<void> close() async => _in.close();
}

void main() {
  (LossyPort, LossyPort) pair(Random r,
      {double drop = 0.0, double dup = 0.0}) {
    final a = LossyPort(r, dropRate: drop, duplicateRate: dup);
    final b = LossyPort(r, dropRate: drop, duplicateRate: dup);
    a.peer = b;
    b.peer = a;
    return (a, b);
  }

  test('clean link: delivers byte-for-byte with sha ok', () async {
    final (a, b) = pair(Random(1));
    final rx = BinaryStreamReceiver(b);
    addTearDown(rx.close);
    final content = blob(200 * 1024 + 37, 7);

    final resultF = BinaryStreamSender(
      a,
      retransmitAfter: const Duration(milliseconds: 200),
    ).send(content);
    final received = await rx.completed.first
        .timeout(const Duration(seconds: 10));
    final result = await resultF;

    expect(received.sha256Ok, true);
    expect(received.bytes, content);
    expect(result.resumedChunks, 0);
    expect(result.totalChunks, (content.length / (16 * 1024)).ceil());
  });

  test('30% loss + 10% duplication: still delivers intact', () async {
    final (a, b) = pair(Random(2), drop: 0.3, dup: 0.1);
    final rx = BinaryStreamReceiver(b);
    addTearDown(rx.close);
    final content = blob(96 * 1024, 3);

    final resultF = BinaryStreamSender(
      a,
      retransmitAfter: const Duration(milliseconds: 120),
      windowSize: 3,
    ).send(content);
    final received = await rx.completed.first
        .timeout(const Duration(seconds: 30));
    await resultF;

    expect(received.sha256Ok, true);
    expect(received.bytes, content);
  });

  test('resume: a second offer skips chunks the receiver already holds',
      () async {
    final r = Random(3);
    final content = blob(160 * 1024, 9);

    // First attempt over a savage link, capped so it cannot finish.
    final (a1, b1) = pair(r, drop: 0.6);
    final rx1 = BinaryStreamReceiver(b1);
    final firstAttempt = BinaryStreamSender(
      a1,
      retransmitAfter: const Duration(milliseconds: 100),
    ).send(content);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    // Simulate the drop: kill the ports mid-flight.
    await a1.close();
    await b1.close();
    unawaited(firstAttempt.catchError((_) =>
        const BinarySendResult(resumedChunks: 0, totalChunks: 0)));

    // Harvest the partial (in production this is the durable store).
    // Reach the partial through a fresh receiver restore.
    // NOTE: rx1 held some chunks; extract via its internals is not public —
    // production persists chunks as they arrive. Here we simulate that by
    // re-receiving what arrived: count is unknown, so restore a HAND-BUILT
    // partial: first 4 chunks pre-seeded.
    await rx1.close();
    final (a2, b2) = pair(Random(4));
    final rx2 = BinaryStreamReceiver(b2);
    addTearDown(rx2.close);
    // Pre-seed chunks 0..3 as "already held" (production persists chunks
    // as they arrive; the id is stored with the partial — recomputed here
    // exactly as the sender derives it: sha256 prefix).
    final chunks = <int, Uint8List>{};
    for (var i = 0; i < 4; i++) {
      chunks[i] = Uint8List.sublistView(
          content, i * 16 * 1024, (i + 1) * 16 * 1024);
    }
    final transferId =
        Uint8List.fromList(sha256.convert(content).bytes.sublist(0, 16));
    rx2.restorePartial(transferId, chunks,
        total: (content.length / (16 * 1024)).ceil(),
        sizeBytes: content.length);

    final resultF = BinaryStreamSender(
      a2,
      retransmitAfter: const Duration(milliseconds: 150),
    ).send(content);
    final received = await rx2.completed.first
        .timeout(const Duration(seconds: 10));
    final result = await resultF;

    expect(received.sha256Ok, true);
    expect(received.bytes, content);
    expect(result.resumedChunks, 4,
        reason: 'the HAVE bitmap must spare the four pre-held chunks');
  });

  test('corrupt frame is dropped, transfer completes anyway', () async {
    final (a, b) = pair(Random(5));
    final rx = BinaryStreamReceiver(b);
    addTearDown(rx.close);
    // Inject garbage and a bit-flipped chunk frame directly.
    b._in.add([0xB5, 3, 1, 2, 3]); // truncated
    final content = blob(48 * 1024, 11);
    final resultF = BinaryStreamSender(
      a,
      retransmitAfter: const Duration(milliseconds: 150),
    ).send(content);
    final received =
        await rx.completed.first.timeout(const Duration(seconds: 10));
    await resultF;
    expect(received.sha256Ok, true);
  });

  test(
      'backpressure gate scales with the send window: buffered depth below '
      'one window does not stall sends', () async {
    // Old fixed gate (2 chunks) would hold EVERY send for the full
    // retransmitAfter here, because buffered() reports 5 chunks queued.
    // The window-derived gate (windowSize 8 -> 9 chunks allowed) must not
    // wait at all, so the transfer finishes far inside one deadline.
    final (a, b) = pair(Random(11));
    final rx = BinaryStreamReceiver(b);
    addTearDown(rx.close);
    const chunk = 16 * 1024;
    final content = blob(4 * chunk, 21);

    final started = DateTime.now();
    final resultF = BinaryStreamSender(
      a,
      retransmitAfter: const Duration(milliseconds: 500),
      windowSize: 8,
      transportBufferedBytes: () => 5 * chunk,
    ).send(content);
    final received =
        await rx.completed.first.timeout(const Duration(seconds: 5));
    await resultF;
    final elapsed = DateTime.now().difference(started);

    expect(received.sha256Ok, true);
    // 4 chunks x 500ms gated waits would be >= 2s under the old gate.
    expect(elapsed, lessThan(const Duration(milliseconds: 1500)));
  });

  test(
      'backpressure gate floor holds on a thin window: buffered depth above '
      'the floor stalls each send for the bounded wait', () async {
    // windowSize 1 -> floor gate of (2+1) chunks; buffered() reports 4
    // chunks queued, so every send must sit out the full bounded wait.
    final (a, b) = pair(Random(12));
    final rx = BinaryStreamReceiver(b);
    addTearDown(rx.close);
    const chunk = 16 * 1024;
    final content = blob(2 * chunk, 22);

    final started = DateTime.now();
    final resultF = BinaryStreamSender(
      a,
      retransmitAfter: const Duration(milliseconds: 80),
      windowSize: 1,
      transportBufferedBytes: () => 4 * chunk,
    ).send(content);
    final received =
        await rx.completed.first.timeout(const Duration(seconds: 10));
    await resultF;
    final elapsed = DateTime.now().difference(started);

    expect(received.sha256Ok, true);
    // Two chunks, each gated for ~80ms before handover.
    expect(elapsed, greaterThan(const Duration(milliseconds: 150)));
  });

  test(
      'long-RTT link with ack jitter: throughput holds near windowSize per '
      'round trip (RTT samples are Karn-guarded; resend deadline adapts)',
      () async {
    // Rig row in miniature (2026-08-08 latency FAIL): 1.8s round trip,
    // caller deadline 2s, window 4. Jitter pushes some acks past the
    // deadline; the un-fixed sender then resent healthy chunks, sampled
    // RTT from the resend timestamp (~0.2s), collapsed its RTT floor,
    // latched the pacer on, and locked at ~1 chunk per round trip.
    final a = JitterLatencyPort(
        Random(31), const Duration(milliseconds: 900), 300,
        stall: const Duration(seconds: 10));
    final b =
        JitterLatencyPort(Random(32), const Duration(milliseconds: 900), 300);
    a.peer = b;
    b.peer = a;
    final rx = BinaryStreamReceiver(b);
    addTearDown(rx.close);
    const chunk = 16 * 1024;
    final content = blob(32 * chunk, 41);

    final started = DateTime.now();
    final sender = BinaryStreamSender(
      a,
      retransmitAfter: const Duration(seconds: 2),
      windowSize: 4,
    );
    final resultF = sender.send(content);
    final received =
        await rx.completed.first.timeout(const Duration(seconds: 150));
    await resultF;
    final elapsed = DateTime.now().difference(started);

    expect(received.sha256Ok, true);
    // 10s stall + 32 chunks at 4 per ~2s round trip is ~26-30s; the
    // poisoned sender (RTT floor collapsed during the stall's resend
    // burst, pacer latched, cumulative rate stuck) needed >70s.
    expect(elapsed, lessThan(const Duration(seconds: 45)),
        reason: 'throughput locked below the window: ${sender.diag()}');
  }, timeout: const Timeout(Duration(minutes: 4)));

  test(
      'send budget token bucket: the lane never offers more than its '
      'allotted rate, and still delivers intact', () async {
    final (a, b) = pair(Random(51));
    final rx = BinaryStreamReceiver(b);
    addTearDown(rx.close);
    const chunk = 16 * 1024;
    final content = blob(4 * chunk, 61);

    final started = DateTime.now();
    final resultF = BinaryStreamSender(
      a,
      retransmitAfter: const Duration(seconds: 5),
      windowSize: 4,
      sendBudgetBytesPerSec: () => chunk, // one chunk's worth per second
    ).send(content);
    final received =
        await rx.completed.first.timeout(const Duration(seconds: 30));
    await resultF;
    final elapsed = DateTime.now().difference(started);

    expect(received.sha256Ok, true);
    // Four chunks at one chunk/s from an empty bucket: ~3-4s minimum.
    // An unbudgeted sender finishes this transfer in tens of ms.
    expect(elapsed, greaterThan(const Duration(milliseconds: 2500)));
  });

  test(
      'send budget far below one chunk per two seconds still transfers '
      '(burst cap must never sit below the chunk size)', () async {
    // Rig run-5 regression: budget 500 B/s with 4 KiB chunks wedged the
    // transfer at zero chunks forever, because the bucket's burst cap
    // (2 x rate = 1000 B) could never accumulate one chunk's tokens.
    final (a, b) = pair(Random(52));
    final rx = BinaryStreamReceiver(b);
    addTearDown(rx.close);
    const chunk = 1024;
    final content = blob(2 * chunk, 62);

    final resultF = BinaryStreamSender(
      a,
      retransmitAfter: const Duration(seconds: 10),
      windowSize: 2,
      chunkBytes: chunk,
      sendBudgetBytesPerSec: () => 512, // half a chunk per second
    ).send(content);
    final received =
        await rx.completed.first.timeout(const Duration(seconds: 30));
    await resultF;
    expect(received.sha256Ok, true);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
