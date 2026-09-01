import 'dart:convert';
import 'dart:typed_data';

/// Phase 5 peak 6 — compact news page wire format.
///
/// A news page travels as canonical CBOR (definite lengths, fixed key order)
/// compressed with Brotli quality 11. This file owns the CBOR subset the page
/// schema needs — uint, text string, map — encoded deterministically so the
/// same page always yields identical bytes. Brotli itself is injected like the
/// text codec's compressor: host benches use the brotli CLI, device builds
/// bind the native library.
///
/// Page schema (fixed key order, gate 6):
///   ver(int) title dek published source image{type hash w h alt} body
/// The embedded image is a BlurHash (or vector) representation whose encoded
/// size must stay <= 500B — the gate books it separately.

typedef BrotliCompress = Uint8List Function(Uint8List raw);
typedef BrotliDecompress = Uint8List Function(Uint8List wire);

class MalformedNewsPage implements Exception {
  final String reason;
  MalformedNewsPage(this.reason);
  @override
  String toString() => 'MalformedNewsPage($reason)';
}

const List<String> newsPageKeys = [
  'ver',
  'title',
  'dek',
  'published',
  'source',
  'image',
  'body',
];
const List<String> newsImageKeys = ['type', 'hash', 'w', 'h', 'alt'];

void _cborUint(BytesBuilder b, int major, int n) {
  if (n < 24) {
    b.addByte(major << 5 | n);
  } else if (n < 256) {
    b
      ..addByte(major << 5 | 24)
      ..addByte(n);
  } else if (n < 65536) {
    b
      ..addByte(major << 5 | 25)
      ..addByte(n >> 8)
      ..addByte(n & 0xFF);
  } else {
    b.addByte(major << 5 | 26);
    b.add([n >> 24 & 0xFF, n >> 16 & 0xFF, n >> 8 & 0xFF, n & 0xFF]);
  }
}

void _cborValue(BytesBuilder b, Object? v) {
  if (v is int) {
    v < 0 ? _cborUint(b, 1, -1 - v) : _cborUint(b, 0, v);
  } else if (v is String) {
    final bytes = Uint8List.fromList(utf8.encode(v));
    _cborUint(b, 3, bytes.length);
    b.add(bytes);
  } else if (v is Map<String, Object?>) {
    _cborUint(b, 5, v.length);
    for (final e in v.entries) {
      _cborValue(b, e.key);
      _cborValue(b, e.value);
    }
  } else {
    throw MalformedNewsPage('unsupported value type: ${v.runtimeType}');
  }
}

/// Canonical CBOR bytes of [page] with the schema's fixed key order enforced.
Uint8List encodeNewsCbor(Map<String, Object?> page) {
  for (final k in newsPageKeys) {
    if (!page.containsKey(k)) throw MalformedNewsPage('missing key $k');
  }
  final image = page['image'];
  if (image is! Map<String, Object?>) {
    throw MalformedNewsPage('image must be a map');
  }
  final ordered = <String, Object?>{
    for (final k in newsPageKeys)
      k: k == 'image'
          ? <String, Object?>{for (final ik in newsImageKeys) ik: image[ik]}
          : page[k],
  };
  final b = BytesBuilder(copy: false);
  _cborValue(b, ordered);
  return b.takeBytes();
}

/// Full wire bytes: canonical CBOR then Brotli.
Uint8List encodeNewsPage(Map<String, Object?> page, BrotliCompress brotli) =>
    brotli(encodeNewsCbor(page));

class _Reader {
  final Uint8List b;
  int i = 0;
  _Reader(this.b);

  int _len(int info) {
    if (info < 24) return info;
    if (info == 24) return b[i++];
    if (info == 25) {
      final n = b[i] << 8 | b[i + 1];
      i += 2;
      return n;
    }
    if (info == 26) {
      final n = b[i] << 24 | b[i + 1] << 16 | b[i + 2] << 8 | b[i + 3];
      i += 4;
      return n;
    }
    throw MalformedNewsPage('length form not in subset');
  }

  Object? value() {
    final ib = b[i++];
    final major = ib >> 5, info = ib & 0x1F;
    final n = _len(info);
    switch (major) {
      case 0:
        return n;
      case 1:
        return -1 - n;
      case 3:
        final s = utf8.decode(b.sublist(i, i + n));
        i += n;
        return s;
      case 5:
        final m = <String, Object?>{};
        for (var k = 0; k < n; k++) {
          final key = value();
          if (key is! String) throw MalformedNewsPage('non-string map key');
          m[key] = value();
        }
        return m;
      default:
        throw MalformedNewsPage('major $major not in subset');
    }
  }
}

/// Decodes wire bytes back to the page map; malformed input fails cleanly.
Map<String, Object?> decodeNewsPage(Uint8List wire, BrotliDecompress brotli) {
  final cbor = brotli(wire);
  final v = _Reader(cbor).value();
  if (v is! Map<String, Object?>) throw MalformedNewsPage('root not a map');
  for (final k in newsPageKeys) {
    if (!v.containsKey(k)) throw MalformedNewsPage('missing key $k');
  }
  return v;
}
