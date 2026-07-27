/// Background media transfer queue with strict voice priority.
///
/// Media datagrams are emitted only while the voice path reports
/// silence, and only up to a configured spare-budget cap (bytes/second,
/// intended range 200-500 B/s). The queue never touches the voice send
/// path at all — voice scheduling is decided entirely outside this
/// class, which is what makes the voice-priority guarantee structural
/// rather than best-effort.
///
/// Transfers use the phase-1 rateless code, so an interruption (speech
/// resumes, path drops) costs nothing: resuming just emits more parity
/// datagrams; there is no state to renegotiate with the receiver.
library;

import 'dart:collection';
import 'dart:typed_data';

import 'rateless_stream.dart';

class MediaTransfer {
  MediaTransfer._(this.id, Uint8List data, int blockSize)
    : _encoder = RatelessEncoder(data, blockSize: blockSize);

  final int id;
  final RatelessEncoder _encoder;
  bool _done = false;

  int get blockCount => _encoder.blockCount;
  bool get isMarkedComplete => _done;

  /// Datagrams handed out so far — used to prove round-robin fairness.
  int datagramsSent = 0;

  Uint8List _next() {
    datagramsSent++;
    return _encoder.nextDatagram();
  }
}

/// One datagram plus which transfer produced it. Needed once the queue
/// can interleave multiple transfers within a single tick (round-robin):
/// the receiver must route each datagram to the right decoder instead of
/// assuming (as head-first service allowed) that a whole tick's batch
/// belongs to one transfer.
class TaggedDatagram {
  const TaggedDatagram(this.transferId, this.bytes);
  final int transferId;
  final Uint8List bytes;
}

class MediaTransferQueue {
  MediaTransferQueue({
    this.spareBudgetBytesPerSecond = 300,
    this.blockSize = 48,
  }) : assert(
         spareBudgetBytesPerSecond >= 200 && spareBudgetBytesPerSecond <= 500,
       );

  /// Cap on media wire rate; only ever spent during silence.
  final int spareBudgetBytesPerSecond;
  final int blockSize;

  final Queue<MediaTransfer> _queue = Queue();
  int _nextId = 1;
  int? _lastTickMs;
  double _tokens = 0;
  int _rrCursor = 0;

  /// Bytes emitted per whole second, for diagnostics.
  int bytesEmitted = 0;

  bool get isIdle => _queue.isEmpty;
  MediaTransfer? get active => _queue.isEmpty ? null : _queue.first;

  MediaTransfer enqueue(Uint8List data) {
    final t = MediaTransfer._(_nextId++, data, blockSize);
    _queue.add(t);
    return t;
  }

  /// The sender is zero-feedback, so completion is signalled from
  /// outside (an application-level ack on the return voice channel).
  void markComplete(int id) {
    for (final t in _queue) {
      if (t.id == id) t._done = true;
    }
    while (_queue.isNotEmpty && _queue.first._done) {
      _queue.removeFirst();
    }
  }

  /// Advance the clock and return the media datagrams to put on the
  /// wire now, tagged with the transfer that produced each one. During
  /// speech this is always empty and no budget accrues beyond one
  /// second's worth (the token bucket is capped).
  List<TaggedDatagram> tick({
    required int nowMs,
    required bool voiceIsSpeaking,
  }) {
    final last = _lastTickMs;
    _lastTickMs = nowMs;
    if (last != null && nowMs > last) {
      _tokens += spareBudgetBytesPerSecond * (nowMs - last) / 1000;
      final cap = spareBudgetBytesPerSecond.toDouble();
      if (_tokens > cap) _tokens = cap;
    }
    if (voiceIsSpeaking || _queue.isEmpty) return const [];
    final out = <TaggedDatagram>[];
    final datagramSize = 4 + blockSize + 1;
    // Round-robin across all active (not-yet-marked-done) transfers so
    // concurrent transfers make simultaneous progress instead of the
    // queue draining strictly head-first — a transfer only completes
    // when the receiver acks it out-of-band, so head-first service
    // could starve every transfer behind an unacked one indefinitely.
    // _rrCursor persists ACROSS ticks: when only one datagram's worth of
    // budget accrues per tick (the common case at 200-500 B/s), restarting
    // the scan at index 0 every tick would always favor the earliest
    // transfer and starve the rest — the cursor guarantees fair turns
    // over time instead of only within a single token-rich tick.
    final active = _queue.where((t) => !t._done).toList();
    while (_tokens >= datagramSize && active.isNotEmpty) {
      if (_rrCursor >= active.length) _rrCursor = 0;
      final t = active[_rrCursor];
      out.add(TaggedDatagram(t.id, t._next()));
      _tokens -= datagramSize;
      bytesEmitted += datagramSize;
      _rrCursor++;
    }
    return out;
  }
}
