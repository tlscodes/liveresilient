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
  ReceivedMedia(this.type, this.bytes);
  final MediaType type;
  final Uint8List bytes;
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

  /// Reassemble one completed transfer on the receiving side.
  static ReceivedMedia receive(RatelessDecoder decoder) {
    final framed = decoder.data;
    final type = MediaType.values[framed[0]];
    final originalLen = ByteData.sublistView(framed).getUint32(1);
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
