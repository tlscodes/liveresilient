import 'dart:async';

import 'package:media_webrtc/media_webrtc.dart';
import 'package:messaging/messaging.dart';
import 'package:messaging_webrtc_adapter/messaging_webrtc_adapter.dart';
import 'package:test/test.dart';

/// Controllable fake channel: scripted state, recorded sends, optional
/// failure mode, and a cross-wired peer for end-to-end tests.
class FakeMediaChannel implements MediaDataChannel {
  FakeMediaChannel({this.label = 'vck-messaging'});

  @override
  final String label;

  FakeMediaChannel? peer;
  final sent = <List<int>>[];
  var failSends = false;
  var closed = false;
  final _inbound = StreamController<List<int>>.broadcast();
  final _state = StreamController<MediaDataChannelState>.broadcast();

  static (FakeMediaChannel, FakeMediaChannel) pair() {
    final a = FakeMediaChannel();
    final b = FakeMediaChannel();
    a.peer = b;
    b.peer = a;
    return (a, b);
  }

  void setState(MediaDataChannelState state) => _state.add(state);

  void deliver(List<int> frame) => _inbound.add(frame);

  @override
  Stream<List<int>> get inbound => _inbound.stream;

  @override
  Stream<MediaDataChannelState> get state => _state.stream;

  @override
  Future<void> send(List<int> frame) async {
    if (failSends) throw Exception('simulated platform send failure');
    sent.add(frame);
    final remote = peer;
    if (remote != null && !remote.closed) remote._inbound.add(frame);
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _inbound.close();
    await _state.close();
  }
}

void main() {
  test('inbound frames pass through unchanged', () async {
    final channel = FakeMediaChannel();
    final port = MediaChannelDataPort(channel);
    final received = <List<int>>[];
    port.inbound.listen(received.add);

    channel.deliver([1, 2, 3]);
    await pumpEventQueue();

    expect(received, [
      [1, 2, 3],
    ]);
    await port.close();
  });

  test('send while open forwards immediately', () async {
    final channel = FakeMediaChannel();
    final port = MediaChannelDataPort(channel);
    channel.setState(MediaDataChannelState.open);
    await pumpEventQueue();

    await port.send([7]);
    expect(channel.sent, [
      [7],
    ]);
    await port.close();
  });

  test('frames sent while connecting are buffered and flushed IN ORDER on '
      'open; later sends go direct', () async {
    final channel = FakeMediaChannel();
    final port = MediaChannelDataPort(channel);

    await port.send([1]);
    await port.send([2]);
    expect(channel.sent, isEmpty, reason: 'nothing sent before open');

    channel.setState(MediaDataChannelState.open);
    await pumpEventQueue();
    expect(channel.sent, [
      [1],
      [2],
    ]);

    await port.send([3]);
    expect(channel.sent, [
      [1],
      [2],
      [3],
    ]);
    await port.close();
  });

  test('pre-open buffer is bounded: overflow drops the OLDEST frame', () async {
    final channel = FakeMediaChannel();
    final port = MediaChannelDataPort(channel, maxPendingFrames: 2);

    await port.send([1]);
    await port.send([2]);
    await port.send([3]); // evicts [1]

    channel.setState(MediaDataChannelState.open);
    await pumpEventQueue();
    expect(channel.sent, [
      [2],
      [3],
    ]);
    await port.close();
  });

  test('maxPendingFrames must be >= 1', () {
    expect(
      () => MediaChannelDataPort(FakeMediaChannel(), maxPendingFrames: 0),
      throwsArgumentError,
    );
  });

  test('a send that throws in the platform channel is a silent transport '
      'drop (ack layer owns recovery)', () async {
    final channel = FakeMediaChannel()..failSends = true;
    final port = MediaChannelDataPort(channel);
    channel.setState(MediaDataChannelState.open);
    await pumpEventQueue();

    await port.send([9]); // must not throw
    expect(channel.sent, isEmpty);
    await port.close();
  });

  test('close is idempotent, closes the underlying channel, and send after '
      'close throws StateError', () async {
    final channel = FakeMediaChannel();
    final port = MediaChannelDataPort(channel);

    await port.close();
    await port.close();
    expect(channel.closed, isTrue);
    expect(() => port.send([1]), throwsStateError);
  });

  test('channel closing mid-session stops direct sends (frames buffer again, '
      'bounded) without throwing at the caller', () async {
    final channel = FakeMediaChannel();
    final port = MediaChannelDataPort(channel);
    channel.setState(MediaDataChannelState.open);
    await pumpEventQueue();
    await port.send([1]);

    channel.setState(MediaDataChannelState.closed);
    await pumpEventQueue();
    await port.send([2]); // buffered, not thrown
    expect(channel.sent, [
      [1],
    ]);
    await port.close();
  });

  group('end-to-end: ReliableMessenger over the bridged channel pair', () {
    test('text message round-trips and the ack drains pendingCount across '
        'two full messaging stacks riding MediaDataChannels', () async {
      final (channelA, channelB) = FakeMediaChannel.pair();
      final portA = MediaChannelDataPort(channelA);
      final portB = MediaChannelDataPort(channelB);

      final alice = ReliableMessenger(portA, peerId: 'alice');
      final bob = ReliableMessenger(portB, peerId: 'bob');
      final bobGot = <ChatMessage>[];
      bob.incoming.listen(bobGot.add);

      channelA.setState(MediaDataChannelState.open);
      channelB.setState(MediaDataChannelState.open);
      await pumpEventQueue();

      await alice.send('سلام از روی کانالِ تماس');
      await pumpEventQueue();

      expect(bobGot, hasLength(1));
      expect(bobGot.single.text, 'سلام از روی کانالِ تماس');
      // Bob auto-acked over the same bridged pair; nothing left pending.
      expect(alice.pendingCount, 0);

      await alice.close();
      await bob.close();
      await portA.close();
      await portB.close();
    });

    test('chunked attachment reassembles across the bridged pair', () async {
      final (channelA, channelB) = FakeMediaChannel.pair();
      final portA = MediaChannelDataPort(channelA);
      final portB = MediaChannelDataPort(channelB);

      final alice = ReliableMessenger(portA, peerId: 'alice');
      final bob = ReliableMessenger(portB, peerId: 'bob');
      final receiver = AttachmentReceiver();
      final bobAttachments = <Attachment>[];
      receiver.completed.listen(bobAttachments.add);
      bob.incoming.listen((message) => receiver.offer(message.text));

      channelA.setState(MediaDataChannelState.open);
      channelB.setState(MediaDataChannelState.open);
      await pumpEventQueue();

      final photoBytes = List<int>.generate(70 * 1024, (i) => i % 251);
      await sendAttachment(
        alice,
        Attachment(
          id: 'photo-1',
          kind: MediaKind.image,
          contentType: 'image/jpeg',
          bytes: photoBytes,
        ),
      );
      await pumpEventQueue();

      expect(bobAttachments, hasLength(1));
      expect(bobAttachments.single.id, 'photo-1');
      expect(bobAttachments.single.bytes, photoBytes);
      expect(alice.pendingCount, 0);

      await receiver.close();
      await alice.close();
      await bob.close();
      await portA.close();
      await portB.close();
    });
  });
}
