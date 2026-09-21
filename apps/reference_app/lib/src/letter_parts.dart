// A letter larger than the door's cap, as up to ten letters in a row over
// the same lane. The cap itself (TxtQueryLane.maxPayloadBytes = 4096) is
// untouched: each part is one ordinary letter under it, and a receiver that
// does not know parts still gets ordinary letters.
//
// Part wire (29 B header, then the slice):
//   [0..1]   'L' 'P'              magic
//   [2]      version = 1
//   [3]      flags = 0
//   [4..7]   id, 4 bytes, the same on every part of one letter
//   [8]      index, 0-based
//   [9]      total, 1..10
//   [10..12] total length of the whole payload, big-endian u24
//   [13..28] sha256 of the whole payload, first 16 bytes
//   [29..]   the slice
//
// A payload that fits in one letter is sent bare, exactly as today; the
// magic decides on receipt. The Python mirror is tools/t2/letter_parts.py;
// tools/t2/goldens/letter_parts_10.bin pins the two to the same bytes.
import 'dart:math';
import 'dart:typed_data';

import 'package:messaging/messaging.dart' show contentSha256Hex;

const List<int> _magic = <int>[0x4C, 0x50]; // 'L' 'P'
const int letterPartVersion = 1;
const int letterPartHeaderBytes = 29;

/// The most parts one letter may have. Ten, then thirty (2026-09-21),
/// then SIXTY on 2026-09-22 for the video letter: the owner spends
/// letters on quality, never on seconds, and a talking face at 144x256
/// was judged a thumbnail — 216x384 needs ~2.25x the bytes at the same
/// bits per pixel. Measured 4.0 s per letter on the rig: 30 ≈ 120 s,
/// 45 ≈ 180 s, 60 ≈ 240 s. The photo keeps its own thirty-letter budget
/// (photo_letter_picker.dart) so a picture never becomes a four-minute
/// letter. The cap per letter and the one-byte index/total are untouched.
const int letterMaxParts = 60;

/// The door's cap, restated here only as a default; callers pass the lane's.
const int letterPartMaxBytes = 4096;

/// Thrown by [splitLetter] when the payload needs more than [letterMaxParts].
class LetterTooLong implements Exception {
  const LetterTooLong(this.bytes, this.limit);
  final int bytes;
  final int limit;
  @override
  String toString() => 'LetterTooLong($bytes B, limit $limit B)';
}

/// Thrown by [LetterAssembler.assemble] when every part is present but the
/// bytes do not hash to the digest the parts carry.
class LetterDigestMismatch implements Exception {
  const LetterDigestMismatch(this.id);
  final int id;
  @override
  String toString() => 'LetterDigestMismatch(id ${idHex(id)})';
}

/// The largest whole payload [maxPartBytes]-sized parts can carry.
int letterMaxTotalBytes({int maxPartBytes = letterPartMaxBytes}) =>
    (maxPartBytes - letterPartHeaderBytes) * letterMaxParts;

/// The id as the receiver names the assembled letter: 8 lowercase hex.
String idHex(int id) => id.toRadixString(16).padLeft(8, '0');

/// One part as parsed off the wire.
class LetterPart {
  const LetterPart({
    required this.id,
    required this.index,
    required this.total,
    required this.totalLength,
    required this.digest16,
    required this.slice,
  });

  final int id;
  final int index;
  final int total;
  final int totalLength;
  final Uint8List digest16;
  final Uint8List slice;
}

