/// Self-describing payload framing for broadcast layers.
///
/// A layer's bytes are content-addressed and signed, but nothing in the
/// descriptor says what they *are*. One tag byte and one version byte fix
/// that, so a reader can refuse a payload it cannot decode instead of
/// handing a caption decoder a picture.
library;

import 'dart:typed_data';

/// What a payload holds.
///
/// The values are wire constants — never renumber one.
enum PayloadKind {
  /// UTF-8 text, compressed by the context-mixing document codec.
  text(1),

  /// One progressive image level, coarsest first.
  imageLevel(2),

  /// A block of neural-codec voice tokens, entropy-coded.
  voiceTokens(3),

  /// One flipbook video frame.
  videoFrame(4),

  /// Several payloads packed together, for the optional heavy layer.
  bundle(5);

  const PayloadKind(this.tag);

  final int tag;

  static PayloadKind? fromTag(int tag) {
    for (final kind in PayloadKind.values) {
      if (kind.tag == tag) return kind;
    }
    return null;
  }
}

/// The only payload framing version this build understands.
const int payloadVersion = 1;

/// Upper bound on any single decoded payload, so a hostile length field
/// cannot turn a read into an allocation.
const int maxPayloadBytes = 8 * 1024 * 1024;

/// Most parts one bundle may carry.
const int maxBundleParts = 256;

/// A tagged payload.
class PayloadEnvelope {
  const PayloadEnvelope({required this.kind, required this.body});

  final PayloadKind kind;
  final Uint8List body;

  /// Tag, version, then the body.
  Uint8List encode() {
    final out = Uint8List(2 + body.length)
      ..[0] = kind.tag
      ..[1] = payloadVersion
      ..setRange(2, 2 + body.length, body);
    return out;
  }

  /// Parse [bytes], or null when it is not a payload this build reads.
  static PayloadEnvelope? decode(Uint8List bytes) {
    if (bytes.length < 2) return null;
    final kind = PayloadKind.fromTag(bytes[0]);
    if (kind == null) return null;
    if (bytes[1] != payloadVersion) return null;
    return PayloadEnvelope(
      kind: kind,
      body: Uint8List.fromList(Uint8List.sublistView(bytes, 2)),
    );
  }
}

/// One progressive image level, with the geometry needed to decode it.
///
/// The level's size and coder travel with its bytes rather than being
/// implied by position, because a reader may hold any subset of the
/// levels and must be able to decode what it has without inferring what
/// it does not.
class ImageLevelPayload {
  const ImageLevelPayload({
    required this.width,
    required this.height,
    required this.coderIndex,
    required this.bytes,
  });

  final int width;
  final int height;

  /// Index into the encoder's coder enum, carried as a number so an
  /// unknown coder from a future build is refused rather than guessed.
  final int coderIndex;

  final Uint8List bytes;

  /// `u16 width · u16 height · u8 coder · bytes`
  Uint8List encode() {
    final out = Uint8List(5 + bytes.length);
    ByteData.sublistView(out)
      ..setUint16(0, width)
      ..setUint16(2, height);
    out[4] = coderIndex;
    out.setRange(5, 5 + bytes.length, bytes);
    return out;
  }

  static ImageLevelPayload? decode(Uint8List body) {
    if (body.length < 6) return null;
    final view = ByteData.sublistView(body);
    final width = view.getUint16(0);
    final height = view.getUint16(2);
    if (width == 0 || height == 0) return null;
    return ImageLevelPayload(
      width: width,
      height: height,
      coderIndex: body[4],
      bytes: Uint8List.fromList(Uint8List.sublistView(body, 5)),
    );
  }
}

/// One flipbook frame, with its position and predictor.
class VideoFramePayload {
  const VideoFramePayload({
    required this.index,
    required this.predictorIndex,
    required this.bytes,
  });

  /// Presentation order. Carried explicitly so a bundle that lost its tail
  /// still says which frames these were.
  final int index;

  final int predictorIndex;
  final Uint8List bytes;

  /// `u16 index · u8 predictor · bytes`
  Uint8List encode() {
    final out = Uint8List(3 + bytes.length);
    ByteData.sublistView(out).setUint16(0, index);
    out[2] = predictorIndex;
    out.setRange(3, 3 + bytes.length, bytes);
    return out;
  }

  static VideoFramePayload? decode(Uint8List body) {
    if (body.length < 4) return null;
    return VideoFramePayload(
      index: ByteData.sublistView(body).getUint16(0),
      predictorIndex: body[2],
      bytes: Uint8List.fromList(Uint8List.sublistView(body, 3)),
    );
  }
}

/// Several payloads in one layer.
///
/// The heavy layer carries a sequence — image refinements, then video
/// frames — and a reader that stops early still has everything before the
/// point it stopped. That is the whole reason the parts are ordered
/// coarsest-first rather than by kind.
class PayloadBundle {
  const PayloadBundle(this.parts);

  final List<PayloadEnvelope> parts;

  /// `u8 version · u16 count · [u32 length · bytes] *`
  Uint8List encode() {
    if (parts.length > maxBundleParts) {
      throw ArgumentError.value(
        parts.length,
        'parts.length',
        'at most $maxBundleParts',
      );
    }
    final encoded = [for (final part in parts) part.encode()];
    var total = 3;
    for (final part in encoded) {
      total += 4 + part.length;
    }
    final out = Uint8List(total);
    final view = ByteData.sublistView(out);
    out[0] = payloadVersion;
    view.setUint16(1, parts.length);
    var offset = 3;
    for (final part in encoded) {
      view.setUint32(offset, part.length);
      offset += 4;
      out.setRange(offset, offset + part.length, part);
      offset += part.length;
    }
    return out;
  }

  /// Parse a bundle, refusing anything internally inconsistent.
  ///
  /// A truncated bundle is refused outright rather than decoded up to the
  /// break. Partial delivery is the transport's job and it already
  /// verifies whole layers by hash; a half-parsed bundle here would only
  /// be a second, weaker version of that.
  static PayloadBundle? decode(Uint8List bytes) {
    if (bytes.length < 3) return null;
    if (bytes[0] != payloadVersion) return null;
    final view = ByteData.sublistView(bytes);
    final count = view.getUint16(1);
    if (count > maxBundleParts) return null;
    final parts = <PayloadEnvelope>[];
    var offset = 3;
    for (var i = 0; i < count; i++) {
      if (offset + 4 > bytes.length) return null;
      final length = view.getUint32(offset);
      offset += 4;
      if (length > maxPayloadBytes) return null;
      if (offset + length > bytes.length) return null;
      final part = PayloadEnvelope.decode(
        Uint8List.fromList(
          Uint8List.sublistView(bytes, offset, offset + length),
        ),
      );
      if (part == null) return null;
      parts.add(part);
      offset += length;
    }
    if (offset != bytes.length) return null;
    return PayloadBundle(parts);
  }
}
