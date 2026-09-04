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

/// Why a message failed, with every number the decision was made from, so
/// the next failure is diagnosable from one log line instead of a rebuild.
///
/// Born on the rig's narrow profile (16 kbit/s shared with a live call,
/// 2026-09-04): a 16.6 KB attachment chunk was resent twelve times at a
/// fixed 2 s and failed ten seconds BEFORE its first copy could have been
/// acknowledged — and the log said only "failed".
class DeliveryFailure {
  final String messageId;
  final int attempts;

  /// Wall time since the first transmission.
  final int elapsedMs;

  /// Time since the first transmission with paused intervals removed — the
  /// clock the delivery budget runs on.
  final int elapsedLiveMs;
  final int frameBytes;

  /// The retransmission window in force at each retransmission.
  final List<int> windowsMs;
  final double? srttMs;
  final double rttvarMs;
  final int? rateBytesPerSec;

  /// Where the round-trip term came from: `sample` (measured ack),
  /// `transport` (seeded from the transport's own estimate) or `floor`
  /// (the constructor's [ReliableMessenger.retryAfter]).
  final String seedSource;
  final int? bufferedAtSend;
  final int? bufferedNow;

  /// Whether the transport had drained the frame's last copy when it failed.
  final bool leftBuffer;
  final String reason;

  const DeliveryFailure({
    required this.messageId,
    required this.attempts,
    required this.elapsedMs,
    required this.elapsedLiveMs,
    required this.frameBytes,
    required this.windowsMs,
    required this.srttMs,
    required this.rttvarMs,
    required this.rateBytesPerSec,
    required this.seedSource,
    required this.bufferedAtSend,
    required this.bufferedNow,
    required this.leftBuffer,
    required this.reason,
  });

  @override
  String toString() =>
      'attempts=$attempts elapsed=${elapsedMs}ms live=${elapsedLiveMs}ms '
      'frame=${frameBytes}B windows=${windowsMs.join('/')}ms '
      'srtt=${srttMs?.round() ?? '-'}ms rttvar=${rttvarMs.round()}ms '
      'rate=${rateBytesPerSec ?? '-'}B/s seed=$seedSource '
      'buffered=${bufferedAtSend ?? '-'}->${bufferedNow ?? '-'} '
      'left=$leftBuffer reason=$reason';
}

class _Pending {
  final ChatMessage message;
  final List<int> frame;
  int attempts;
  int lastSentMs;

  /// When the FIRST copy left: the round-trip sample base. Only a message
  /// acked after a single transmission is sampled (Karn's rule) — an ack
  /// after a retransmit cannot say which copy it answers.
  final int firstSentMs;

  /// Time-based failure criterion on the live clock, null = count-based.
  final int? deliveryBudgetMs;

  /// The messenger's accumulated pause time when this message was sent, so
  /// only pauses AFTER the send are subtracted from its live clock.
  final int pausedAccumAtSendMs;

  /// Transport bytes queued ahead of the last (re)transmission.
  int? bufferedAtSend;

  /// Cumulative bytes handed to the port right after the last (re)send; the
  /// frame has left the transport once the drained total reaches it.
  int handedMark = 0;

  /// The window in force at each retransmission (evidence for the record).
  final windowsMs = <int>[];

  _Pending(
    this.message,
    this.frame,
    this.attempts,
    this.lastSentMs, {
    required this.deliveryBudgetMs,
    required this.pausedAccumAtSendMs,
  }) : firstSentMs = lastSentMs;
}

