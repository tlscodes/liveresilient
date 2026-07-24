import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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

  /// Hard ceiling on a chunk's declared piece count, checked before any
  /// per-index bookkeeping — a hostile peer cannot force an unbounded
  /// `_Partial` allocation via an absurd `total`.
  static const int maxChunks = 4096;

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
      if (n <= 0 || n > maxChunks) return null;
      if (i < 0 || i >= n) return null;
      final kind = MediaKind.values.firstWhere(
        (k) => k.name == obj['kind'],
        orElse: () => MediaKind.file,
      );
      final ct = obj['ct'];
      final data = base64Decode(d);
      if (data.length > AttachmentChunker.maxAllowedChunkBytes) return null;
      return AttachmentChunk(
        attachmentId: aid,
        kind: kind,
        contentType: ct is String ? ct : 'application/octet-stream',
        index: i,
        total: n,
        data: data,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Splits attachments into ordered chunks. An empty attachment yields a single
/// empty chunk so the receiver always completes.
class AttachmentChunker {
  /// Upper bound on a single chunk's payload size, checked both here
  /// (against [split]'s `maxChunkBytes`) and on the receiving side in
  /// [AttachmentChunk.tryDecode] — a hostile peer cannot claim a chunk larger
  /// than any legitimate sender could ever produce.
  static const int maxAllowedChunkBytes = 256 * 1024;

  static List<AttachmentChunk> split(
    Attachment a, {
    int maxChunkBytes = 12 * 1024,
  }) {
    if (maxChunkBytes <= 0 || maxChunkBytes > maxAllowedChunkBytes) {
      throw ArgumentError.value(
        maxChunkBytes,
        'maxChunkBytes',
        'Must be > 0 and <= $maxAllowedChunkBytes',
      );
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
  /// Maximum number of attachments with an incomplete partial in flight at
  /// once. Insertion-ordered `_partials` map, so once at cap the OLDEST
  /// incomplete partial is evicted to admit a new attachmentId — a hostile
  /// peer opening unbounded distinct attachmentIds cannot grow memory
  /// unboundedly.
  final int maxPendingAttachments;

  AttachmentReassembler({this.maxPendingAttachments = 16})
    : assert(maxPendingAttachments >= 1);

  final _partials = <String, _Partial>{};

  int get pendingCount => _partials.length;

  /// Feeds one chunk; returns the finished [Attachment] on the last piece, else
  /// null. A chunk whose total/kind/contentType conflicts with the partial
  /// already recorded for its attachmentId is dropped — the original partial
  /// is kept untouched.
  Attachment? accept(AttachmentChunk c) {
    final existing = _partials[c.attachmentId];
    if (existing != null) {
      if (existing.total != c.total ||
          existing.kind != c.kind ||
          existing.contentType != c.contentType) {
        return null; // conflicting chunk for a known id: drop it
      }
    } else {
      if (_partials.length >= maxPendingAttachments) {
        _partials.remove(_partials.keys.first); // evict oldest incomplete
      }
      _partials[c.attachmentId] = _Partial(c.total, c.kind, c.contentType);
    }

    final p = _partials[c.attachmentId]!;
    if (c.index < 0 || c.index >= p.total) return null;
    p.parts[c.index] = c.data;
    if (p.parts.length < p.total) return null;

    final builder = BytesBuilder(copy: false);
    for (var i = 0; i < p.total; i++) {
      builder.add(p.parts[i]!);
    }
    _partials.remove(c.attachmentId);
    return Attachment(
      id: c.attachmentId,
      kind: p.kind,
      contentType: p.contentType,
      bytes: builder.toBytes(),
    );
  }
}

/// A point-in-time snapshot of an outbound attachment transfer.
class AttachmentSendProgress {
  final int bytesSent;
  final int totalBytes;

  const AttachmentSendProgress(this.bytesSent, this.totalBytes);

  /// 0.0 → 1.0; an empty attachment is complete by definition.
  double get fraction => totalBytes == 0 ? 1.0 : bytesSent / totalBytes;
}

/// Live view of one outbound attachment transfer started by
/// [startAttachmentSend]: a [progress] stream plus current-state getters
/// ([bytesSent]/[totalBytes]) so late subscribers can still render.
class AttachmentSendHandle {
  AttachmentSendHandle._(this.totalBytes);

  final int totalBytes;
  int _bytesSent = 0;
  int get bytesSent => _bytesSent;

  final _progress = StreamController<AttachmentSendProgress>.broadcast();

  /// Emits after each chunk is handed to the messenger, starting with a
  /// `(0, totalBytes)` snapshot and ending at `bytesSent == totalBytes`;
  /// closes when the transfer finishes (also on error, after [done] errors).
  Stream<AttachmentSendProgress> get progress => _progress.stream;

  /// Completes when every chunk has been handed to the messenger (delivery
  /// itself is confirmed by the ack layer, as for chat text).
  late final Future<void> done;
}

/// Starts sending [attachment] over [messenger] and returns a handle whose
/// [AttachmentSendHandle.progress] reports bytesSent/totalBytes per chunk.
AttachmentSendHandle startAttachmentSend(
  ReliableMessenger messenger,
  Attachment attachment, {
  int maxChunkBytes = 12 * 1024,
}) {
  final chunks = AttachmentChunker.split(
    attachment,
    maxChunkBytes: maxChunkBytes,
  );
  final handle = AttachmentSendHandle._(attachment.sizeBytes);
  handle.done = () async {
    // Yield one microtask so a caller subscribing synchronously after this
    // returns still sees the initial (0, totalBytes) snapshot.
    await null;
    try {
      handle._progress.add(AttachmentSendProgress(0, handle.totalBytes));
      for (final chunk in chunks) {
        await messenger.send(chunk.encode());
        handle._bytesSent += chunk.data.length;
        handle._progress.add(
          AttachmentSendProgress(handle._bytesSent, handle.totalBytes),
        );
      }
    } finally {
      await handle._progress.close();
    }
  }();
  return handle;
}

/// Sends [attachment] over an existing [ReliableMessenger] by chunking it into
/// reliable text frames — reusing the exact delivery path the chat text uses.
/// (Kept as the simple await-to-completion form; [startAttachmentSend] is the
/// same transfer with a progress handle.)
Future<void> sendAttachment(
  ReliableMessenger messenger,
  Attachment attachment, {
  int maxChunkBytes = 12 * 1024,
}) async {
  await startAttachmentSend(
    messenger,
    attachment,
    maxChunkBytes: maxChunkBytes,
  ).done;
}

/// Consumes incoming chat text: routes attachment chunks to the reassembler and
/// leaves plain chat text alone. Emits an [Attachment] when one completes.
///
/// Idempotent against a full re-transmission of an already-completed
/// attachment (e.g. a sender-side retry after a drop/reconnect that resends
/// every chunk of an attachment whose id was already delivered): the
/// `attachmentId` — [Attachment.id], supplied by the sender and unchanged
/// across resends, unlike a fresh per-transfer id would be — is remembered
/// in a bounded FIFO set of the last [maxRememberedIds] completed ids. A
/// resend of an already-seen id is reassembled (memory-bounded, cheap) but
/// dropped SILENTLY at completion — no error surfaces to the sender, so the
/// sender's delivery/ack bookkeeping still sees it as delivered and its send
/// queue drains normally. Distinct attachment ids are never affected. Once
/// an id ages out of the cap it is treated as new again on next resend.
class AttachmentReceiver {
  /// Cap on remembered completed-attachment ids. Bounded so a long call
  /// cannot grow this set forever; oldest id is evicted first (FIFO) once at
  /// capacity.
  static const int maxRememberedIds = 256;

  final _reassembler = AttachmentReassembler();
  final _completed = StreamController<Attachment>.broadcast();
  final _seenIds = <String>{};

  Stream<Attachment> get completed => _completed.stream;
  int get pendingCount => _reassembler.pendingCount;

  /// Offers one incoming text. Returns true if it was an attachment chunk
  /// (consumed here), false if it is plain chat the caller should display.
  bool offer(String text) {
    final chunk = AttachmentChunk.tryDecode(text);
    if (chunk == null) return false;
    final done = _reassembler.accept(chunk);
    if (done != null) {
      if (!_seenIds.add(done.id)) {
        // Already delivered once: drop silently, do not re-emit.
        return true;
      }
      if (_seenIds.length > maxRememberedIds) {
        _seenIds.remove(_seenIds.first); // evict oldest (FIFO)
      }
      _completed.add(done);
    }
    return true;
  }

  Future<void> close() => _completed.close();
}
