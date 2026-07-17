import 'dart:async';

import 'package:clock/clock.dart';
import 'package:messaging/messaging.dart';
import 'package:test/test.dart';

/// In-memory data channel with a controllable drop switch, for loopback tests.
class MemPort implements DataChannelPort {
  final _in = StreamController<List<int>>.broadcast();
  MemPort? peer;
  bool dropOutbound = false;
  final sent = <List<int>>[];

  @override
  Stream<List<int>> get inbound => _in.stream;

  @override
  Future<void> send(List<int> frame) async {
    sent.add(frame);
    if (dropOutbound) return; // simulate loss
    peer?._in.add(frame);
  }

  @override
  Future<void> close() async {
    if (!_in.isClosed) await _in.close();
  }
}

(MemPort, MemPort) pair() {
  final a = MemPort();
  final b = MemPort();
  a.peer = b;
  b.peer = a;
  return (a, b);
}

void main() {
  test('round-trip: message delivered, receiver emits once, sender acked', () async {
    final (a, b) = pair();
    final alice = ReliableMessenger(a, peerId: 'alice');
    final bob = ReliableMessenger(b, peerId: 'bob');
    final received = <ChatMessage>[];
    final delivered = <String>[];
    bob.incoming.listen(received.add);
    alice.deliveries.listen((e) {
      if (e.$2 == DeliveryState.delivered) delivered.add(e.$1);
    });

    final sent = await alice.send('salaam');
    await pumpEventQueue();

    expect(received, hasLength(1));
    expect(received.single.text, 'salaam');
    expect(received.single.senderId, 'alice');
    expect(alice.pendingCount, 0);
    expect(delivered, [sent.id]);

    await alice.close();
    await bob.close();
  });

  test('retransmission + de-dup: dropped acks cause resend, receiver still once',
      () async {
    var now = DateTime.utc(2026, 1, 1);
    final (a, b) = pair();
    final alice = ReliableMessenger(
      a,
      peerId: 'alice',
      clock: Clock(() => now),
      retryAfter: const Duration(seconds: 2),
    );
    final bob = ReliableMessenger(b, peerId: 'bob');
    final received = <ChatMessage>[];
    bob.incoming.listen(received.add);

    b.dropOutbound = true; // bob's acks never reach alice
    await alice.send('hi');
    await pumpEventQueue();
    expect(received, hasLength(1));
    expect(alice.pendingCount, 1); // no ack yet

    now = now.add(const Duration(seconds: 3));
    await alice.tick(); // retransmit
    await pumpEventQueue();

    expect(a.sent.length, 2); // sent twice
    expect(received, hasLength(1)); // but received/emitted once (de-duped)
    expect(alice.pendingCount, 1); // still unacked

    await alice.close();
    await bob.close();
  });

  test('gives up after maxAttempts with a failed delivery', () async {
    var now = DateTime.utc(2026, 1, 1);
    final (a, b) = pair();
    final alice = ReliableMessenger(
      a,
      peerId: 'alice',
      clock: Clock(() => now),
      retryAfter: const Duration(seconds: 1),
      maxAttempts: 2,
    );
    b.dropOutbound = true;
    a.dropOutbound = true; // fully partitioned
    final failed = <String>[];
    alice.deliveries.listen((e) {
      if (e.$2 == DeliveryState.failed) failed.add(e.$1);
    });

    final msg = await alice.send('anyone?');
    for (var i = 0; i < 3; i++) {
      now = now.add(const Duration(seconds: 2));
      await alice.tick();
    }
    await pumpEventQueue();

    expect(failed, [msg.id]);
    expect(alice.pendingCount, 0);

    await alice.close();
  });

  test('malformed frames are ignored, not thrown', () async {
    final (a, b) = pair();
    final bob = ReliableMessenger(b, peerId: 'bob');
    final received = <ChatMessage>[];
    bob.incoming.listen(received.add);

    await a.send([1, 2, 3, 99]); // garbage bytes to bob
    await a.send('{"not":"a frame"}'.codeUnits);
    await pumpEventQueue();

    expect(received, isEmpty);
    await bob.close();
  });
}
