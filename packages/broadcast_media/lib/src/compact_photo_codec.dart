import 'dart:typed_data';

/// Phase 5 peak 2 — compact photo wire format.
///
/// A photo travels as one codec payload under a 2-byte micro header:
///   [0] ver (high nibble) | format (low nibble)
///   [1] flags (bit0: grayscale)
///   [2..] the codec bitstream as produced by the encoder (AVIF primary;
///         WebP is the sanctioned, labeled fallback)
/// Encoding itself (resize ladder + quantizer sweep) runs in native encoders;
/// this codec owns layout, format tagging and clean decode failure. Budget
/// enforcement (<= 3072B) lives in gate_2, not here.

const int compactPhotoVersion = 1;
const int compactPhotoHeaderBytes = 2;

enum PhotoWireFormat {
  avif(1),
  webp(2);

  const PhotoWireFormat(this.id);
  final int id;
}

class MalformedPhotoFrame implements Exception {
  final String reason;
  MalformedPhotoFrame(this.reason);
  @override
  String toString() => 'MalformedPhotoFrame($reason)';
}

extension type PhotoWire(Uint8List bytes) {
  int get ver => bytes[0] >> 4;
  int get formatId => bytes[0] & 0x0F;
  bool get grayscale => (bytes[1] & 0x01) != 0;
  Uint8List get payload =>
      Uint8List.sublistView(bytes, compactPhotoHeaderBytes);

  PhotoWireFormat get format => PhotoWireFormat.values.firstWhere(
    (f) => f.id == formatId,
    orElse: () => throw MalformedPhotoFrame('unknown format id $formatId'),
  );

  static PhotoWire checked(Uint8List bytes) {
    if (bytes.length <= compactPhotoHeaderBytes) {
      throw MalformedPhotoFrame('frame too short: ${bytes.length}');
    }
    if (bytes[0] >> 4 != compactPhotoVersion) {
      throw MalformedPhotoFrame('unknown version ${bytes[0] >> 4}');
    }
    return PhotoWire(bytes);
  }
}

PhotoWire encodePhotoWire({
  required Uint8List payload,
  required PhotoWireFormat format,
  required bool grayscale,
}) {
  if (payload.isEmpty) throw MalformedPhotoFrame('empty payload');
  final out = Uint8List(compactPhotoHeaderBytes + payload.length);
  out[0] = (compactPhotoVersion << 4) | format.id;
  out[1] = grayscale ? 0x01 : 0x00;
  out.setRange(compactPhotoHeaderBytes, out.length, payload);
  return PhotoWire(out);
}
