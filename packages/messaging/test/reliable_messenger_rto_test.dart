/// The retransmission window follows measured round trips (RFC 6298) and
/// backs off per retransmission once a measurement exists.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

/// A port whose delivery to the peer is delayed by [latency] (one way).
class _LatentPort implements DataChannelPort {
  _LatentPort(this._now);
  final DateTime Function() _now;
  final _inbound = StreamController<List<int>>.broadcast();
  _LatentPort? peer;
  Duration latency = Duration.zero;
  bool drop = false;
  final _queue = <(DateTime, List<int>)>[];

  @override
  Stream<List<int>> get inbound => _inbound.stream;

  @override
  Future<void> send(List<int> frame) async {
    if (drop) return;
    _queue.add((_now().add(latency), frame));
  }

  /// Delivers every queued frame whose arrival time has come.
  void deliverDue() {
    final now = _now();
    final due = _queue.where((q) => !q.$1.isAfter(now)).toList();
    _queue.removeWhere((q) => !q.$1.isAfter(now));
    for (final (_, frame) in due) {
      peer?._inbound.add(frame);
    }
  }

  @override
  Future<void> close() async {
    if (!_inbound.isClosed) await _inbound.close();
  }
}

void main() {
  test('the window starts at retryAfter, then follows srtt + 4·rttvar, and '
      'doubles per retransmission', () async {
    var now = DateTime.utc(2026, 1, 1);
    final a = _LatentPort(() => now);
    final b = _LatentPort(() => now);
    a.peer = b;
    b.peer = a;
    // A slow link: one way 1.5 s, so a round trip is 3 s.
    a.latency = const Duration(milliseconds: 1500);
    b.latency = const Duration(milliseconds: 1500);
    final alice = ReliableMessenger(
      a,
      peerId: 'alice',
      clock: Clock(() => now),
      retryAfter: const Duration(seconds: 2),
      maxAttempts: 12,
    );
    final bob = ReliableMessenger(b, peerId: 'bob', clock: Clock(() => now));
    addTearDown(() async {
      await alice.close();
      await bob.close();
    });
    expect(alice.currentRetryAfter, const Duration(seconds: 2));

    await alice.send('first');
    // Deliver the message after 1.5 s and its ack after another 1.5 s; tick
    // in between at 2 s (the old fixed window) — with no measurement yet the
    // messenger retransmits once, exactly as before.
    now = now.add(const Duration(milliseconds: 1500));
    a.deliverDue();
    await Future<void>.delayed(Duration.zero);
    now = now.add(const Duration(milliseconds: 600));
    await alice.tick();
    now = now.add(const Duration(milliseconds: 900));
    b.deliverDue();
    await Future<void>.delayed(Duration.zero);
    // The ack answered a retransmitted message: Karn's rule, no sample.
    expect(alice.smoothedRttMs, isNull);

    // A clean exchange: send, deliver, ack — one transmission, one sample.
    await alice.send('second');
    now = now.add(const Duration(milliseconds: 1500));
    a.deliverDue();
    await Future<void>.delayed(Duration.zero);
    now = now.add(const Duration(milliseconds: 1500));
    b.deliverDue();
    await Future<void>.delayed(Duration.zero);
    expect(alice.smoothedRttMs, closeTo(3000, 1));
    // srtt 3000 + 4·rttvar 1500 = 9 s: the window no longer re-sends every
    // chunk before its ack can arrive.
    expect(alice.currentRetryAfter, const Duration(seconds: 9));

    // Under a partition the retransmissions back off: 9 s, 18 s, 30 s cap.
    a.drop = true;
    final third = await alice.send('third');
    var sends = 0;
    a.drop = false;
    b.drop = true; // acks never return
    now = now.add(const Duration(seconds: 9));
    await alice.tick(); // attempt 2 at +9 s
    sends = a._queue.length;
    expect(sends, 1);
    now = now.add(const Duration(seconds: 9));
    await alice.tick(); // +18 s since attempt 2: window is now 18 s → no send
    expect(a._queue.length, 1);
    now = now.add(const Duration(seconds: 9));
    await alice.tick(); // +18 s: attempt 3
    expect(a._queue.length, 2);
    expect(alice.pendingCount, 1);
    expect(third.text, 'third');
  });
}
