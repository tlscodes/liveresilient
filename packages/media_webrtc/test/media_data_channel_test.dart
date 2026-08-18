/// Contract tests for the data-channel surface added to the media layer.
///
/// The in-memory pair here doubles as the executable specification of the
/// MediaDataChannel contract (broadcast streams, hand-off send semantics,
/// idempotent close) that platform bindings and bridge adapters must match.
library;

import 'dart:async';

import 'package:media_webrtc/media_webrtc.dart';
import 'package:test/test.dart';

/// Minimal conforming implementation: two channels cross-wired in memory.
class _InMemoryChannel implements MediaDataChannel {
  _InMemoryChannel(this.label);

  @override
  final String label;

  @override
  int? get bufferedAmount => null; // in-memory: nothing ever queues

  _InMemoryChannel? _peer;
  var _closed = false;
  final _inbound = StreamController<List<int>>.broadcast();
  final _state = StreamController<MediaDataChannelState>.broadcast();

  static (_InMemoryChannel, _InMemoryChannel) pair(String label) {
    final a = _InMemoryChannel(label);
    final b = _InMemoryChannel(label);
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  @override
  var currentState = MediaDataChannelState.connecting;

  void open() {
    currentState = MediaDataChannelState.open;
    _state.add(MediaDataChannelState.open);
  }

  @override
  Stream<List<int>> get inbound => _inbound.stream;

  @override
  Stream<MediaDataChannelState> get state => _state.stream;

  @override
  Future<void> send(List<int> frame) async {
    if (_closed) throw StateError('send after close');
    final peer = _peer;
    if (peer != null && !peer._closed) peer._inbound.add(frame);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    currentState = MediaDataChannelState.closed;
    _state.add(MediaDataChannelState.closed);
    await _inbound.close();
    await _state.close();
  }
}

void main() {
  group('DataChannelConfig.validate', () {
    test('defaults are valid (label vck-messaging, id 0, ordered)', () {
      const config = DataChannelConfig();
      config.validate();
      expect(config.label, 'vck-messaging');
      expect(config.negotiatedId, 0);
      expect(config.ordered, isTrue);
    });

    test('rejects empty and oversized labels', () {
      expect(
        () => const DataChannelConfig(label: '').validate(),
        throwsArgumentError,
      );
      expect(
        () => DataChannelConfig(label: 'x' * 129).validate(),
        throwsArgumentError,
      );
      DataChannelConfig(label: 'x' * 128).validate(); // boundary OK
    });

    test('rejects ids outside the SCTP stream range 0..65534', () {
      expect(
        () => const DataChannelConfig(negotiatedId: -1).validate(),
        throwsArgumentError,
      );
      expect(
        () => const DataChannelConfig(negotiatedId: 65535).validate(),
        throwsArgumentError,
      );
      const DataChannelConfig(negotiatedId: 65534).validate(); // boundary OK
    });

    test('maxRetransmits: null (reliable default) and 0..65535 valid, '
        'out-of-range rejected', () {
      const DataChannelConfig().validate(); // null = reliable, valid
      expect(const DataChannelConfig().maxRetransmits, isNull);
      // 0 is the fountain lane's hard precondition — must be expressible.
      const DataChannelConfig(maxRetransmits: 0).validate();
      const DataChannelConfig(maxRetransmits: 65535).validate();
      expect(
        () => const DataChannelConfig(maxRetransmits: -1).validate(),
        throwsArgumentError,
      );
      expect(
        () => const DataChannelConfig(maxRetransmits: 65536).validate(),
        throwsArgumentError,
      );
    });
  });

  group('MediaDataChannel contract (in-memory reference pair)', () {
    test('frames sent on one side arrive on the other, in order', () async {
      final (a, b) = _InMemoryChannel.pair('vck-messaging');
      final received = <List<int>>[];
      b.inbound.listen(received.add);

      await a.send([1, 2, 3]);
      await a.send([4, 5]);
      await pumpEventQueue();

      expect(received, [
        [1, 2, 3],
        [4, 5],
      ]);
      await a.close();
      await b.close();
    });

    test('state stream reports open then closed', () async {
      final (a, b) = _InMemoryChannel.pair('vck-messaging');
      final states = <MediaDataChannelState>[];
      a.state.listen(states.add);

      a.open();
      await pumpEventQueue();
      await a.close();
      await pumpEventQueue();

      expect(states, [
        MediaDataChannelState.open,
        MediaDataChannelState.closed,
      ]);
      await b.close();
    });

    test('close is idempotent; send after close throws StateError', () async {
      final (a, b) = _InMemoryChannel.pair('vck-messaging');
      await a.close();
      await a.close(); // second close is a no-op, not an error
      expect(() => a.send([1]), throwsStateError);
      await b.close();
    });

    test('send into a closed peer is a silent drop (transport semantics — '
        'reliability belongs to the messaging ack layer)', () async {
      final (a, b) = _InMemoryChannel.pair('vck-messaging');
      await b.close();
      await a.send([9]); // must not throw
      await a.close();
    });
  });
}
