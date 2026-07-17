import 'dart:async';

import 'package:clock/clock.dart';

import 'chat_message.dart';
import 'data_channel_port.dart';
import 'wire_frame.dart';

/// Delivery outcome for a locally-sent message.
enum DeliveryState { delivered, failed }

class _Pending {
  final ChatMessage message;
  final List<int> frame;
  int attempts;
  int lastSentMs;
  _Pending(this.message, this.frame, this.attempts, this.lastSentMs);
}

/// Reliable text messaging over a [DataChannelPort]: at-least-once delivery
/// with acknowledgements, receiver-side de-duplication, and app-driven retry
/// ([tick]) so the core stays timer-free and deterministically testable.
///
/// A WebRTC DataChannel can already run in reliable-ordered mode, but that
/// guarantee ends at reconnect. This layer survives channel replacement: the
/// outbox keeps unacked messages and [tick] retransmits them on a fresh port.
class ReliableMessenger {
  final DataChannelPort _port;
  final String peerId;
  final Duration retryAfter;
  final int maxAttempts;
  final Clock _clock;

  int _seq = 0;
  final _pending = <String, _Pending>{};
  final _seen = <String>{};
  final _incoming = StreamController<ChatMessage>.broadcast();
  final _deliveries = StreamController<(String, DeliveryState)>.broadcast();
  late final StreamSubscription<List<int>> _sub;
  bool _closed = false;

  ReliableMessenger(
    this._port, {
    required this.peerId,
    this.retryAfter = const Duration(seconds: 2),
    this.maxAttempts = 5,
    Clock? clock,
  }) : _clock = clock ?? const Clock(),
       assert(maxAttempts >= 1) {
    _sub = _port.inbound.listen(_onFrame);
  }

  /// Messages received from the peer, de-duplicated (each id emitted once).
  Stream<ChatMessage> get incoming => _incoming.stream;

  /// Delivery-state transitions for locally-sent messages.
  Stream<(String, DeliveryState)> get deliveries => _deliveries.stream;

  /// Count of locally-sent messages still awaiting acknowledgement.
  int get pendingCount => _pending.length;

  /// Sends [text]; returns the created [ChatMessage]. Retransmits happen on
  /// [tick] until an ack arrives or [maxAttempts] transmissions are exhausted.
  Future<ChatMessage> send(String text) async {
    final nowMs = _clock.now().millisecondsSinceEpoch;
    final seq = _seq++;
    final msg = ChatMessage(
      id: '$peerId-$seq',
      senderId: peerId,
      seq: seq,
      sentAtMs: nowMs,
      text: text,
    );
    final frame = WireCodec.encodeMessage(msg);
    _pending[msg.id] = _Pending(msg, frame, 1, nowMs);
    await _port.send(frame);
    return msg;
  }

  /// Retransmits pending messages whose [retryAfter] window elapsed, and fails
  /// those that reach [maxAttempts]. Call periodically from the app layer.
  Future<void> tick() async {
    final nowMs = _clock.now().millisecondsSinceEpoch;
    for (final p in _pending.values.toList()) {
      if (nowMs - p.lastSentMs < retryAfter.inMilliseconds) continue;
      if (p.attempts >= maxAttempts) {
        _pending.remove(p.message.id);
        _deliveries.add((p.message.id, DeliveryState.failed));
        continue;
      }
      p.attempts++;
      p.lastSentMs = nowMs;
      await _port.send(p.frame);
    }
  }

  Future<void> _onFrame(List<int> bytes) async {
    final frame = WireCodec.tryDecode(bytes);
    switch (frame) {
      case null:
        return; // ignore malformed / hostile input
      case AckFrame(:final id):
        if (_pending.remove(id) != null) {
          _deliveries.add((id, DeliveryState.delivered));
        }
      case MessageFrame(:final message):
        // Ack every copy so the sender can stop retrying, but surface the
        // message to the app only once.
        await _port.send(WireCodec.encodeAck(message.id));
        if (_seen.add(message.id)) {
          _incoming.add(message);
        }
    }
  }

  /// Closes the messenger and the underlying port.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub.cancel();
    await _incoming.close();
    await _deliveries.close();
    await _port.close();
  }
}
