/// The messenger's own acked-bytes rate is a sliding window, not a lifetime
/// average: after an idle stretch the first slow acks must not pin every
/// later chunk at 1 KiB with minute-long windows (refuted 2026-09-04). And a
/// round-trip sample whose serialization term exceeds the observed time is
/// skipped, never clamped to 1 ms.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

class _Port implements DataChannelPort {
  _Port();
  final _inbound = StreamController<List<int>>.broadcast();
  _Port? peer;
  final _queue = <List<int>>[];

  @override
  Stream<List<int>> get inbound => _inbound.stream;

  @override
  Future<void> send(List<int> frame) async => _queue.add(frame);

  void deliverAll() {
    final due = _queue.toList();
    _queue.clear();
    for (final frame in due) {
      peer?._inbound.add(frame);
    }
  }

  @override
  Future<void> close() async {
    if (!_inbound.isClosed) await _inbound.close();
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('the own rate forgets acks older than the window', () async {
    var now = DateTime.utc(2026, 9, 4, 17);
    final a = _Port();
    final b = _Port();
    a.peer = b;
    b.peer = a;
    final alice = ReliableMessenger(
      a,
      peerId: 'alice',
      clock: Clock(() => now),
      sendBudgetBytesPerSec: () => 4194304, // the governor's cap
    );
    final bob = ReliableMessenger(b, peerId: 'bob', clock: Clock(() => now));
    addTearDown(() async {
      await alice.close();
      await bob.close();
    });
    // Three small texts acked slowly: ~135 B frames over 2.5 s ≈ 160 B/s.
    for (var i = 0; i < 3; i++) {
      await alice.send('text $i');
      now = now.add(const Duration(milliseconds: 1250));
      a.deliverAll();
      await _settle();
      b.deliverAll();
      await _settle();
    }
    final slow = alice.rateBytesPerSec;
    expect(slow, isNotNull);
    expect(slow!, lessThan(400));
    expect(
      alice.suggestedPayloadBytes(framingOverhead: 1.35),
      1024,
      reason: 'the min rule holds while those acks are inside the window',
    );
    // Idle for ten seconds: the window empties and the governor's budget
    // rules again — no lifetime average pins the next chunk.
    now = now.add(const Duration(seconds: 10));
    expect(alice.rateBytesPerSec, 4194304);
    expect(alice.suggestedPayloadBytes(framingOverhead: 1.35), 12 * 1024);
  });

  test('a round-trip sample is skipped when the serialization estimate '
      'exceeds the observed time', () async {
    var now = DateTime.utc(2026, 9, 4, 17);
    final a = _Port();
    final b = _Port();
    a.peer = b;
    b.peer = a;
    // The governor claims 100 B/s, so a 16 KB frame "needs" 170 s to drain;
    // the ack arrives after 2 s: the estimate was wrong, not the path.
    final alice = ReliableMessenger(
      a,
      peerId: 'alice',
      clock: Clock(() => now),
      sendBudgetBytesPerSec: () => 100,
    );
    final bob = ReliableMessenger(b, peerId: 'bob', clock: Clock(() => now));
    addTearDown(() async {
      await alice.close();
      await bob.close();
    });
    await alice.send('x' * 16000);
    now = now.add(const Duration(seconds: 2));
    a.deliverAll();
    await _settle();
    b.deliverAll();
    await _settle();
    expect(alice.pendingCount, 0);
    expect(alice.smoothedRttMs, isNull, reason: 'no 1 ms sample was taken');
  });
}