/// Reliable text messaging over a [DataChannelPort]: at-least-once delivery
/// with acknowledgements, receiver-side de-duplication, and app-driven retry
/// ([tick]) so the core stays timer-free and deterministically testable.
///
/// A WebRTC DataChannel can already run in reliable-ordered mode, but that
/// guarantee ends at reconnect. This layer survives channel replacement: the
/// outbox keeps unacked messages and [tick] retransmits them on a fresh port.
///
/// The retransmission window is a MODEL of the frame on the path, not a
/// constant (RFC 6298 with two additions the rig forced):
///
///   window = serialization + rto, doubled per retransmission, clamped
///   serialization = (bytes queued ahead + frame bytes x 1.08) / lane rate
///   rto = srtt + 4·rttvar once an ack was sampled;
///         3 x the transport's own round-trip estimate before that;
///         [retryAfter] when neither exists
///
/// The backoff applies from the first attempt even without a sample
/// (RFC 6298 §5.5): on a path whose round trip exceeds [retryAfter] no
/// single-transmission ack can ever beat the floor, so a sample would never
/// seed and the old fixed window resent every frame forever. A frame still
/// queued in the transport's send buffer is never retransmitted — it cannot
/// have been lost, and a copy behind it only lengthens the queue.
class ReliableMessenger {
  final DataChannelPort _port;
  final String peerId;

  /// The retransmission window BEFORE any round trip was measured or seeded,
  /// and the floor under the measured one. See [currentRetryAfter].
  final Duration retryAfter;

  /// Cap on the number of copies of one frame. Without [deliveryBudget]
  /// reaching it fails the message (count-based, the original contract);
  /// with a budget it only stops further duplicates and the budget decides.
  final int maxAttempts;
  final Clock _clock;

  /// Time a message may stay undelivered on a LIVE path (pauses excluded)
  /// before it fails. Null keeps the count-based criterion. A per-message
  /// budget can be given to [send].
  final Duration? deliveryBudget;

  /// The lane's send-rate budget in bytes per second (the same signal the
  /// binary lanes read from the lane governor). Null or non-positive: the
  /// messenger falls back to its own acked-bytes rate, then to no
  /// serialization term at all.
  final int? Function()? sendBudgetBytesPerSec;

  /// Bytes queued in the transport (RTCDataChannel.bufferedAmount). Null:
  /// the buffer is unknown and every frame is assumed to have left.
  final int? Function()? transportBufferedBytes;

  /// The transport's own round-trip estimate in milliseconds, used to seed
  /// the window until an ack is sampled. Null or non-positive: no seed.
  final int? Function()? transportRttMs;

  /// Cap on the round-trip term of the window and on its backoff. The
  /// serialization term can raise the cap for a large frame (3 x its own
  /// serialization time) so a slow link never truncates the window below
  /// the time the frame needs to leave.
  static const Duration maxRetryAfter = Duration(seconds: 30);

  /// Wire bytes per frame byte on the data channel: ~93 B of IP, UDP, DTLS
  /// and SCTP framing per ~1.2 KB packet (measured 2026-09-04). Applied to
  /// the serialization term only.
  static const double wireOverhead = 1.08;

  /// Smoothed round trip and its variance from single-transmission acks
  /// (RFC 6298 seeding and gains), with the frame's own serialization time
  /// removed from each sample so a 16 KB chunk on a thin link does not
  /// teach srtt = 35 s. Null until the first clean ack.
  double? _srttMs;
  double _rttvarMs = 0;

  /// Maximum number of received-message ids retained for de-duplication.
  final int maxSeenEntries;

  int _seq = 0;
  final _pending = <String, _Pending>{};

  /// Cumulative bytes handed to the port (data frames, retransmits, acks);
  /// with [transportBufferedBytes] this says how much has drained.
  int _handed = 0;
  int _ackedBytes = 0;
  int _acks = 0;
  int? _firstSendMs;
  int _duplicateFrames = 0;

  bool _paused = false;
  int _pausedAccumMs = 0;
  int? _pauseStartedMs;

  /// Insertion-ordered, capped de-dup set: oldest id is evicted once
  /// [maxSeenEntries] is exceeded, so a long-lived peer connection cannot
  /// grow this unboundedly (mirrors `LinkSeenCache` in device_link).
  final _seen = LinkedHashSet<String>();
  final _incoming = StreamController<ChatMessage>.broadcast();
  final _deliveries = StreamController<(String, DeliveryState)>.broadcast();
  final _failures = StreamController<DeliveryFailure>.broadcast();
  late final StreamSubscription<List<int>> _sub;
  bool _closed = false;

