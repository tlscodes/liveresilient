/// [DataChannelPort] implementation over a live [MediaDataChannel].
///
/// Responsibilities (and nothing more):
/// - pass inbound frames through unchanged;
/// - hold frames sent while the channel is still connecting in a small
///   bounded queue and flush them in order on open — so the first chat
///   message typed during call setup is not silently dropped and forced
///   into the ack layer's retry delay;
/// - drop sends into a closed/failed channel without throwing (transport
///   semantics: delivery confirmation is the messaging ack layer's job);
/// - close idempotently, closing the underlying channel.
///
/// No crypto, no retry, no dedup here — the channel already rides the
/// call's DTLS transport, and reliability lives in ReliableMessenger.
library;

import 'dart:async';

import 'package:media_webrtc/media_webrtc.dart';
import 'package:messaging/messaging.dart';

class MediaChannelDataPort implements DataChannelPort {
  /// Wraps [channel]. Subscribes to its streams immediately, so construct
  /// this port before signaling readiness to peers (broadcast-stream rule).
  /// The seed below relaxes that rule for STATE only: an open reported before
  /// construction is recovered from [MediaDataChannel.currentState], but an
  /// inbound frame delivered before construction is still lost (ack layer
  /// recovers it).
  MediaChannelDataPort(this._channel, {this.maxPendingFrames = 64}) {
    if (maxPendingFrames < 1) {
      throw ArgumentError.value(
        maxPendingFrames,
        'maxPendingFrames',
        'must be >= 1',
      );
    }
    _inboundSub = _channel.inbound.listen(_inboundController.add);
    _stateSub = _channel.state.listen(_onState);
    // Seed AFTER subscribing: a channel born open on a live SCTP association
    // emits its open event while nobody listens, and broadcast streams replay
    // nothing — without this line every frame buffers into _pending forever
    // (rig 2026-08-11: staged-photo lane, acked=0 minRtt=-1 retx=0). A later
    // duplicate open from the stream is idempotent in _onState.
    _onState(_channel.currentState);
  }

  final MediaDataChannel _channel;

  /// Cap on frames buffered while the channel is connecting. Overflow drops
  /// the OLDEST frame: the newest user action wins, and the ack layer
  /// retransmits whatever was dropped once the channel opens.
  final int maxPendingFrames;

  final _inboundController = StreamController<List<int>>.broadcast();
  final _pending = <List<int>>[];
  late final StreamSubscription<List<int>> _inboundSub;
  late final StreamSubscription<MediaDataChannelState> _stateSub;
  var _open = false;
  var _closed = false;

  @override
  Stream<List<int>> get inbound => _inboundController.stream;

  void _onState(MediaDataChannelState state) {
    switch (state) {
      case MediaDataChannelState.open:
        _open = true;
        _flushPending();
      case MediaDataChannelState.connecting:
        break;
      case MediaDataChannelState.closing:
      case MediaDataChannelState.closed:
        _open = false;
    }
  }

  void _flushPending() {
    if (_pending.isEmpty) return;
    final frames = List<List<int>>.from(_pending);
    _pending.clear();
    for (final frame in frames) {
      // Fire-and-forget: send() completion means handed to the channel,
      // and per-channel ordering is preserved by sending sequentially in
      // the original order before any later send() runs (single isolate).
      unawaited(_sendNow(frame));
    }
  }

  Future<void> _sendNow(List<int> frame) async {
    try {
      await _channel.send(frame);
    } on Exception {
      // A racing close/failure between the open event and the platform call:
      // transport-level drop, recovered by the ack layer.
    }
  }

  @override
  Future<void> send(List<int> frame) async {
    if (_closed) throw StateError('send after close');
    if (!_open) {
      if (_pending.length >= maxPendingFrames) _pending.removeAt(0);
      _pending.add(frame);
      return;
    }
    await _sendNow(frame);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pending.clear();
    await _inboundSub.cancel();
    await _stateSub.cancel();
    await _channel.close();
    await _inboundController.close();
  }
}
