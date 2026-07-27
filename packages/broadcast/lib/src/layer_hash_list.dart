/// A flat, signed-by-reference list of chunk hashes for a large layer.
///
/// This replaces a Merkle tree on purpose. A Merkle path only pays for
/// itself when a reader cannot afford the whole hash list; below roughly
/// a thousand chunks the flat list is both smaller and simpler:
///
///     flat list   : n * 32 bytes, fetched once
///     merkle path : n * 32 * ceil(log2 n) bytes, if each chunk carries
///                   its own path
///
/// For a 2 MB layer in 64 KB chunks that is 32 hashes — about a
/// kilobyte, committed by the descriptor's single signature. The tree
/// would cost five times as much and add a second verification path to
/// get wrong.
library;

import 'dart:typed_data';

import 'broadcast_ids.dart';
import 'wire.dart';

/// The only hash-list version this build understands.
const int hashListVersion = 1;

/// Chunk sizes outside this range are refused.
///
/// The floor keeps the 32-byte per-chunk hash overhead under about half
/// a percent. The ceiling keeps a single failed chunk from costing a
/// reader on a bad link more than a moment of work.
const int minChunkSize = 8 * 1024;
const int maxChunkSize = 256 * 1024;

/// Upper bound on chunk count, so a hostile list cannot ask a reader to
/// allocate without limit before any hash has been checked.
const int maxChunkCount = 1 << 16;

/// Why a hash list was refused.
enum HashListRejection {
  malformed,
  unsupportedVersion,
  chunkSizeOutOfRange,
  emptyList,
  tooManyChunks,
  lengthMismatch,
}

/// The verified chunk index for one layer.
class LayerHashList {
  LayerHashList._({
    required this.chunkSize,
    required this.totalLength,
    required this.hashes,
    required this.encoded,
  }) : hash = contentHash(encoded);

  /// Size of every chunk except the last.
  final int chunkSize;

  /// Total length of the reassembled layer.
  final int totalLength;

  /// One hash per chunk, in order.
  final List<Uint8List> hashes;

  /// The exact bytes this was parsed from, or produced as.
  final Uint8List encoded;

  /// Content address of the list itself. This is what a descriptor
  /// commits to via [LayerFlag.mediaList].
  final Uint8List hash;

  int get chunkCount => hashes.length;

  /// Expected byte length of the chunk at [index].
  int chunkLengthAt(int index) {
    if (index < 0 || index >= chunkCount) {
      throw RangeError.index(index, hashes, 'index');
    }
    if (index < chunkCount - 1) return chunkSize;
    final tail = totalLength - chunkSize * (chunkCount - 1);
    return tail;
  }

  /// Whether [bytes] is genuinely the chunk at [index].
  ///
  /// The length is checked first: a wrong-length chunk cannot be the
  /// right one, and rejecting it here avoids hashing attacker-chosen
  /// bulk.
  bool verifyChunk(int index, Uint8List bytes) {
    if (index < 0 || index >= chunkCount) return false;
    if (bytes.length != chunkLengthAt(index)) return false;
    return bytesEqual(contentHash(bytes), hashes[index]);
  }

  /// Split [data] into chunks and index them.
  static LayerHashList build(Uint8List data, {int chunkSize = 64 * 1024}) {
    if (chunkSize < minChunkSize || chunkSize > maxChunkSize) {
      throw ArgumentError.value(
        chunkSize,
        'chunkSize',
        'must be $minChunkSize..$maxChunkSize',
      );
    }
    if (data.isEmpty) {
      throw ArgumentError.value(data, 'data', 'nothing to index');
    }
    final count = (data.length + chunkSize - 1) ~/ chunkSize;
    if (count > maxChunkCount) {
      throw ArgumentError.value(
        count,
        'chunkCount',
        'exceeds $maxChunkCount; raise chunkSize',
      );
    }
    final hashes = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      final start = i * chunkSize;
      final end = start + chunkSize < data.length
          ? start + chunkSize
          : data.length;
      hashes.add(contentHash(Uint8List.sublistView(data, start, end)));
    }
    return LayerHashList._(
      chunkSize: chunkSize,
      totalLength: data.length,
      hashes: List.unmodifiable(hashes),
      encoded: _encode(
        chunkSize: chunkSize,
        totalLength: data.length,
        hashes: hashes,
      ),
    );
  }

  /// Extract the chunk at [index] from a complete [data] buffer.
  ///
  /// Used by a publisher to hand chunks to a store; a reader assembles
  /// from the other direction.
  Uint8List chunkOf(Uint8List data, int index) {
    if (data.length != totalLength) {
      throw ArgumentError.value(
        data.length,
        'data.length',
        'expected $totalLength',
      );
    }
    final start = index * chunkSize;
    return Uint8List.fromList(
      Uint8List.sublistView(data, start, start + chunkLengthAt(index)),
    );
  }

  /// Parse [encoded], rejecting anything internally inconsistent.
  static LayerHashList? parse(
    Uint8List encoded, {
    void Function(HashListRejection reason)? onReject,
  }) {
    void reject(HashListRejection reason) => onReject?.call(reason);
    final reader = WireReader(encoded);
    try {
      final version = reader.u8();
      if (version != hashListVersion) {
        reject(HashListRejection.unsupportedVersion);
        return null;
      }
      final chunkSize = reader.u32();
      final totalLength = reader.u32();
      final count = reader.u32();

      if (chunkSize < minChunkSize || chunkSize > maxChunkSize) {
        reject(HashListRejection.chunkSizeOutOfRange);
        return null;
      }
      if (count == 0 || totalLength == 0) {
        reject(HashListRejection.emptyList);
        return null;
      }
      if (count > maxChunkCount) {
        reject(HashListRejection.tooManyChunks);
        return null;
      }
      // The declared count must be exactly the count the declared length
      // implies, so a list cannot describe a layer that no chunking of
      // that length could produce.
      if ((totalLength + chunkSize - 1) ~/ chunkSize != count) {
        reject(HashListRejection.lengthMismatch);
        return null;
      }
      if (reader.remaining != count * hashBytes) {
        reject(HashListRejection.malformed);
        return null;
      }
      final hashes = <Uint8List>[];
      for (var i = 0; i < count; i++) {
        hashes.add(reader.bytes(hashBytes));
      }
      return LayerHashList._(
        chunkSize: chunkSize,
        totalLength: totalLength,
        hashes: List.unmodifiable(hashes),
        encoded: Uint8List.fromList(encoded),
      );
    } on FormatException {
      reject(HashListRejection.malformed);
      return null;
    }
  }

  static Uint8List _encode({
    required int chunkSize,
    required int totalLength,
    required List<Uint8List> hashes,
  }) {
    final out = WireWriter()
      ..u8(hashListVersion)
      ..u32(chunkSize)
      ..u32(totalLength)
      ..u32(hashes.length);
    for (final hash in hashes) {
      out.bytes(hash);
    }
    return out.take();
  }
}
