/// Call memory: the seconds cut off by a drop are frozen at the
/// reconnect edge and replayed to the peer over the REAL reliable
/// outbox once the call is live again.
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:messaging/messaging.dart';
import 'package:reference_app/src/call_memory.dart';

class _MemoryPort implements DataChannelPort {
  final _incoming = StreamController<List<int>>.broadcast();
  _MemoryPort? peer;
  bool online = true;

  @override
  Stream<List<int>> get inbound => _incoming.stream;

  @override
  Future<void> send(List<int> frame) async {
    if (online && peer != null && !peer!._incoming.isClosed) {
      peer!._incoming.add(frame);
    }
  }

  @override
  Future<void> close() => _incoming.close();
}

CallState _state(CallPhase phase, int seq, {int attempt = 0}) => CallState(
  phase: phase,
  sequence: seq,
  changedAt: DateTime.utc(2026),
  reconnectAttempt: attempt,
);

void main() {
  group('AudioRingBuffer', () {
    test('byte budget evicts oldest frames first and drain empties', () {
      final buffer = AudioRingBuffer(maxBytes: 10);
      buffer.add([1, 1, 1, 1]); // 4
      buffer.add([2, 2, 2, 2]); // 8
      buffer.add([3, 3, 3, 3]); // 12 -> evicts [1,1,1,1]
      expect(buffer.sizeBytes, 8);
      expect(buffer.drain(), [2, 2, 2, 2, 3, 3, 3, 3]);
      expect(buffer.isEmpty, isTrue);
    });

    test('oversized and empty frames are ignored', () {
      final buffer = AudioRingBuffer(maxBytes: 4);
      buffer.add([]);
      buffer.add([9, 9, 9, 9, 9]);
      expect(buffer.isEmpty, isTrue);
    });
  });

  test('the audio tail buffered before a drop is frozen at the reconnect '
      'edge and delivered to the peer after the call is live again — even '
      'though the transport was down at the freeze moment', () {
    fakeAsync((async) {
      final states = StreamController<CallState>.broadcast();
      final local = _MemoryPort();
      final remote = _MemoryPort();
      local.peer = remote;
      remote.peer = local;

      final messenger = ReliableMessenger(local, peerId: 'caller-memory');
      final remoteMessenger = ReliableMessenger(remote, peerId: 'callee');
      final receiver = AttachmentReceiver();
      final received = <Attachment>[];
      receiver.completed.listen(received.add);
      remoteMessenger.incoming.listen((m) => receiver.offer(m.text));

      late void Function(List<int>) push;
      final memory = CallMemory(
        states: states.stream,
        messenger: () async => messenger,
        tap: (onFrame) {
          push = onFrame;
          return () {};
        },
      );

      var seq = 0;
      states.add(_state(CallPhase.connected, ++seq));
      async.flushMicrotasks();

      // Live audio flows into the ring buffer.
      push([10, 11, 12]);
      push([13, 14, 15]);

      // The path dies mid-sentence: transport down, reconnecting. Two
      // attempts of the SAME outage must keep the first frozen tail.
      local.online = false;
      states.add(_state(CallPhase.reconnecting, ++seq, attempt: 1));
      async.flushMicrotasks();
      push([
        99,
      ]); // Audio during the outage joins the NEXT buffer, not the tail.
      states.add(_state(CallPhase.reconnecting, ++seq, attempt: 2));
      async.flushMicrotasks();
      expect(received, isEmpty);

      // Reconnect lands; transport back. The frozen tail ships once.
      local.online = true;
      states.add(_state(CallPhase.connected, ++seq));
      async.flushMicrotasks();
      for (var i = 0; i < 20; i++) {
        async.elapse(const Duration(seconds: 1));
        unawaited(messenger.tick());
        async.flushMicrotasks();
      }

      expect(received, hasLength(1));
      expect(received.single.contentType, 'audio/replay');
      expect(received.single.bytes, [10, 11, 12, 13, 14, 15]);
      expect(memory.replaysSent, 1);

      // A clean stretch with no drop replays nothing further.
      push([20, 21]);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(received, hasLength(1));

      memory.dispose();
      messenger.close();
      remoteMessenger.close();
      receiver.close();
      states.close();
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 1));
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a terminal phase clears the buffer: nothing replays after the call '
      'ends', () {
    fakeAsync((async) {
      final states = StreamController<CallState>.broadcast();
      final local = _MemoryPort();
      final messenger = ReliableMessenger(local, peerId: 'caller-memory');

      late void Function(List<int>) push;
      final memory = CallMemory(
        states: states.stream,
        messenger: () async => messenger,
        tap: (onFrame) {
          push = onFrame;
          return () {};
        },
      );

      var seq = 0;
      states.add(_state(CallPhase.connected, ++seq));
      async.flushMicrotasks();
      push([1, 2, 3]);
      states.add(
        CallState(
          phase: CallPhase.ended,
          sequence: ++seq,
          changedAt: DateTime.utc(2026),
          endReason: CallEndReason.localHangup,
        ),
      );
      async.flushMicrotasks();

      expect(memory.replaysSent, 0);
      memory.dispose();
      messenger.close();
      states.close();
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
    });
  });
}
