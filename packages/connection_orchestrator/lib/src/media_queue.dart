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

  Uint8List _next() => _encoder.nextDatagram();
}

class MediaTransferQueue {
  MediaTransferQueue({
    this.spareBudgetBytesPerSecond = 300,
    this.blockSize = 48,
  }) : assert(spareBudgetBytesPerSecond >= 200 &&
            spareBudgetBytesPerSecond <= 500);

  /// Cap on media wire rate; only ever spent during silence.
  final int spareBudgetBytesPerSecond;
  final int blockSize;

  final Queue<MediaTransfer> _queue = Queue();
  int _nextId = 1;
  int? _lastTickMs;
  double _tokens = 0;

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
  /// wire now. During speech this is always empty and no budget
  /// accrues beyond one second's worth (the token bucket is capped).
  List<Uint8List> tick({required int nowMs, required bool voiceIsSpeaking}) {
    final last = _lastTickMs;
    _lastTickMs = nowMs;
    if (last != null && nowMs > last) {
      _tokens += spareBudgetBytesPerSecond * (nowMs - last) / 1000;
      final cap = spareBudgetBytesPerSecond.toDouble();
      if (_tokens > cap) _tokens = cap;
    }
    if (voiceIsSpeaking || _queue.isEmpty) return const [];
    final out = <Uint8List>[];
    final datagramSize = 4 + blockSize + 1;
    while (_tokens >= datagramSize && _queue.isNotEmpty) {
      out.add(_queue.first._next());
      _tokens -= datagramSize;
      bytesEmitted += datagramSize;
    }
    return out;
  }
}
