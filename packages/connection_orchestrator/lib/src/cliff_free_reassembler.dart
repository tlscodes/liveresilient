/// Order-free reassembly of a layered object carried as independent RLNC
/// streams — one decoder per layer, datagrams absorbed in ANY order across
/// layers, and no layer ever needs another layer to decode.
///
/// Two counts are exposed on purpose:
/// - [decodedLayerCount]: layers whose generation reached full rank, in any
///   position. Pure decode progress.
/// - [usableLayerCount]: the longest decoded PREFIX starting at L0 — what a
///   renderer may actually show, since an embedded refinement layer is only
///   meaningful on top of the layers below it. Decoding is order-free;
///   RENDERING is inherently prefix-shaped. Keeping the two numbers separate
///   is what stops the reassembler from silently requiring in-order layers.
library;

import 'dart:typed_data';

import 'gf256_rlnc_stream.dart';

class CliffFreeReassembler {
  CliffFreeReassembler({required this.layerCount}) {
    if (layerCount <= 0) {
      throw ArgumentError.value(layerCount, 'layerCount', 'must be >= 1');
    }
  }

  final int layerCount;
  final Map<int, RlncDecoder> _decoders = {};
  final Map<int, Uint8List> _decoded = {};

  /// Absorbs one wire datagram belonging to [layerIndex] (on the real
  /// transport seam the index comes from `TaggedDatagram.transferId` — each
  /// layer of a `sendLayered` call is its own transfer).
  ///
  /// Returns true when this datagram completed its layer. Datagrams for an
  /// already-decoded layer are ignored (rateless duplicates cost nothing).
  bool addDatagram(int layerIndex, Uint8List datagram) {
    if (layerIndex < 0 || layerIndex >= layerCount) {
      throw RangeError.range(layerIndex, 0, layerCount - 1, 'layerIndex');
    }
    if (_decoded.containsKey(layerIndex)) return false;
    final dec = _decoders.putIfAbsent(layerIndex, RlncDecoder.new);
    dec.addDatagram(datagram);
    if (dec.isComplete) {
      _decoded[layerIndex] = dec.data;
      _decoders.remove(layerIndex); // free the elimination matrices
      return true;
    }
    return false;
  }

  bool isLayerDecoded(int layerIndex) => _decoded.containsKey(layerIndex);

  /// Layers decoded so far, regardless of position.
  int get decodedLayerCount => _decoded.length;

  /// Longest decoded prefix from L0 — the renderable quality step.
  int get usableLayerCount {
    var n = 0;
    while (n < layerCount && _decoded.containsKey(n)) {
      n++;
    }
    return n;
  }

  bool get isComplete => _decoded.length == layerCount;

  /// Exact bytes of a decoded layer.
  Uint8List layerData(int layerIndex) {
    final d = _decoded[layerIndex];
    if (d == null) {
      throw StateError('layer $layerIndex is not decoded yet');
    }
    return d;
  }

  /// The renderable object so far: concatenation of the usable prefix.
  Uint8List usableBytes() {
    final b = BytesBuilder(copy: false);
    for (var i = 0; i < usableLayerCount; i++) {
      b.add(_decoded[i]!);
    }
    return b.toBytes();
  }
}
