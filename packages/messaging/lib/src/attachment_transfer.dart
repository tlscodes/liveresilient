import 'dart:async';
import 'dart:convert';

import 'attachment.dart';
import 'reliable_messenger.dart';

/// One slice of an [Attachment]. Chunks are sent as ordinary reliable text
/// messages, so they inherit the messenger's at-least-once delivery, ack, and
/// de-duplication — the same guarantees the chat text uses.
class AttachmentChunk {
  final String attachmentId;
  final MediaKind kind;
  final String contentType;
  final int index;
  final int total;
  final List<int> data;

  AttachmentChunk({
    required this.attachmentId,
    required this.kind,
    required this.contentType,
    required this.index,
    required this.total,
    required List<int> data,
  }) : data = List.unmodifiable(data);

  /// Encodes to a self-describing text frame carried by [ReliableMessenger].
  String encode() => jsonEncode({
    't': 'attach',
    'aid': attachmentId,
    'kind': kind.name,
    'ct': contentType,
    'i': index,
    'n': total,
    'd': base64Encode(data),
  });

  /// Decodes a chunk frame, or null if [text] is not one (e.g. plain chat).
  static AttachmentChunk? tryDecode(String text) {
    try {
      final obj = jsonDecode(text);
      if (obj is! Map || obj['t'] != 'attach') return null;
      final aid = obj['aid'];
      final i = obj['i'];
      final n = obj['n'];
      final d = obj['d'];
      if (aid is! String || i is! int || n is! int || d is! String) return null;
      if (i < 0 || n <= 0 || i >= n) return null;
      final kind = MediaKind.values.firstWhere(
        (k) => k.name == obj['kind'],
        orElse: () => MediaKind.file,
      );
      final ct = obj['ct'];
      return AttachmentChunk(
        attachmentId: aid,
        kind: kind,
        contentType: ct is String ? ct : 'application/octet-stream',
        index: i,
        total: n,
        data: base64Decode(d),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Splits attachments into ordered chunks. An empty attachment yields a single
/// empty chunk so the receiver always completes.
class AttachmentChunker {
  static List<AttachmentChunk> split(
    Attachment a, {
    int maxChunkBytes = 12 * 1024,
  }) {
    if (maxChunkBytes <= 0) {
      throw ArgumentError.value(maxChunkBytes, 'maxChunkBytes', 'Must be > 0');
    }
    final total = a.bytes.isEmpty ? 1 : (a.bytes.length / maxChunkBytes).ceil();
    return [
      for (var i = 0; i < total; i++)
        AttachmentChunk(
          attachmentId: a.id,
          kind: a.kind,
          contentType: a.contentType,
          index: i,
          total: total,
          data: a.bytes.sublist(
            i * maxChunkBytes,
            ((i + 1) * maxChunkBytes).clamp(0, a.bytes.length),
          ),
        ),
    ];
  }
}

class _Partial {
  final int total;
  final MediaKind kind;
  final String contentType;
  final Map<int, List<int>> parts = {};
  _Partial(this.total, this.kind, this.contentType);
}

/// Reassembles chunks into complete [Attachment]s. Tolerates out-of-order and
/// duplicate chunks (duplicates by index are idempotent).
class AttachmentReassembler {
  final _partials = <String, _Partial>{};

  int get pendingCount => _partials.length;

  /// Feeds one chunk; returns the finished [Attachment] on the last piece, else
  /// null.
  Attachment? accept(AttachmentChunk c) {
    final p = _partials.putIfAbsent(
      c.attachmentId,
      () => _Partial(c.total, c.kind, c.contentType),
    );
    if (c.index < 0 || c.index >= p.total) return null;
    p.parts[c.index] = c.data;
    if (p.parts.length < p.total) return null;

    final bytes = <int>[];
    for (var i = 0; i < p.total; i++) {
      bytes.addAll(p.parts[i]!);
    }
    _partials.remove(c.attachmentId);
    return Attachment(
      id: c.attachmentId,
      kind: p.kind,
      contentType: p.contentType,
      bytes: bytes,
    );
  }
}

/// Sends [attachment] over an existing [ReliableMessenger] by chunking it into
/// reliable text frames — reusing the exact delivery path the chat text uses.
Future<void> sendAttachment(
  ReliableMessenger messenger,
  Attachment attachment, {
  int maxChunkBytes = 12 * 1024,
}) async {
  for (final chunk in AttachmentChunker.split(
    attachment,
    maxChunkBytes: maxChunkBytes,
  )) {
    await messenger.send(chunk.encode());
  }
}

/// Consumes incoming chat text: routes attachment chunks to the reassembler and
/// leaves plain chat text alone. Emits an [Attachment] when one completes.
class AttachmentReceiver {
  final _reassembler = AttachmentReassembler();
  final _completed = StreamController<Attachment>.broadcast();

  Stream<Attachment> get completed => _completed.stream;
  int get pendingCount => _reassembler.pendingCount;

  /// Offers one incoming text. Returns true if it was an attachment chunk
  /// (consumed here), false if it is plain chat the caller should display.
  bool offer(String text) {
    final chunk = AttachmentChunk.tryDecode(text);
    if (chunk == null) return false;
    final done = _reassembler.accept(chunk);
    if (done != null) _completed.add(done);
    return true;
  }

  Future<void> close() => _completed.close();
}
