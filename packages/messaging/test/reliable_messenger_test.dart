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
  test(
    'round-trip: message delivered, receiver emits once, sender acked',
    () async {
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
    },
  );

  test(
    'retransmission + de-dup: dropped acks cause resend, receiver still once',
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
    },
  );

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

  test('capped de-dup: oldest seen id evicted, newest retained, re-sent oldest '
      'id accepted again', () async {
    final (a, b) = pair();
    final bob = ReliableMessenger(b, peerId: 'bob', maxSeenEntries: 4);
    final received = <String>[];
    bob.incoming.listen((m) => received.add(m.id));

    // Send 5 distinct raw message frames directly (bypassing alice's
    // instance so ids are simple and ordering is explicit).
    for (var i = 0; i < 5; i++) {
      final frame = WireCodec.encodeMessage(
        ChatMessage(
          id: 'm$i',
          senderId: 'alice',
          seq: i,
          sentAtMs: i,
          text: 'msg$i',
        ),
      );
      await a.send(frame);
    }
    await pumpEventQueue();

    expect(received, ['m0', 'm1', 'm2', 'm3', 'm4']);

    // m0 was evicted (cap 4, 5 inserted) so re-sending it is accepted
    // again as new; m4 (newest) is retained and must NOT be re-emitted.
    final resendM0 = WireCodec.encodeMessage(
      ChatMessage(id: 'm0', senderId: 'alice', seq: 0, sentAtMs: 0, text: 'x'),
    );
    final resendM4 = WireCodec.encodeMessage(
      ChatMessage(id: 'm4', senderId: 'alice', seq: 4, sentAtMs: 4, text: 'x'),
    );
    await a.send(resendM0);
    await a.send(resendM4);
    await pumpEventQueue();

    expect(received, ['m0', 'm1', 'm2', 'm3', 'm4', 'm0']);

    await bob.close();
  });

  test('close() emits failed for every still-pending message', () async {
    final (a, b) = pair();
    b.dropOutbound = true; // acks never arrive
    final alice = ReliableMessenger(a, peerId: 'alice');
    final failed = <String>[];
    alice.deliveries.listen((e) {
      if (e.$2 == DeliveryState.failed) failed.add(e.$1);
    });

    final m1 = await alice.send('one');
    final m2 = await alice.send('two');
    await pumpEventQueue();
    expect(alice.pendingCount, 2);

    await alice.close();

    expect(failed, containsAll([m1.id, m2.id]));
    expect(failed, hasLength(2));
  });

  test('send()/tick() after close() throw StateError', () async {
    final a = MemPort();
    final alice = ReliableMessenger(a, peerId: 'alice');
    await alice.close();

    // send()/tick() are `async`, so the StateError surfaces as a rejected
    // Future, not a synchronous throw — pass the Future itself.
    await expectLater(alice.send('late'), throwsStateError);
    await expectLater(alice.tick(), throwsStateError);
  });

  test(
    'two messengers with the same peerId produce non-colliding ids',
    () async {
      final (a, b) = pair();
      final alice1 = ReliableMessenger(a, peerId: 'alice');
      final alice2 = ReliableMessenger(b, peerId: 'alice');

      final m1 = await alice1.send('hi');
      final m2 = await alice2.send('hi');

      expect(m1.id, isNot(equals(m2.id)));

      await alice1.close();
      await alice2.close();
    },
  );
}
