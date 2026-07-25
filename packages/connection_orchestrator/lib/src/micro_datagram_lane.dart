/// Micro-datagram lane: carries token-voice blocks across a path that
/// only passes very small, unreliable datagrams with multi-second delay.
///
/// The environment this is designed for (measured, not hypothetical):
/// throughput of a few hundred bytes per second, packet loss of 70-95%,
/// one-way delay of 3-5 seconds, and an effective MTU of only tens of
/// bytes. Three consequences drive the design:
///
/// - **No round trips.** With multi-second delay, any ack/retransmit
///   scheme is far slower than speech. Everything is send-only.
/// - **Sliding-window redundancy, not repetition.** Each datagram
///   carries the newest block PLUS the previous [windowBlocks] blocks.
///   A block therefore rides many independent datagrams spread over
///   time, so P(block lost) = loss^(number of datagrams carrying it),
///   which collapses to near zero even at 95% loss — and unlike naive
///   copy-repetition, the redundancy is amortized across blocks instead
///   of multiplying the byte rate per block.
/// - **Independent blocks.** Each block is coded against a frozen warm
///   dictionary snapshot, so a lost block never breaks the next one
///   (there is no ack channel to resynchronize a chain).
///
/// Wire format per datagram:
///   u16 newestSeq · u8 count · then `count` records of
///   [u8 length][payload], newest first.
library;

import 'dart:typed_data';

/// Builds datagrams that each carry the newest block plus recent ones.
class SlidingWindowPacker {
  SlidingWindowPacker({this.maxDatagramBytes = 60, this.windowBlocks = 8})
      : assert(maxDatagramBytes > 8),
        assert(windowBlocks >= 1);

  /// Total datagram size cap, header included.
  final int maxDatagramBytes;

  /// How many recent blocks each datagram tries to carry.
  final int windowBlocks;

  final List<(int, Uint8List)> _recent = [];

  /// Adds a freshly coded block and returns the datagram to send now.
  /// Blocks larger than the datagram budget are rejected — the caller
  /// must shrink the block (fewer frames) rather than fragment, since a
  /// fragmented block needs every piece and cannot exploit the window.
  Uint8List addBlock(int seq, Uint8List blockBytes) {
    if (blockBytes.length + 4 > maxDatagramBytes) {
      throw ArgumentError('block of ${blockBytes.length} B exceeds the '
          '$maxDatagramBytes B datagram budget — use fewer frames');
    }
    _recent.insert(0, (seq, blockBytes));
    if (_recent.length > windowBlocks) _recent.removeLast();

    final out = BytesBuilder()
      ..addByte(seq & 0xFF)
      ..addByte((seq >> 8) & 0xFF);
    final countAt = out.length;
    out.addByte(0);
    var count = 0;
    var used = 3;
    for (final (_, bytes) in _recent) {
      if (used + 1 + bytes.length > maxDatagramBytes) break;
      out
        ..addByte(bytes.length)
        ..add(bytes);
      used += 1 + bytes.length;
      count++;
    }
    final bytes = out.takeBytes();
    bytes[countAt] = count;
    return bytes;
  }
}

/// Unpacks datagrams, yielding each block the first time it is seen.
class SlidingWindowUnpacker {
  final Set<int> _seen = {};

  /// Datagrams accepted (survivors of the path).
  int accepted = 0;

  /// Feed one surviving datagram; returns the blocks recovered from it
  /// that had not been seen before, oldest first.
  List<(int, Uint8List)> offer(Uint8List datagram) {
    if (datagram.length < 3) return const [];
    accepted++;
    final newest = datagram[0] | (datagram[1] << 8);
    final count = datagram[2];
    var at = 3;
    final found = <(int, Uint8List)>[];
    for (var i = 0; i < count; i++) {
      if (at >= datagram.length) break;
      final len = datagram[at];
      at += 1;
      if (at + len > datagram.length) break;
      final seq = newest - i;
      if (seq >= 0 && _seen.add(seq)) {
        found.add((seq, Uint8List.sublistView(datagram, at, at + len)));
      }
      at += len;
    }
    return found.reversed.toList();
  }
}