  /// The most recent failure record, for callers that only see the
  /// [deliveries] tuple (the attachment sender puts it in its error text).
  DeliveryFailure? lastFailure;

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
    this.deliveryBudget,
    this.sendBudgetBytesPerSec,
    this.transportBufferedBytes,
    this.transportRttMs,
    Clock? clock,
    Random? random,
    // Default to the zone-scoped clock (package:clock's top-level `clock`)
    // instead of the raw system clock, so `fakeAsync`/`withClock` tests can
    // drive retry windows deterministically. Outside such zones this IS the
    // system clock — production behavior is unchanged.
  }) : _clock = clock ?? clock_pkg.clock,
       _instanceTag = _makeInstanceTag(random ?? Random.secure()),
       assert(maxAttempts >= 1),
       assert(maxSeenEntries >= 1),
       assert(retryAfter <= maxRetryAfter) {
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

  /// The record behind every failed delivery, emitted just before the
  /// matching [deliveries] tuple.
  Stream<DeliveryFailure> get failures => _failures.stream;

  /// Count of locally-sent messages still awaiting acknowledgement.
  int get pendingCount => _pending.length;

  /// Frames sent more than once since construction.
  int get duplicateFrames => _duplicateFrames;

  /// Whether [tick] is frozen (a recovery episode: see [pause]).
  bool get isPaused => _paused;

  /// The round-trip term of the window: [retryAfter] until a round trip has
  /// been measured or seeded, then srtt + 4·rttvar (or 3 x the transport's
  /// estimate) clamped to [retryAfter, maxRetryAfter]. The serialization
  /// term is per frame and comes on top (see the class comment).
  Duration get currentRetryAfter => Duration(
    milliseconds: _rtoBaseMs().round().clamp(
      retryAfter.inMilliseconds,
      maxRetryAfter.inMilliseconds,
    ),
  );

  /// Last measured smoothed round trip in milliseconds, null before an ack.
  double? get smoothedRttMs => _srttMs;

  /// The lane rate the serialization term uses, null when unknown.
  int? get rateBytesPerSec => _rate();

  /// One line for a log: what the window is made of right now.
  String describe() =>
      'pending=${_pending.length} srtt=${_srttMs?.round() ?? '-'}ms '
      'rto=${currentRetryAfter.inMilliseconds}ms rate=${_rate() ?? '-'}B/s '
      'seed=$_seedSource dup=$_duplicateFrames paused=$_paused';

  /// Freezes retransmission and the live clock of every pending message: a
  /// recovery episode is not evidence of loss, and attempts spent into a
  /// dead channel are attempts the message no longer has when the path is
  /// back. Sends while paused still go out (the port decides).
  void pause() {
    if (_paused) return;
    _paused = true;
    _pauseStartedMs = _clock.now().millisecondsSinceEpoch;
  }

  /// Resumes from the same attempt counts; a window that elapsed during
  /// the pause retransmits on the next [tick] once its frame has drained.
  void resume() {
    if (!_paused) return;
    final started = _pauseStartedMs;
    if (started != null) {
      _pausedAccumMs += _clock.now().millisecondsSinceEpoch - started;
    }
    _paused = false;
    _pauseStartedMs = null;
  }

  /// Payload bytes one chunk of a chunked transfer should carry so its wire
  /// time stays a few round trips (3-10 s, three quarters of the lane's
  /// share) instead of a fixed size that took 32 s on a 570 B/s share.
  /// [framingOverhead] is the caller's encoding cost per payload byte
  /// (base64 in a JSON frame ≈ 1.35). Without a known rate: [maxBytes].
  int suggestedPayloadBytes({
    required double framingOverhead,
    int minBytes = 1024,
    int maxBytes = 12 * 1024,
  }) {
    final rate = _rate();
    if (rate == null) return maxBytes;
    final rttMs =
        _srttMs ??
        _positive(transportRttMs?.call())?.toDouble() ??
        retryAfter.inMilliseconds.toDouble();
    final targetMs = (4 * rttMs).clamp(3000.0, 10000.0);
    final wireBudget = rate * targetMs / 1000 * 0.75;
    final payload = wireBudget / (framingOverhead * wireOverhead);
    return payload.round().clamp(minBytes, maxBytes);
  }

  static int? _positive(int? value) =>
      value != null && value > 0 ? value : null;

  int? _rate() {
    final budget = _positive(sendBudgetBytesPerSec?.call());
    if (budget != null) return budget;
    final first = _firstSendMs;
    if (first != null && _acks >= 3) {
      final elapsed = _clock.now().millisecondsSinceEpoch - first;
      if (elapsed >= 2000) {
        final own = _ackedBytes * 1000 ~/ elapsed;
        if (own > 0) return own;
      }
    }
    return null;
  }

  String get _seedSource {
    if (_srttMs != null) return 'sample';
    if (_positive(transportRttMs?.call()) != null) return 'transport';
    return 'floor';
  }

  /// The round-trip term: measured, else seeded from the transport (srtt =
  /// R, rttvar = R/2, so R + 4·R/2 = 3R), else the floor.
  double _rtoBaseMs() {
    final srtt = _srttMs;
    if (srtt != null) return srtt + 4 * _rttvarMs;
    final seed = _positive(transportRttMs?.call());
    if (seed != null) return 3.0 * seed;
    return retryAfter.inMilliseconds.toDouble();
  }

  /// Time for the bytes queued ahead plus this frame to leave at the lane
  /// rate; zero when the rate is unknown.
  double _serializationMs(_Pending p) {
    final rate = _rate();
    if (rate == null) return 0;
    final queued = p.bufferedAtSend ?? 0;
    return (queued + p.frame.length * wireOverhead) / rate * 1000;
  }

  Duration _windowFor(_Pending p) {
    final serialization = _serializationMs(p);
    final base = serialization + _rtoBaseMs();
    final shift = (p.attempts - 1).clamp(0, 6);
    final backedOff = base * (1 << shift);
    final cap = max(maxRetryAfter.inMilliseconds.toDouble(), 3 * serialization);
    final floor = retryAfter.inMilliseconds.toDouble();
    return Duration(milliseconds: backedOff.clamp(floor, cap).round());
  }

  /// Whether the transport has drained the frame's last copy. Unknown
  /// buffers count as drained (the original behavior).
  bool _hasLeftBuffer(_Pending p) {
    final buffered = transportBufferedBytes?.call();
    if (buffered == null) return true;
    return _handed - buffered >= p.handedMark;
  }

  int _liveElapsedMs(_Pending p, int nowMs) {
    var paused = _pausedAccumMs - p.pausedAccumAtSendMs;
    final started = _pauseStartedMs;
    if (_paused && started != null) {
      paused += nowMs - max(started, p.firstSentMs);
    }
    return nowMs - p.firstSentMs - paused;
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

  /// Hands [frame] to the port, marking [p] (if any) with the drained total
  /// its copy must reach before it counts as having left the transport.
  Future<void> _handOver(List<int> frame, {_Pending? p}) {
    _handed += frame.length;
    if (p != null) {
      p.bufferedAtSend = transportBufferedBytes?.call();
      p.handedMark = _handed;
    }
    return _port.send(frame);
  }

  void _fail(_Pending p, int nowMs, String reason) {
    _pending.remove(p.message.id);
    final record = DeliveryFailure(
      messageId: p.message.id,
      attempts: p.attempts,
      elapsedMs: nowMs - p.firstSentMs,
      elapsedLiveMs: _liveElapsedMs(p, nowMs),
      frameBytes: p.frame.length,
      windowsMs: List.unmodifiable(p.windowsMs),
      srttMs: _srttMs,
      rttvarMs: _rttvarMs,
      rateBytesPerSec: _rate(),
      seedSource: _seedSource,
      bufferedAtSend: p.bufferedAtSend,
      bufferedNow: transportBufferedBytes?.call(),
      leftBuffer: _hasLeftBuffer(p),
      reason: reason,
    );
    lastFailure = record;
    _failures.add(record);
    _deliveries.add((p.message.id, DeliveryState.failed));
  }

  /// Sends [text]; returns the created [ChatMessage]. Retransmits happen on
  /// [tick] until an ack arrives, the per-message [deliveryBudget] (default:
  /// the messenger's) elapses on the live clock, or — without a budget —
  /// [maxAttempts] transmissions are exhausted.
  Future<ChatMessage> send(String text, {Duration? deliveryBudget}) async {
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
    final budget = deliveryBudget ?? this.deliveryBudget;
    final p = _Pending(
      msg,
      frame,
      1,
      nowMs,
      deliveryBudgetMs: budget?.inMilliseconds,
      pausedAccumAtSendMs: _pausedAccumMs,
    );
    _firstSendMs ??= nowMs;
    _pending[msg.id] = p;
    await _handOver(frame, p: p);
    return msg;
  }

  /// Retransmits pending messages whose window ([currentRetryAfter] plus the
  /// frame's serialization time, backed off per retransmission) elapsed and
  /// whose last copy has left the transport, and fails those past their
  /// budget (or, without one, at [maxAttempts]). Does nothing while
  /// [isPaused]. Call periodically from the app layer.
  Future<void> tick() async {
    if (_closed) throw StateError('ReliableMessenger is closed');
    if (_paused) return;
    final nowMs = _clock.now().millisecondsSinceEpoch;
    for (final p in _pending.values.toList()) {
      final budget = p.deliveryBudgetMs;
      if (budget != null && _liveElapsedMs(p, nowMs) >= budget) {
        _fail(p, nowMs, 'delivery budget ${budget}ms elapsed on a live path');
        continue;
      }
      final window = _windowFor(p);
      final sinceMs = nowMs - p.lastSentMs;
      if (sinceMs < window.inMilliseconds) continue;
      if (!_hasLeftBuffer(p)) {
        // Still queued in the transport: not lost, so no copy. With a budget
        // the budget decides a transport that never drains; without one, one
        // more window of patience and then the count-based path applies.
        if (budget != null || sinceMs < 2 * window.inMilliseconds) continue;
      }
      if (p.attempts >= maxAttempts) {
        if (budget == null) {
          _fail(p, nowMs, 'attempts exhausted ($maxAttempts copies)');
        }
        continue;
      }
      p.attempts++;
      _duplicateFrames++;
      p.windowsMs.add(window.inMilliseconds);
      p.lastSentMs = nowMs;
      await _handOver(p.frame, p: p);
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
          _acks++;
          _ackedBytes += acked.frame.length;
          if (acked.attempts == 1) {
            final nowMs = _clock.now().millisecondsSinceEpoch;
            // The sample is the path's round trip, not the frame's drain:
            // a large frame's serialization time is removed so the window
            // of the next small frame is not inflated by it.
            final raw =
                nowMs - acked.firstSentMs - _serializationMs(acked).round();
            _sampleRtt(max(1, raw));
          }
          _deliveries.add((id, DeliveryState.delivered));
        }
      case MessageFrame(:final message):
        // Ack every copy so the sender can stop retrying, but surface the
        // message to the app only once.
        await _handOver(WireCodec.encodeAck(message.id));
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
    final nowMs = _clock.now().millisecondsSinceEpoch;
    for (final p in _pending.values.toList()) {
      _fail(p, nowMs, 'messenger closed');
    }
    _pending.clear();
    await _sub.cancel();
    await _incoming.close();
    await _deliveries.close();
    await _failures.close();
    await _port.close();
  }
}
