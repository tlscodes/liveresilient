/// Phase 5 — one facade over the whole media stage: per-type front-end
/// compression -> rateless coding -> background queue with strict voice
/// priority. `send(bytes, type)` on one side, `onReceived` on the other.
///
/// Type routing (lab winners, measured 2026-07-25):
///   document -> LiveContextCompressor (own CM codec, lossless)
///   photo    -> progressive thumbnail pyramid (lossy preview form)
///   audioPcm -> QuantizedLpc front-end + CM (lossless)
///   flipbook -> caller pre-codes frames (FlipbookVideoCompressor) and
///               sends the serialized frame stream as a document payload
///
/// Transfer framing (before rateless coding): u8 type · u32 length ·
/// payload. The transport claim is EXACT delivery of these bytes; lossy
/// codecs upstream never dilute that claim.
library;

import 'dart:typed_data';

import 'media_codecs/live_context_compressor.dart';
import 'media_codecs/media_frontends.dart';
import 'media_queue.dart';
import 'rateless_stream.dart';

enum MediaType { document, photo, audioPcm, flipbook }

class ReceivedMedia {
  ReceivedMedia(this.type, this.bytes, {this.layerIndex, this.layerCount});
  final MediaType type;
  final Uint8List bytes;

  /// Set when this payload is one layer of a layered transfer.
  final int? layerIndex;
  final int? layerCount;

  bool get isLayer => layerIndex != null;

  /// True for the coarsest layer, the one worth rendering immediately.
  bool get isFirstLayer => layerIndex == 0;
}

class ResilientMediaTransport {
  ResilientMediaTransport({MediaTransferQueue? queue})
      : queue = queue ?? MediaTransferQueue();

  final MediaTransferQueue queue;
  static const _cm = LiveContextCompressor();

  /// Compress per type and enqueue. Returns (transfer, compressedSize).
  (MediaTransfer, int) send(Uint8List bytes, MediaType type) {
    final compressed = _compress(bytes, type);
    final framed = Uint8List(5 + compressed.length);
    framed[0] = type.index;
    ByteData.sublistView(framed).setUint32(1, bytes.length);
    framed.setRange(5, framed.length, compressed);
    return (queue.enqueue(framed), compressed.length);
  }

  static Uint8List _compress(Uint8List bytes, MediaType type) {
    switch (type) {
      case MediaType.audioPcm:
        return _cm.compress(QuantizedLpc.encode(bytes));
      case MediaType.document:
      case MediaType.photo:
      case MediaType.flipbook:
        // photo/flipbook arrive pre-coded by their phase-4 codecs; the
        // CM pass here squeezes framing/header redundancy losslessly.
        return _cm.compress(bytes);
    }
  }

  /// Enqueue [layers] as independent transfers, coarsest first.
  ///
  /// Each layer is its own rateless stream, so the queue's round-robin
  /// scheduler advances all of them together and the receiver can use
  /// layer 0 the moment it decodes rather than waiting for the whole
  /// object. Returns one (transfer, compressedSize) record per layer, in
  /// the order given.
  List<(MediaTransfer, int)> sendLayered(
      List<Uint8List> layers, MediaType type) {
    if (layers.isEmpty) throw ArgumentError('no layers to send');
    if (layers.length > 0xFF) {
      throw ArgumentError('at most 255 layers per object');
    }
    final out = <(MediaTransfer, int)>[];
    for (var i = 0; i < layers.length; i++) {
      final compressed = _compress(layers[i], type);
      // u8 type | u32 original length | u8 layer index | u8 layer count
      final framed = Uint8List(7 + compressed.length);
      framed[0] = type.index | _layeredFlag;
      ByteData.sublistView(framed).setUint32(1, layers[i].length);
      framed[5] = i;
      framed[6] = layers.length;
      framed.setRange(7, framed.length, compressed);
      out.add((queue.enqueue(framed), compressed.length));
    }
    return out;
  }

  /// High bit of the type byte marks a layered frame, so a receiver can
  /// tell the two framings apart without a separate channel.
  static const int _layeredFlag = 0x80;

  /// Reassemble one completed transfer on the receiving side.
  static ReceivedMedia receive(RatelessDecoder decoder) {
    final framed = decoder.data;
    final layered = (framed[0] & _layeredFlag) != 0;
    final type = MediaType.values[framed[0] & ~_layeredFlag];
    final originalLen = ByteData.sublistView(framed).getUint32(1);
    if (layered) {
      final compressed = Uint8List.sublistView(framed, 7);
      final bytes = type == MediaType.audioPcm
          ? QuantizedLpc.decode(_cm.decompress(compressed), originalLen)
          : _cm.decompress(compressed);
      return ReceivedMedia(type, bytes,
          layerIndex: framed[5], layerCount: framed[6]);
    }
    final compressed = Uint8List.sublistView(framed, 5);
    switch (type) {
      case MediaType.audioPcm:
        return ReceivedMedia(
            type, QuantizedLpc.decode(_cm.decompress(compressed), originalLen));
      case MediaType.document:
      case MediaType.photo:
      case MediaType.flipbook:
        return ReceivedMedia(type, _cm.decompress(compressed));
    }
  }
}
