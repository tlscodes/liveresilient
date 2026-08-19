/// Cross-piped [MediaDataChannel] pair for the chat-over-call E2E suite.
///
/// The real SCTP data channel is device-bound (it lives inside the platform
/// WebRTC stack), so this suite substitutes the media boundary exactly the
/// way `HandshakingFakeMedia` substitutes audio: everything above the
/// boundary — messaging reliability, chunked attachments, the bridge
/// adapter, both call controllers, real TLS signaling — is the genuine
/// article. The pair "opens" when the test observes both call stacks
/// connected, modeling the negotiated channel opening on DTLS-up.
library;

import 'dart:async';

import 'package:media_webrtc/media_webrtc.dart';

class InMemoryMediaChannel implements MediaDataChannel {
  InMemoryMediaChannel(this.label);

  @override
  final String label;

  InMemoryMediaChannel? _peer;
  var _closed = false;
  final _inbound = StreamController<List<int>>.broadcast();
  final _state = StreamController<MediaDataChannelState>.broadcast();

  static (InMemoryMediaChannel, InMemoryMediaChannel) pair({
    String label = 'vck-messaging',
  }) {
    final a = InMemoryMediaChannel(label);
    final b = InMemoryMediaChannel(label);
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  /// Reports the channel open, as the platform would once DTLS/SCTP is up.
  void open() => _state.add(MediaDataChannelState.open);

  @override
  Stream<List<int>> get inbound => _inbound.stream;

  // In-memory pair: frames hand over synchronously, nothing ever queues.
  @override
  int? get bufferedAmount => null;

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
    _state.add(MediaDataChannelState.closed);
    await _inbound.close();
    await _state.close();
  }
}
