import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'attachment.dart';
import 'attachment_route_decision.dart';
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
  AttachmentSendHandle._(this.totalBytes, this.routeDecision);

  final int totalBytes;

  /// What the media router said about this transfer, or null when no advisor
  /// was supplied.
  ///
  /// Exposed rather than merely logged because the eventual switch changes what
  /// [progress] MEANS: on the acknowledged path "bytes sent" is very nearly
  /// "bytes delivered", and on a rateless path it is not — a rateless sender
  /// deliberately emits more bytes than the object contains. A UI that shows a
  /// percentage has to know which regime it is in, and this is where it will
  /// find out.
  final AttachmentRouteDecision? routeDecision;

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
  AttachmentRouteAdvisor? routeAdvisor,
}) {
  final chunks = AttachmentChunker.split(
    attachment,
    maxChunkBytes: maxChunkBytes,
  );
  // Shadow mode: ask, record, and keep sending the old way. Obeying the answer
  // needs the receive-side transferId -> layer router, which does not exist in
  // the app yet; emitting rateless symbols nobody reassembles would turn a slow
  // photo into a lost one. See attachment_route_decision.dart for why the
  // question is asked anyway.
  final decision = routeAdvisor?.call(
    byteLength: attachment.sizeBytes,
    isImage: attachment.kind == MediaKind.image,
  );
  final handle = AttachmentSendHandle._(attachment.sizeBytes, decision);
  handle.done = () async {
    // Yield one microtask so a caller subscribing synchronously after this
    // returns still sees the initial (0, totalBytes) snapshot.
    await null;
    // ACK-PACED STREAMING: one chunk in flight, the next handed over only
    // after this one's delivery is confirmed. The channel underneath is
    // already reliable-ordered, so blasting every chunk at once only fills
    // the transport's send buffer — measured 2026-08-07 (T2 narrow,
    // 16 kbit/s): a 48 KB photo parked 100 KB+ of chunks plus app-layer
    // retransmit duplicates in the SCTP buffer and the voice note queued
    // behind minutes of backlog, missing every window while the photo's
    // "delivered" chunks were still draining. One in flight keeps the pipe
    // busy without bloating it, and a failed chunk surfaces here instead
    // of as a silent stall.
    //
    // The deliveries subscription is opened BEFORE the first send and
    // events are buffered by id: `deliveries` is a broadcast stream, and
    // an ack that lands between send() resuming and a later listen() would
    // otherwise be DROPPED — the id leaves the messenger's pending map
    // before the event is emitted, so no later event ever comes and the
    // transfer would hang forever (adversarial review finding,
    // 2026-08-07).
    final unclaimed = <String, DeliveryState>{};
    final waiters = <String, Completer<DeliveryState>>{};
    final deliverySub = messenger.deliveries.listen((d) {
      final waiter = waiters.remove(d.$1);
      if (waiter != null) {
        waiter.complete(d.$2);
      } else {
        unclaimed[d.$1] = d.$2;
      }
    });
    Future<DeliveryState> deliveryOf(String messageId) {
      final buffered = unclaimed.remove(messageId);
      if (buffered != null) return Future.value(buffered);
      return (waiters[messageId] = Completer<DeliveryState>()).future;
    }

    try {
      handle._progress.add(AttachmentSendProgress(0, handle.totalBytes));
      for (final chunk in chunks) {
        final message = await messenger.send(chunk.encode());
        final state = await deliveryOf(message.id);
        if (state != DeliveryState.delivered) {
          throw StateError(
            'attachment ${attachment.id} chunk ${chunk.index} failed '
            'delivery (${state.name})',
          );
        }
        handle._bytesSent += chunk.data.length;
        handle._progress.add(
          AttachmentSendProgress(handle._bytesSent, handle.totalBytes),
        );
      }
    } catch (error, stack) {
      // THE PROGRESS STREAM MUST CARRY THE FAILURE.
      //
      // It used to close cleanly on error, so a subscriber watching only
      // `progress` — the natural thing for a progress bar — saw `onDone` at
      // whatever fraction the failure reached and rendered a stalled bar
      // vanishing as if the send had succeeded. The doc promised "closes on
      // error" and delivered exactly that, which was the problem: closing is
      // indistinguishable from finishing.
      handle._progress.addError(error, stack);
      rethrow;
    } finally {
      // Detached, not awaited: cancel() of a listener on a broadcast
      // controller returns the SDK's root-zone _nullFuture; awaiting it
      // parks the continuation outside any fake_async zone (same trap as
      // call_core's teardown, measured 2026-08-07).
      unawaited(deliverySub.cancel());
      await handle._progress.close();
    }
  }();
  // The future is created eagerly, so a caller that never awaits `done` would
  // otherwise get an unhandled zone error from a method named "start" —
  // exactly the shape that invites fire-and-forget. The error is preserved on
  // `done` for whoever does await it, and swallowed here only so that not
  // awaiting is a lost report rather than a crashed isolate.
  unawaited(handle.done.catchError((Object _) {}));
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
