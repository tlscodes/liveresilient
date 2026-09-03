import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:clock/clock.dart' as clock_pkg;

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

  /// When the FIRST copy left: the round-trip sample base. Only a message
  /// acked after a single transmission is sampled (Karn's rule) — an ack
  /// after a retransmit cannot say which copy it answers.
  final int firstSentMs;
  _Pending(this.message, this.frame, this.attempts, this.lastSentMs)
    : firstSentMs = lastSentMs;
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

  /// The retransmission window BEFORE any round trip was measured, and the
  /// floor under the measured one. See [currentRetryAfter].
  final Duration retryAfter;
  final int maxAttempts;
  final Clock _clock;

  /// Cap on the measured window and on its backoff.
  static const Duration maxRetryAfter = Duration(seconds: 30);

  /// Smoothed round trip and its variance from single-transmission acks
  /// (RFC 6298 seeding and gains). Null until the first ack: a 12 KB
  /// attachment chunk on a 32 kbit/s link drains in seconds, and a fixed
  /// 2 s window re-sent every chunk before its ack could arrive — doubling
  /// the load on the link that was already the problem (rig, 2026-09-04).
  double? _srttMs;
  double _rttvarMs = 0;

  /// Maximum number of received-message ids retained for de-duplication.
  final int maxSeenEntries;

  int _seq = 0;
  final _pending = <String, _Pending>{};

  /// Insertion-ordered, capped de-dup set: oldest id is evicted once
  /// [maxSeenEntries] is exceeded, so a long-lived peer connection cannot
  /// grow this unboundedly (mirrors `LinkSeenCache` in device_link).
  final _seen = LinkedHashSet<String>();
  final _incoming = StreamController<ChatMessage>.broadcast();
  final _deliveries = StreamController<(String, DeliveryState)>.broadcast();
  late final StreamSubscription<List<int>> _sub;
  bool _closed = false;

  /// Short per-instance random component mixed into generated message ids so
  /// a rebuilt messenger (whose [_seq] restarts at 0) never reuses an id the
  /// peer's de-dup set already saw. Six hex chars, derived once at
  /// construction from [random] (or a secure default).
  final String _instanceTag;

  ReliableMessenger(
    this._port, {
    required this.peerId,
    this.retryAfter = const Duration(seconds: 2),
    this.maxAttempts = 5,
    this.maxSeenEntries = 4096,
    Clock? clock,
    Random? random,
    // Default to the zone-scoped clock (package:clock's top-level `clock`)
    // instead of the raw system clock, so `fakeAsync`/`withClock` tests can
    // drive retry windows deterministically. Outside such zones this IS the
    // system clock — production behavior is unchanged.
  }) : _clock = clock ?? clock_pkg.clock,
       _instanceTag = _makeInstanceTag(random ?? Random.secure()),
       assert(maxAttempts >= 1),
       assert(maxSeenEntries >= 1) {
    _sub = _port.inbound.listen(
      _onFrame,
      // A broken/hostile port must not become an unhandled zone error: the
      // simplest safe behavior is to drop the errored event and keep the
      // messenger running (the app layer observes failures via `deliveries`
      // and `tick()`, not via the port's error channel).
      onError: (_, __) {},
    );
  }

  static String _makeInstanceTag(Random random) {
    const chars = '0123456789abcdef';
    return List.generate(6, (_) => chars[random.nextInt(16)]).join();
  }

  /// Messages received from the peer, de-duplicated (each id emitted once).
  Stream<ChatMessage> get incoming => _incoming.stream;

  /// Delivery-state transitions for locally-sent messages.
  Stream<(String, DeliveryState)> get deliveries => _deliveries.stream;

  /// Count of locally-sent messages still awaiting acknowledgement.
  int get pendingCount => _pending.length;

  /// The retransmission window in force: [retryAfter] until a round trip
  /// has been measured, then srtt + 4·rttvar clamped to
  /// [retryAfter, maxRetryAfter]. Once measured, each retransmission of a
  /// message doubles its own window (Karn backoff), capped the same way.
  Duration get currentRetryAfter {
    final srtt = _srttMs;
    if (srtt == null) return retryAfter;
    final rto = (srtt + 4 * _rttvarMs).round();
    return Duration(
      milliseconds: rto.clamp(
        retryAfter.inMilliseconds,
        maxRetryAfter.inMilliseconds,
      ),
    );
  }

  /// Last measured smoothed round trip in milliseconds, null before an ack.
  double? get smoothedRttMs => _srttMs;

  Duration _windowFor(_Pending p) {
    final base = currentRetryAfter;
    if (_srttMs == null || p.attempts <= 1) return base;
    final shift = (p.attempts - 1).clamp(0, 6);
    final backedOff = base.inMilliseconds << shift;
    return Duration(
      milliseconds: backedOff.clamp(
        base.inMilliseconds,
        maxRetryAfter.inMilliseconds,
      ),
    );
  }

  void _sampleRtt(int sampleMs) {
    final sample = sampleMs.toDouble();
    final srtt = _srttMs;
    if (srtt == null) {
      _srttMs = sample;
      _rttvarMs = sample / 2;
    } else {
      _rttvarMs = _rttvarMs * 0.75 + (srtt - sample).abs() * 0.25;
      _srttMs = srtt * 0.875 + sample * 0.125;
    }
  }

  /// Sends [text]; returns the created [ChatMessage]. Retransmits happen on
  /// [tick] until an ack arrives or [maxAttempts] transmissions are exhausted.
  Future<ChatMessage> send(String text) async {
    if (_closed) throw StateError('ReliableMessenger is closed');
    final nowMs = _clock.now().millisecondsSinceEpoch;
    final seq = _seq++;
    final msg = ChatMessage(
      id: '$peerId-$_instanceTag-$seq',
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

  /// Retransmits pending messages whose window ([currentRetryAfter], backed
  /// off per retransmission) elapsed, and fails those that reach
  /// [maxAttempts]. Call periodically from the app layer.
  Future<void> tick() async {
    if (_closed) throw StateError('ReliableMessenger is closed');
    final nowMs = _clock.now().millisecondsSinceEpoch;
    for (final p in _pending.values.toList()) {
      if (nowMs - p.lastSentMs < _windowFor(p).inMilliseconds) continue;
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
        final acked = _pending.remove(id);
        if (acked != null) {
          if (acked.attempts == 1) {
            _sampleRtt(_clock.now().millisecondsSinceEpoch - acked.firstSentMs);
          }
          _deliveries.add((id, DeliveryState.delivered));
        }
      case MessageFrame(:final message):
        // Ack every copy so the sender can stop retrying, but surface the
        // message to the app only once.
        await _port.send(WireCodec.encodeAck(message.id));
        if (_seen.add(message.id)) {
          while (_seen.length > maxSeenEntries) {
            _seen.remove(_seen.first);
          }
          _incoming.add(message);
        }
    }
  }

  /// Closes the messenger and the underlying port. Any message still
  /// awaiting acknowledgement is reported as [DeliveryState.failed] first, so
  /// callers never see it silently vanish.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final p in _pending.values.toList()) {
      _deliveries.add((p.message.id, DeliveryState.failed));
    }
    _pending.clear();
    await _sub.cancel();
    await _incoming.close();
    await _deliveries.close();
    await _port.close();
  }
}
