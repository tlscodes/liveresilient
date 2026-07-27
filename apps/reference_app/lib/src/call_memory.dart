/// Call memory — the third operating rung: the last seconds of outgoing
/// audio before a drop are kept in a bounded ring buffer and, after the
/// reconnect lands, replayed to the peer over the call's own reliable
/// data channel — so the sentence that was cut mid-word arrives anyway.
///
/// Frame capture is a SEAM ([AudioFrameTap]): the platform layer taps
/// encoded outgoing audio frames wherever it can (recorder callback,
/// insertable stream); tests inject synthetic frames. This class holds no
/// platform code — only the bounded buffering, the drop/replay state
/// machine, and the wire format (one attachment per gap, `audio/replay`).
library;

import 'dart:async';

import 'package:call_core/call_core.dart';
import 'package:messaging/messaging.dart';

/// Pushes encoded outgoing audio frames into [onFrame]; returns a stop
/// callback. Production wires the platform tap; tests push synthetic
/// frames.
typedef AudioFrameTap =
    void Function() Function(void Function(List<int> frame) onFrame);

/// Bounded FIFO of the most recent audio frames (byte-budgeted, not
/// count-budgeted, so variable-size encoded frames cannot blow the cap).
class AudioRingBuffer {
  AudioRingBuffer({this.maxBytes = 256 * 1024}) {
    if (maxBytes <= 0) throw ArgumentError.value(maxBytes, 'maxBytes');
  }

  final int maxBytes;
  final _frames = <List<int>>[];
  int _bytes = 0;

  int get sizeBytes => _bytes;
  bool get isEmpty => _frames.isEmpty;

  void add(List<int> frame) {
    if (frame.isEmpty || frame.length > maxBytes) return;
    _frames.add(frame);
    _bytes += frame.length;
    while (_bytes > maxBytes) {
      _bytes -= _frames.removeAt(0).length;
    }
  }

  /// Drains every buffered frame, oldest first, concatenated.
  List<int> drain() {
    final out = <int>[for (final f in _frames) ...f];
    _frames.clear();
    _bytes = 0;
    return out;
  }

  void clear() {
    _frames.clear();
    _bytes = 0;
  }
}

/// Watches the call lifecycle: buffers outgoing audio continuously while
/// the call is live; when a reconnect episode interrupts it, freezes the
/// buffered tail; when the call reconnects, ships that tail as ONE
/// reliable attachment (`audio/replay`) the peer can play back.
class CallMemory {
  CallMemory({
    required Stream<CallState> states,
    required this.messenger,
    AudioFrameTap? tap,
    int maxBytes = 256 * 1024,
  }) : _buffer = AudioRingBuffer(maxBytes: maxBytes) {
    _stateSub = states.listen(_onState);
    _stopTap = tap?.call(_buffer.add);
  }

  /// Built lazily over the call's data channel (same seam as the
  /// degraded-mode driver's voice notes).
  final Future<ReliableMessenger> Function() messenger;

  final AudioRingBuffer _buffer;
  late final StreamSubscription<CallState> _stateSub;
  void Function()? _stopTap;

  List<int>? _frozenTail;
  bool _disposed = false;
  int _replaysSent = 0;

  /// Completed gap replays shipped to the peer (for UI badges and tests).
  int get replaysSent => _replaysSent;

  void _onState(CallState state) {
    if (_disposed) return;
    switch (state) {
      case ReconnectingCallState():
        // The drop edge: freeze what the peer most likely lost. Keep only
        // the FIRST freeze of an episode chain — later attempts of the
        // same outage must not overwrite the tail with silence.
        _frozenTail ??= _buffer.drain();
      case ConnectedCallState() || DegradedCallState():
        final tail = _frozenTail;
        _frozenTail = null;
        if (tail != null && tail.isNotEmpty) {
          unawaited(_shipReplay(tail));
        }
      case IdleCallState() ||
          ConnectingCallState() ||
          NegotiatingCallState() ||
          EndingCallState() ||
          EndedCallState() ||
          FailedCallState():
        _buffer.clear();
        _frozenTail = null;
    }
  }

  Future<void> _shipReplay(List<int> tail) async {
    try {
      await sendAttachment(
        await messenger(),
        Attachment(
          id: 'gap-replay-$_replaysSent',
          kind: MediaKind.file,
          contentType: 'audio/replay',
          bytes: tail,
        ),
      );
      _replaysSent++;
    } catch (_) {
      // A failed replay is not worth failing anything else over; the
      // conversation has already moved on.
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _stopTap?.call();
    _stopTap = null;
    _buffer.clear();
    await _stateSub.cancel();
  }
}
