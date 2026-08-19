import 'dart:typed_data';

/// Phase 5 peak 1 — compact text wire format.
///
/// Wire layout (4-byte micro header, then body):
///   [0] ver (high nibble) | flags (low nibble); flag bit0 = body compressed
///   [1..2] msgId, little-endian u16
///   [3] dictVer — 1-byte dictionary version id (appendix C: the version id
///       travels in the schema, never a hash in the header)
///   [4..] body: zstd-with-dictionary compressed UTF-8, or raw UTF-8 when
///       compression does not shrink this particular message
///
/// Compression itself is injected: on host benches it is the zstd CLI, on
/// device it will be the zstd FFI binding. The codec owns layout and the
/// smaller-of-two rule, not the compressor.
/// The message buffer itself is an allocation; the extension type only avoids
/// a wrapper object.

const int compactTextVersion = 1;
const int _flagCompressed = 0x01;
const int compactTextHeaderBytes = 4;

typedef Compressor = Uint8List Function(Uint8List raw);
typedef Decompressor = Uint8List Function(Uint8List body);

/// Thrown when a frame's dictionary version does not match the dictionary the
/// receiver holds — the mandated CLEAN failure (never garbage output).
class DictVersionMismatch implements Exception {
  final int frameDictVer;
  final int localDictVer;
  DictVersionMismatch(this.frameDictVer, this.localDictVer);
  @override
  String toString() =>
      'DictVersionMismatch(frame=$frameDictVer local=$localDictVer)';
}

class MalformedTextFrame implements Exception {
  final String reason;
  MalformedTextFrame(this.reason);
  @override
  String toString() => 'MalformedTextFrame($reason)';
}

/// Zero-wrapper view over an encoded frame.
extension type CompactTextFrame(Uint8List bytes) {
  int get ver => bytes[0] >> 4;
  int get flags => bytes[0] & 0x0F;
  bool get compressed => (flags & _flagCompressed) != 0;
  int get msgId => bytes[1] | (bytes[2] << 8);
  int get dictVer => bytes[3];
  Uint8List get body => Uint8List.sublistView(bytes, compactTextHeaderBytes);

  static CompactTextFrame checked(Uint8List bytes) {
    if (bytes.length < compactTextHeaderBytes) {
      throw MalformedTextFrame('frame shorter than header: ${bytes.length}');
    }
    if (bytes[0] >> 4 != compactTextVersion) {
      throw MalformedTextFrame('unknown version ${bytes[0] >> 4}');
    }
    return CompactTextFrame(bytes);
  }
}

/// Encodes [utf8Text] into a frame, keeping whichever body is smaller:
/// the compressor's output or the raw bytes.
CompactTextFrame encodeCompactText({
  required Uint8List utf8Text,
  required int msgId,
  required int dictVer,
  required Compressor compress,
}) {
  if (msgId < 0 || msgId > 0xFFFF) {
    throw ArgumentError.value(msgId, 'msgId', 'must fit u16');
  }
  if (dictVer < 0 || dictVer > 0xFF) {
    throw ArgumentError.value(dictVer, 'dictVer', 'must fit u8');
  }
  final compressed = compress(utf8Text);
  final useCompressed = compressed.length < utf8Text.length;
  final body = useCompressed ? compressed : utf8Text;
  final out = Uint8List(compactTextHeaderBytes + body.length);
  out[0] = (compactTextVersion << 4) | (useCompressed ? _flagCompressed : 0);
  out[1] = msgId & 0xFF;
  out[2] = (msgId >> 8) & 0xFF;
  out[3] = dictVer;
  out.setRange(compactTextHeaderBytes, out.length, body);
  return CompactTextFrame(out);
}

/// Decodes a frame back to UTF-8 bytes. A dictionary version mismatch fails
/// cleanly with [DictVersionMismatch] BEFORE any decompression is attempted.
Uint8List decodeCompactText({
  required CompactTextFrame frame,
  required int localDictVer,
  required Decompressor decompress,
}) {
  final f = CompactTextFrame.checked(frame.bytes);
  if (f.compressed && f.dictVer != localDictVer) {
    throw DictVersionMismatch(f.dictVer, localDictVer);
  }
  return f.compressed ? decompress(f.body) : f.body;
}
