/// ISO BMFF (MP4) probe: walks the top-level boxes for `ftyp` and `moov`,
/// reads the movie header for the clock and the first video track header
/// for the picture size. Every read is bounds-checked; no exception escapes.
///
/// Pure Dart, no Flutter import: usable from widget code and plain tests.
library;

/// What the movie and track headers of an MP4 say about it.
class Mp4Info {
  const Mp4Info({
    required this.durationMs,
    required this.width,
    required this.height,
    required this.brand,
  });

  /// `mvhd` duration converted to milliseconds through its timescale.
  final int durationMs;

  /// Picture size from the FIRST `tkhd` whose width is non-zero (the audio
  /// track's is 0×0); both zero when no track carries a picture.
  final int width;
  final int height;

  /// `ftyp` major brand, e.g. `isom`, `mp42`, `qt  `.
  final String brand;
}

/// Parses the box tree of [bytes]. Null when `ftyp`, `moov` or `mvhd` is
/// missing or the structure is malformed; no exception escapes.
Mp4Info? probeMp4(List<int> bytes) {
  try {
    return _probe(bytes);
  } catch (_) {
    return null;
  }
}

class _Box {
  const _Box(this.type, this.bodyStart, this.end);
  final String type;
  final int bodyStart;
  final int end;
}

/// Reads the box header at [offset] within `[offset, limit)`. Null when the
/// header does not fit or the box overruns its parent.
_Box? _boxAt(List<int> bytes, int offset, int limit) {
  if (offset + 8 > limit) return null;
  var size = _u32be(bytes, offset);
  final type = _fourCc(bytes, offset + 4);
  var header = 8;
  if (size == 1) {
    if (offset + 16 > limit) return null;
    size = _u64be(bytes, offset + 8);
    header = 16;
  } else if (size == 0) {
    size = limit - offset;
  }
  if (size < header) return null;
  final end = offset + size;
  if (end > limit) return null;
  return _Box(type, offset + header, end);
}

Iterable<_Box> _children(List<int> bytes, int start, int limit) sync* {
  var offset = start;
  while (offset < limit) {
    final box = _boxAt(bytes, offset, limit);
    if (box == null) return;
    yield box;
    offset = box.end;
  }
}

Mp4Info? _probe(List<int> bytes) {
  String? brand;
  _Box? moov;
  for (final box in _children(bytes, 0, bytes.length)) {
    if (box.type == 'ftyp' && brand == null) {
      if (box.bodyStart + 4 > box.end) return null;
      brand = _fourCc(bytes, box.bodyStart);
    } else if (box.type == 'moov' && moov == null) {
      moov = box;
    }
    if (brand != null && moov != null) break;
  }
  if (brand == null || moov == null) return null;

  int? durationMs;
  var width = 0;
  var height = 0;
  for (final child in _children(bytes, moov.bodyStart, moov.end)) {
    if (child.type == 'mvhd' && durationMs == null) {
      durationMs = _movieDurationMs(bytes, child);
      if (durationMs == null) return null;
    } else if (child.type == 'trak' && width == 0) {
      for (final inner in _children(bytes, child.bodyStart, child.end)) {
        if (inner.type != 'tkhd') continue;
        final size = _trackSize(bytes, inner);
        if (size != null && size.$1 != 0) {
          width = size.$1;
          height = size.$2;
        }
        break;
      }
    }
  }
  if (durationMs == null) return null;
  return Mp4Info(
    durationMs: durationMs,
    width: width,
    height: height,
    brand: brand,
  );
}

/// `mvhd`: version 0 keeps a 32-bit timescale at body+12 and a 32-bit
/// duration at body+16; version 1 widens the two timestamps before them, so
/// the timescale sits at body+20 and a 64-bit duration at body+24.
int? _movieDurationMs(List<int> bytes, _Box box) {
  final body = box.bodyStart;
  if (body + 1 > box.end) return null;
  final version = bytes[body] & 0xFF;
  final int timescale;
  final int duration;
  if (version == 0) {
    if (body + 20 > box.end) return null;
    timescale = _u32be(bytes, body + 12);
    duration = _u32be(bytes, body + 16);
    if (duration == 0xFFFFFFFF) return 0; // "unknown" per the spec
  } else if (version == 1) {
    if (body + 32 > box.end) return null;
    timescale = _u32be(bytes, body + 20);
    duration = _u64be(bytes, body + 24);
    if (duration == -1) return 0; // all ones: "unknown"
  } else {
    return null;
  }
  if (timescale <= 0) return null;
  return duration * 1000 ~/ timescale;
}

/// `tkhd`: width and height are 16.16 fixed-point at body+76/+80 for
/// version 0 (84/88 from an 8-byte box header) and at body+88/+92 for
/// version 1 (96/100 from the header). Offsets are taken from the body so a
/// 64-bit box header would not shift them.
(int, int)? _trackSize(List<int> bytes, _Box box) {
  final body = box.bodyStart;
  if (body + 1 > box.end) return null;
  final version = bytes[body] & 0xFF;
  final int at;
  if (version == 0) {
    at = body + 76;
  } else if (version == 1) {
    at = body + 88;
  } else {
    return null;
  }
  if (at + 8 > box.end) return null;
  return (_u32be(bytes, at) >> 16, _u32be(bytes, at + 4) >> 16);
}

String _fourCc(List<int> bytes, int offset) {
  if (offset + 4 > bytes.length) return '';
  return String.fromCharCodes([
    bytes[offset] & 0xFF,
    bytes[offset + 1] & 0xFF,
    bytes[offset + 2] & 0xFF,
    bytes[offset + 3] & 0xFF,
  ]);
}

int _u32be(List<int> bytes, int offset) {
  if (offset + 4 > bytes.length) throw RangeError('u32 past end');
  return ((bytes[offset] & 0xFF) << 24) |
      ((bytes[offset + 1] & 0xFF) << 16) |
      ((bytes[offset + 2] & 0xFF) << 8) |
      (bytes[offset + 3] & 0xFF);
}

int _u64be(List<int> bytes, int offset) {
  if (offset + 8 > bytes.length) throw RangeError('u64 past end');
  return (_u32be(bytes, offset) << 32) | _u32be(bytes, offset + 4);
}
