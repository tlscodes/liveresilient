/// Packet-size targets for the shaping layer — the Dart twin of the engine's
/// `SizeTargets` (engine/crates/shaping/src/lib.rs:27-61).
///
/// The distribution here MUST match the one the reference profile is built
/// from; if the two drift apart the shaped histogram converges to the wrong
/// shape and the leak metric silently stops meaning anything. That is why the
/// draw sequence is pinned to a cross-language vector rather than merely
/// re-derived from the same description.
///
/// HONEST COST NOTE, stated where the code is rather than in a report: padding
/// only ever grows a datagram, and these targets are drawn from a web-like
/// distribution whose small mode alone is 40-160 bytes. A voice frame is far
/// smaller, so shaping multiplies the byte rate. Whether that fits the media
/// budget is a measurement, not an assumption — see the shaping cost harness.
library;

import 'dart:typed_data';

import 'seed_stream.dart';

/// Logical path of the shaping substream, matching the engine's.
const String shapingTargetsPath = 'shaping/pad/targets/v1';

class SizeTargets {
  /// Seeds the target stream from the manifest genealogy.
  SizeTargets({
    required int rootSeed,
    required Uint8List manifestHash,
    String logicalPath = shapingTargetsPath,
  }) : _stream = SeedStream.forPath(
         rootSeed: rootSeed,
         manifestHash: manifestHash,
         logicalPath: logicalPath,
       );

  /// Seeds from an already-built stream. Used by tests that pin the sequence.
  SizeTargets.fromStream(this._stream);

  final SeedStream _stream;

  /// Next target size in bytes, from the same 70/30 small/large web mix the
  /// engine uses. Deterministic given the seed and the call order.
  int nextTarget() {
    if (_stream.nextBelow(10) < 7) {
      return 40 + _stream.nextBelow(120); // 40..159
    }
    return 200 + _stream.nextBelow(1200); // 200..1399
  }
}

/// Pads [datagram] up to [targetLength] by appending zero bytes.
///
/// Padding never shrinks: a target below the real length returns the datagram
/// unchanged, so an oversized payload still shows its true size. The receiver
/// recovers the real payload from the frame length prefix, so the padding is
/// transparent to decoding.
Uint8List padTo(List<int> datagram, int targetLength) {
  final length = targetLength > datagram.length
      ? targetLength
      : datagram.length;
  final out = Uint8List(length);
  out.setRange(0, datagram.length, datagram);
  return out;
}
