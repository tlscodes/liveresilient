// What a sealed letter says, once it is open: a text, or the description of
// a photo, a voice note or a video whose bytes travel beside it in sealed
// chunks. The description carries the size, the SHA-256 of the whole and
// the number of chunks, so the recipient knows when it has all of it and
// that it is the right all of it.
import 'dart:convert';
import 'dart:typed_data';

/// The first byte of a typed body. A body that does not start with it is a
/// plain text from before letters had types.
const int sealedContentMarker = 0xA7;

/// The most one chunk carries. With the box's own overhead a chunk stays
/// under the box limit and far under what the relay queues.
const int sealedChunkBytes = 48000;

/// The most one media letter may be: 64 chunks.
const int sealedMaxMediaBytes = 64 * sealedChunkBytes;

enum SealedMediaKind {
  photo(1, 'photo'),
  voice(2, 'voice'),
  video(3, 'video'),
  file(4, 'file');

  const SealedMediaKind(this.wire, this.label);
  final int wire;
  final String label;

  static SealedMediaKind? fromWire(int value) {
    for (final kind in values) {
      if (kind.wire == value) return kind;
    }
    return null;
  }
}

/// A photo, voice note or video described, not carried.
class SealedMedia {
  const SealedMedia({
    required this.kind,
    required this.contentType,
    required this.size,
    required this.sha256,
    required this.chunks,
    this.duration = Duration.zero,
    this.caption = '',
  });

  final SealedMediaKind kind;

  /// A MIME type, e.g. `image/jpeg`.
  final String contentType;
  final int size;
  final Uint8List sha256;
  final int chunks;

  /// How long it plays; zero for a photo or when unknown.
  final Duration duration;
  final String caption;
}

/// A letter's content: exactly one of [text] and [media].
class SealedContent {
  const SealedContent.text(String this.text) : media = null;
  const SealedContent.media(SealedMedia this.media) : text = null;

  final String? text;
  final SealedMedia? media;

  /// `text`, `photo`, `voice`, `video` or `file`.
  String get kindLabel => media?.kind.label ?? 'text';

  /// The size a person would quote: the text's bytes, or the media's.
  int get bytes => media?.size ?? utf8.encode(text ?? '').length;

  /// One line for a list.
  String get summary {
    final m = media;
    if (m == null) return text ?? '';
    final seconds = m.duration.inMilliseconds / 1000;
    final length = m.duration > Duration.zero
        ? ' · ${seconds.toStringAsFixed(seconds < 10 ? 1 : 0)} s'
        : '';
    final caption = m.caption.isEmpty ? '' : ' — ${m.caption}';
    return '${m.kind.label} · ${_size(m.size)}$length$caption';
  }

  Uint8List encode() {
    final m = media;
    if (m == null) {
      return Uint8List.fromList([
        sealedContentMarker,
        1,
        ...utf8.encode(text ?? ''),
      ]);
    }
    final type = ascii.encode(m.contentType);
    if (type.length > 255) {
      throw ArgumentError.value(m.contentType, 'contentType', 'too long');
    }
    final out = BytesBuilder()
      ..add([sealedContentMarker, 2, m.kind.wire, type.length])
      ..add(type)
      ..add(_u32(m.size))
      ..add(m.sha256)
      ..add(_u16(m.chunks))
      ..add(_u32(m.duration.inMilliseconds))
      ..add(utf8.encode(m.caption));
    return out.takeBytes();
  }

  /// Reads a letter's body. Never throws: anything that is not a
  /// well-formed typed body is shown as the text it most plainly is.
  static SealedContent decode(Uint8List body) {
    try {
      if (body.length >= 2 && body[0] == sealedContentMarker) {
        if (body[1] == 1) {
          return SealedContent.text(
            utf8.decode(body.sublist(2), allowMalformed: true),
          );
        }
        if (body[1] == 2) {
          final kind = SealedMediaKind.fromWire(body[2]);
          final typeLength = body[3];
          var at = 4;
          final contentType = ascii.decode(body.sublist(at, at += typeLength));
          final view = ByteData.sublistView(body);
          final size = view.getUint32(at);
          at += 4;
          final sha = Uint8List.fromList(body.sublist(at, at += 32));
          final chunks = view.getUint16(at);
          at += 2;
          final durationMs = view.getUint32(at);
          at += 4;
          if (kind != null &&
              size > 0 &&
              size <= sealedMaxMediaBytes &&
              chunks == (size + sealedChunkBytes - 1) ~/ sealedChunkBytes) {
            return SealedContent.media(
              SealedMedia(
                kind: kind,
                contentType: contentType,
                size: size,
                sha256: sha,
                chunks: chunks,
                duration: Duration(milliseconds: durationMs),
                caption: utf8.decode(body.sublist(at), allowMalformed: true),
              ),
            );
          }
        }
      }
    } catch (_) {
      // Fall through: shown as text.
    }
    return SealedContent.text(utf8.decode(body, allowMalformed: true));
  }
}

String _size(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(0)} KB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

Uint8List _u32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value);
Uint8List _u16(int value) =>
    Uint8List(2)..buffer.asByteData().setUint16(0, value);
