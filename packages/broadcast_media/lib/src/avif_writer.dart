/// A minimal AVIF (ISOBMFF) writer: one AV1 keyframe becomes a file both
/// receivers already open — ffmpeg and Preview on the Mac, dav1d on the
/// phone (av1_decoder.dart's avifMdatPayload reads it back).
///
/// Why the photo letter needs it (measured 2026-09-23 on the real phone
/// photo 402504ee, 591x1280, scored against itself with ffmpeg's ssim):
///   JPEG 113532 B -> 0.9727      AVIF 113926 B -> 0.9826
///                                AVIF  92638 B -> 0.9759
/// so AV1 carries the same picture in about a quarter fewer bytes, and the
/// freed bytes buy a larger edge in the picker's ladder. The video letter
/// already proved the encoder on the phone (av1_encoder.dart).
///
/// Only what a still needs is written: ftyp, meta (hdlr, pitm, iloc, iinf,
/// iprp with av1C/ispe/pixi, ipma) and mdat. No alpha, no exif, no
/// transform boxes — the picker bakes rotation before it encodes.
library;

import 'dart:typed_data';

Uint8List _box(String type, List<int> body) {
  final out = BytesBuilder(copy: false);
  final size = 8 + body.length;
  out.add([
    (size >> 24) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
  ]);
  out.add(type.codeUnits);
  out.add(body);
  return out.takeBytes();
}

Uint8List _fullBox(String type, int version, int flags, List<int> body) =>
    _box(type, [
      version & 0xFF,
      (flags >> 16) & 0xFF,
      (flags >> 8) & 0xFF,
      flags & 0xFF,
      ...body,
    ]);

List<int> _u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];
List<int> _u32(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

/// The av1C configuration record for an 8-bit 4:2:0 Main-profile stream,
/// with the sequence header carried inside the OBU stream itself
/// (initial_presentation_delay absent, configOBUs empty) — dav1d and
/// libavif both accept that shape.
Uint8List _av1C({int profile = 0, int level = 8, bool monochrome = false}) =>
    _box('av1C', [
      0x81, // marker 1, version 1
      ((profile & 0x07) << 5) | (level & 0x1F),
      // tier 0, high_bitdepth 0, twelve_bit 0, monochrome, 4:2:0 (subsampling
      // x and y set), chroma_sample_position unknown
      (monochrome ? 0x10 : 0x00) | 0x0C,
      0x00, // no initial presentation delay
    ]);

/// Wraps one AV1 keyframe [obu] as an AVIF still of [width] x [height].
Uint8List wrapAvif(
  Uint8List obu, {
  required int width,
  required int height,
  bool monochrome = false,
}) {
  if (obu.isEmpty) throw ArgumentError('empty AV1 payload');
  const itemId = 1;
  final ftyp = _box('ftyp', [
    ...'avif'.codeUnits,
    ..._u32(0),
    ...'avif'.codeUnits,
    ...'mif1'.codeUnits,
    ...'miaf'.codeUnits,
    ...'MA1B'.codeUnits,
  ]);
  final hdlr = _fullBox('hdlr', 0, 0, [
    ..._u32(0),
    ...'pict'.codeUnits,
    ..._u32(0),
    ..._u32(0),
    ..._u32(0),
    0, // an empty name
  ]);
  final pitm = _fullBox('pitm', 0, 0, _u16(itemId));
  final iinf = _fullBox('iinf', 0, 0, [
    ..._u16(1),
    ..._fullBox('infe', 2, 0, [
      ..._u16(itemId),
      ..._u16(0),
      ...'av01'.codeUnits,
      0, // an empty item name
    ]),
  ]);
  final ipco = _box('ipco', [
    ..._av1C(monochrome: monochrome),
    ..._fullBox('ispe', 0, 0, [..._u32(width), ..._u32(height)]),
    ..._box('pixi', [0, 0, 0, 0, 3, 8, 8, 8]),
  ]);
  final ipma = _fullBox('ipma', 0, 0, [
    ..._u32(1),
    ..._u16(itemId),
    3, // three associations
    0x81, // property 1 (av1C), essential
    0x02, // property 2 (ispe)
    0x03, // property 3 (pixi)
  ]);
  final iprp = _box('iprp', [...ipco, ...ipma]);

  // iloc carries the absolute file offset of the payload, so the meta box
  // is built twice: once to learn its length, once with the real offset.
  Uint8List metaWith(int offset) {
    final iloc = _fullBox('iloc', 0, 0, [
      0x44, // offset_size 4, length_size 4
      0x00, // base_offset_size 0, index_size 0
      ..._u16(1),
      ..._u16(itemId),
      ..._u16(0), // data reference index
      ..._u16(1), // one extent
      ..._u32(offset),
      ..._u32(obu.length),
    ]);
    return _fullBox('meta', 0, 0, [
      ...hdlr,
      ...pitm,
      ...iloc,
      ...iinf,
      ...iprp,
    ]);
  }

  final metaLength = metaWith(0).length;
  final payloadOffset = ftyp.length + metaLength + 8; // + the mdat header
  final out = BytesBuilder(copy: false)
    ..add(ftyp)
    ..add(metaWith(payloadOffset))
    ..add(_box('mdat', obu));
  return out.takeBytes();
}

/// True when [bytes] begin with an AVIF file's `ftypavif` brand.
bool isAvif(Uint8List bytes) =>
    bytes.length > 12 &&
    bytes[4] == 0x66 &&
    bytes[5] == 0x74 &&
    bytes[6] == 0x79 &&
    bytes[7] == 0x70 &&
    bytes[8] == 0x61 &&
    bytes[9] == 0x76 &&
    bytes[10] == 0x69 &&
    bytes[11] == 0x66;
