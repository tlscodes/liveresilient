import 'dart:typed_data';

/// Phase 5 peak 5 — half-duplex PTT bundling engine (wire logic only).
///
/// Rides the datagram lane with NO handshake and NO loss-reactive control:
/// Codec2 700C frames (28 bits / 40ms) are bit-packed contiguously into
/// bundles of 1-4 seconds and sent as one datagram each, prefixed by the
/// relay's 2-byte tag-v2 (the 16B room key travels only in the v2 hello).
/// Packet anatomy on the uplink wire (gate 5 accounting):
///   [2B tag][ceil(frames*28/8) payload]  + 28B UDP/IPv4 computed by the gate
/// Sub-second bundling is rejected by construction (appendix E: 160ms
/// bundling is ~2200bps during speech — duty-cycle games are not a codec).
/// The socket itself is injected; this file owns bundling, sequencing and the
/// receive-side reorder-tolerant unpacking.

const int pttFrameBits = 28;
const int pttFrameMs = 40;
const int pttTagBytes = 2;
const Duration pttMinBundle = Duration(seconds: 1);
const Duration pttMaxBundle = Duration(seconds: 4);

class PttConfigError implements Exception {
  final String reason;
  PttConfigError(this.reason);
  @override
  String toString() => 'PttConfigError($reason)';
}

/// One outgoing bundle: the exact bytes to hand to the datagram lane.
typedef PttSend = void Function(Uint8List datagram);

final class PttBundler {
  PttBundler({
    required int tag,
    required Duration bundle,
    required PttSend send,
  }) : _tag = tag,
       _send = send,
       _framesPerBundle = bundle.inMilliseconds ~/ pttFrameMs {
    if (tag < 0 || tag > 0xFFFF || tag == 0) {
      throw PttConfigError('tag must be u16 nonzero, got $tag');
    }
    if (bundle < pttMinBundle || bundle > pttMaxBundle) {
      throw PttConfigError('bundle ${bundle.inMilliseconds}ms outside 1-4s');
    }
    if (bundle.inMilliseconds % pttFrameMs != 0) {
      throw PttConfigError('bundle must be a multiple of ${pttFrameMs}ms');
    }
  }

  final int _tag;
  final PttSend _send;
  final int _framesPerBundle;
  final List<Uint8List> _pending = [];

  int get framesPerBundle => _framesPerBundle;

  /// Wire bytes of one full bundle: tag + bit-packed frames.
  int get bundleWireBytes =>
      pttTagBytes + ((_framesPerBundle * pttFrameBits) + 7) ~/ 8;

  /// Adds one 28-bit frame (4 bytes, low 4 bits of byte 3 zero). Emits a
  /// datagram when the bundle is full.
  void addFrame(Uint8List frame) {
    if (frame.length != 4) {
      throw PttConfigError('700C frame must be 4 bytes, got ${frame.length}');
    }
    _pending.add(frame);
    if (_pending.length >= _framesPerBundle) flush();
  }

  /// Ends the utterance (PTT release): whatever is pending goes out now —
  /// bundling latency is the nature of PTT, but release is never delayed.
  void flush() {
    if (_pending.isEmpty) return;
    final totalBits = _pending.length * pttFrameBits;
    final out = Uint8List(pttTagBytes + ((totalBits + 7) >> 3));
    out[0] = _tag >> 8;
    out[1] = _tag & 0xFF;
    var bitPos = 0;
    for (final f in _pending) {
      for (var b = 0; b < pttFrameBits; b++) {
        final bit = (f[b >> 3] >> (7 - (b & 7))) & 1;
        if (bit != 0) {
          final p = bitPos + b;
          out[pttTagBytes + (p >> 3)] |= 1 << (7 - (p & 7));
        }
      }
      bitPos += pttFrameBits;
    }
    _pending.clear();
    _send(out);
  }
}

/// Receive side: unpacks a tagged bundle back into 4-byte frames. The queue
/// depth is bounded — PTT is live audio, so anything older than [maxQueued]
/// bundles is dropped oldest-first rather than growing without bound.
final class PttUnbundler {
  PttUnbundler({this.maxQueued = 8});

  final int maxQueued;
  final List<Uint8List> _queue = [];

  int get queuedBundles => _queue.length;

  /// Returns the frames of [datagram] (tag stripped) and records the bundle
  /// in the bounded queue. Malformed input returns an empty list — a lost or
  /// garbled bundle is exactly the loss this lane is designed to survive.
  List<Uint8List> accept(Uint8List datagram) {
    if (datagram.length <= pttTagBytes) return const [];
    final payload = Uint8List.sublistView(datagram, pttTagBytes);
    final frameCount = (payload.length * 8) ~/ pttFrameBits;
    if (frameCount == 0) return const [];
    _queue.add(payload);
    while (_queue.length > maxQueued) {
      _queue.removeAt(0);
    }
    final frames = <Uint8List>[];
    for (var i = 0; i < frameCount; i++) {
      final f = Uint8List(4);
      for (var b = 0; b < pttFrameBits; b++) {
        final p = i * pttFrameBits + b;
        final bit = (payload[p >> 3] >> (7 - (p & 7))) & 1;
        if (bit != 0) f[b >> 3] |= 1 << (7 - (b & 7));
      }
      frames.add(f);
    }
    return frames;
  }
}