/// Splits [payload] into parts under [maxPartBytes] each, or returns it
/// bare when it fits in one. [id] is random unless given (tests, goldens).
List<Uint8List> splitLetter(
  Uint8List payload, {
  int maxPartBytes = letterPartMaxBytes,
  int? id,
}) {
  if (payload.length <= maxPartBytes) return [payload];
  final sliceMax = maxPartBytes - letterPartHeaderBytes;
  final total = (payload.length + sliceMax - 1) ~/ sliceMax;
  if (total > letterMaxParts) {
    throw LetterTooLong(payload.length, sliceMax * letterMaxParts);
  }
  final letterId = id ?? Random.secure().nextInt(0xFFFFFFFF);
  final digest = _sha256Bytes(payload);
  final parts = <Uint8List>[];
  for (var i = 0; i < total; i++) {
    final start = i * sliceMax;
    final end = min(start + sliceMax, payload.length);
    final out = Uint8List(letterPartHeaderBytes + (end - start));
    out[0] = _magic[0];
    out[1] = _magic[1];
    out[2] = letterPartVersion;
    out[3] = 0;
    out[4] = (letterId >> 24) & 0xFF;
    out[5] = (letterId >> 16) & 0xFF;
    out[6] = (letterId >> 8) & 0xFF;
    out[7] = letterId & 0xFF;
    out[8] = i;
    out[9] = total;
    out[10] = (payload.length >> 16) & 0xFF;
    out[11] = (payload.length >> 8) & 0xFF;
    out[12] = payload.length & 0xFF;
    out.setRange(13, 29, digest, 0);
    out.setRange(29, out.length, payload, start);
    parts.add(out);
  }
  return parts;
}

/// The part in [bytes], or null when they are not a part (a bare letter, a
/// picture, a voice note) or the header is malformed.
LetterPart? parseLetterPart(Uint8List bytes) {
  if (bytes.length < letterPartHeaderBytes) return null;
  if (bytes[0] != _magic[0] || bytes[1] != _magic[1]) return null;
  if (bytes[2] != letterPartVersion) return null;
  final index = bytes[8];
  final total = bytes[9];
  if (total < 1 || total > letterMaxParts || index >= total) return null;
  final id = (bytes[4] << 24) | (bytes[5] << 16) | (bytes[6] << 8) | bytes[7];
  final totalLength = (bytes[10] << 16) | (bytes[11] << 8) | bytes[12];
  return LetterPart(
    id: id,
    index: index,
    total: total,
    totalLength: totalLength,
    digest16: Uint8List.sublistView(bytes, 13, 29),
    slice: Uint8List.sublistView(bytes, 29),
  );
}

/// Collects the parts of ONE letter, in any order, tolerating duplicates.
/// The caller owns the deadline: it asks [isComplete] / [missing] and
/// decides when to stop waiting; nothing here throws on an absent part.
class LetterAssembler {
  LetterAssembler(this.id);

  final int id;
  final Map<int, LetterPart> _parts = <int, LetterPart>{};
  int? _total;

  int? get total => _total;
  int get received => _parts.length;
  bool get isComplete => _total != null && _parts.length == _total;

  /// Indexes not yet received, in order; empty when complete or when no
  /// part has told the assembler the total yet.
  List<int> get missing {
    final total = _total;
    if (total == null) return const [];
    return [
      for (var i = 0; i < total; i++)
        if (!_parts.containsKey(i)) i,
    ];
  }

  /// Adds one part of this letter. Returns false for a part of another
  /// letter, a part contradicting the total, or a duplicate.
  bool add(LetterPart part) {
    if (part.id != id) return false;
    if (_total != null && part.total != _total) return false;
    _total ??= part.total;
    if (_parts.containsKey(part.index)) return false;
    _parts[part.index] = part;
    return true;
  }

  /// The whole payload once complete, else null. Throws
  /// [LetterDigestMismatch] when the bytes do not hash to the carried digest.
  Uint8List? assemble() {
    if (!isComplete) return null;
    final first = _parts[0]!;
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < _total!; i++) {
      out.add(_parts[i]!.slice);
    }
    final whole = out.takeBytes();
    if (whole.length != first.totalLength) throw LetterDigestMismatch(id);
    final digest = _sha256Bytes(whole);
    for (var i = 0; i < 16; i++) {
      if (digest[i] != first.digest16[i]) throw LetterDigestMismatch(id);
    }
    return whole;
  }
}

/// sha256 as bytes, through the repo's one digest helper (hex in, bytes out).
Uint8List _sha256Bytes(List<int> bytes) {
  final hex = contentSha256Hex(bytes);
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
