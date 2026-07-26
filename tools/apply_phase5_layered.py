#!/usr/bin/env python3
"""Phase 5 record: layered delivery, usable content before completion.

Until now a photo was one transfer: nothing was viewable until the whole
pyramid arrived, which on a hostile channel means tens of seconds of
blank screen even though the coarse level is only a few dozen bytes.

sendLayered() enqueues each layer as its own rateless transfer, so the
queue's round-robin carries them concurrently and the receiver can render
the coarse level as soon as it decodes -- while the finer levels are
still in flight. Each layer is framed with its index and the layer count,
so the receiver knows what it has and what is still coming.
"""
import pathlib
import sys

SRC = pathlib.Path(
    "/Users/behnam/Downloads/voice_call_kit_v3/packages/connection_orchestrator"
    "/lib/src/resilient_media_transport.dart"
)

OLD_HEAD = '''class ReceivedMedia {
  ReceivedMedia(this.type, this.bytes);
  final MediaType type;
  final Uint8List bytes;
}'''

NEW_HEAD = '''class ReceivedMedia {
  ReceivedMedia(this.type, this.bytes, {this.layerIndex, this.layerCount});
  final MediaType type;
  final Uint8List bytes;

  /// Set when this payload is one layer of a layered transfer.
  final int? layerIndex;
  final int? layerCount;

  bool get isLayer => layerIndex != null;

  /// True for the coarsest layer, the one worth rendering immediately.
  bool get isFirstLayer => layerIndex == 0;
}'''

OLD_SEND = '''  /// Reassemble one completed transfer on the receiving side.
  static ReceivedMedia receive(RatelessDecoder decoder) {
    final framed = decoder.data;
    final type = MediaType.values[framed[0]];
    final originalLen = ByteData.sublistView(framed).getUint32(1);
    final compressed = Uint8List.sublistView(framed, 5);'''

NEW_SEND = '''  /// Enqueue [layers] as independent transfers, coarsest first.
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
    final compressed = Uint8List.sublistView(framed, 5);'''

text = SRC.read_text(encoding="utf-8")
for old, new in ((OLD_HEAD, NEW_HEAD), (OLD_SEND, NEW_SEND)):
    if old not in text:
        sys.exit(f"anchor not found:\n{old[:70]}")
    text = text.replace(old, new, 1)
SRC.write_text(text, encoding="utf-8")
print(f"patched {SRC.name}")
