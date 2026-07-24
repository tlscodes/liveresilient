/// Weak-link efficiency codec: three composable stages that make every
/// byte count on a 2G-grade or high-loss path.
///
///  1. Coalescing — many small messages ride one frame (fewer headers,
///     fewer radio wakeups).
///  2. Compression — zlib/deflate when it actually shrinks the payload
///     (a 1-byte flag records the choice; incompressible data ships raw).
///  3. Parity — per group of k data chunks, one XOR parity chunk lets
///     the receiver rebuild ANY single lost chunk without a round-trip
///     (the round-trip is exactly what a weak link cannot afford).
library;

import 'dart:io';
import 'dart:typed_data';

/// Stage 1 — frame many small messages as one payload and back.
class MessageCoalescer {
  /// Frame layout: [count varint32][len varint32, bytes]* — simple,
  /// bounded, endian-free.
  static List<int> pack(List<List<int>> messages) {
    final out = BytesBuilder();
    _writeVarint(out, messages.length);
    for (final m in messages) {
      _writeVarint(out, m.length);
      out.add(m);
    }
    return out.takeBytes();
  }

  static List<List<int>>? unpack(List<int> frame) {
    final data = Uint8List.fromList(frame);
    var offset = 0;
    int? readVarint() {
      var value = 0, shift = 0;
      while (offset < data.length) {
        final b = data[offset++];
        value |= (b & 0x7f) << shift;
        if (b & 0x80 == 0) return value;
        shift += 7;
        if (shift > 28) return null;
      }
      return null;
    }

    final count = readVarint();
    if (count == null || count < 0) return null;
    final messages = <List<int>>[];
    for (var i = 0; i < count; i++) {
      final len = readVarint();
      if (len == null || offset + len > data.length) return null;
      messages.add(data.sublist(offset, offset + len));
      offset += len;
    }
    return messages;
  }

  static void _writeVarint(BytesBuilder out, int value) {
    var v = value;
    while (v >= 0x80) {
      out.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    out.addByte(v);
  }
}

/// Stage 2 — compress only when it pays. First byte: 0 raw, 1 deflate.
class WeakLinkCompressor {
  static const int _raw = 0;
  static const int _deflate = 1;

  static List<int> encode(List<int> payload) {
    final compressed = zlib.encode(payload);
    if (compressed.length + 1 < payload.length) {
      return [_deflate, ...compressed];
    }
    return [_raw, ...payload];
  }

  static List<int>? decode(List<int> framed) {
    if (framed.isEmpty) return null;
    final body = framed.sublist(1);
    switch (framed.first) {
      case _raw:
        return body;
      case _deflate:
        try {
          return zlib.decode(body);
        } on FormatException {
          return null;
        }
      default:
        return null;
    }
  }
}

/// Stage 3 — XOR parity over groups of [groupSize] equal-length chunks.
class ParityGroup {
  const ParityGroup({this.groupSize = 4});

  /// Data chunks per parity chunk. Overhead = 1/groupSize.
  final int groupSize;

  /// Returns the parity chunk for up-to-[groupSize] data chunks, padded
  /// to the longest chunk's length.
  List<int> parityOf(List<List<int>> chunks) {
    final len = chunks.fold(0, (a, c) => c.length > a ? c.length : a);
    final parity = List<int>.filled(len, 0);
    for (final c in chunks) {
      for (var i = 0; i < c.length; i++) {
        parity[i] ^= c[i];
      }
    }
    return parity;
  }

  /// Rebuilds the single missing chunk of a group from the survivors and
  /// the parity chunk. [presentChunks] excludes the lost one. Returns the
  /// recovered bytes trimmed to [lostLength].
  List<int> recover(
    List<List<int>> presentChunks,
    List<int> parity, {
    required int lostLength,
  }) {
    final rebuilt = List<int>.from(parity);
    for (final c in presentChunks) {
      for (var i = 0; i < c.length; i++) {
        rebuilt[i] ^= c[i];
      }
    }
    return rebuilt.sublist(0, lostLength);
  }
}
