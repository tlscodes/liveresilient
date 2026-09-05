/// The blackout v2 forwarder: pure Dart, no I/O, so the chunk splitter and
/// the resume-from-the-first-missing-chunk logic can be tested against a
/// fake transport.
///
/// A blackout job (job.json "blackout" with "v":2) carries a plan of
/// bundles with real sizes and priorities. The phone signs each one at T0,
/// keeps them in the durable queue, and every time the hub answers a probe
/// it flushes the whole queue in priority-then-age order. A bundle whose
/// envelope fits in [BlackoutPlan.chunkBytes] goes in one POST /bundle; a
/// larger one is split into chunks, the hub is asked which chunks it
/// already holds (GET /have), and only the missing ones are posted in index
/// order. A window that closes mid-transfer leaves its chunks on the hub,
/// so the next window resumes from the first missing index instead of
/// starting over.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:device_link/device_link.dart' show LinkMessagePriority;

/// One bundle of the plan: the `seq`-th bundle of its `kind`.
class BlackoutPlanItem {
  const BlackoutPlanItem({
    required this.kind,
    required this.bytes,
    required this.seq,
  });

  final String kind;
  final int bytes;
  final int seq;

  /// Text rides ahead of media: presence outranks bulk in the queue's
  /// delivery order, so the eight short messages leave before any photo.
  LinkMessagePriority get priority =>
      kind == 'text' ? LinkMessagePriority.presence : LinkMessagePriority.bulk;

  @override
  String toString() => '$kind#$seq(${bytes}B)';
}

/// The parsed "blackout" block of a v2 job.
class BlackoutPlan {
  const BlackoutPlan({
    required this.items,
    required this.probeS,
    required this.lifetimeS,
    required this.chunkBytes,
  });

  final List<BlackoutPlanItem> items;
  final int probeS;
  final int lifetimeS;
  final int chunkBytes;

  int get bytesTotal => items.fold(0, (sum, item) => sum + item.bytes);

  /// Null unless the block says `"v": 2`; a job without it is v1 and the
  /// caller keeps today's single-bundle behaviour. A v2 block with no
  /// usable plan entries yields an empty plan rather than null, so the
  /// caller can fail the job loudly instead of silently running v1.
  static BlackoutPlan? parse(Map<String, Object?> cfg) {
    if (cfg['v'] != 2) return null;
    final items = <BlackoutPlanItem>[];
    final plan = cfg['plan'];
    if (plan is List) {
      for (final entry in plan) {
        if (entry is! Map) continue;
        final kind = entry['kind'];
        final bytes = entry['bytes'];
        final n = entry['n'];
        if (kind is! String || kind.isEmpty || bytes is! int || bytes < 1) {
          continue;
        }
        final count = n is int ? n : 1;
        for (var seq = 0; seq < count; seq++) {
          items.add(BlackoutPlanItem(kind: kind, bytes: bytes, seq: seq));
        }
      }
    }
    return BlackoutPlan(
      items: items,
      probeS: _positiveInt(cfg['probe_s'], 2),
      lifetimeS: _positiveInt(cfg['lifetime_s'], 6 * 3600),
      chunkBytes: _positiveInt(cfg['chunk_bytes'], 8192),
    );
  }

  static int _positiveInt(Object? value, int fallback) =>
      value is int && value > 0 ? value : fallback;
}

/// The payload of one planned bundle: a JSON header naming the run, kind
/// and sequence (so the Mac can tell which bundle arrived from the bytes
/// alone), then random fill to exactly [bytes]. A header longer than
/// [bytes] is truncated; the size is the contract, not the header.
Uint8List blackoutPayload({
  required String run,
  required BlackoutPlanItem item,
  required int createdMs,
  required Random random,
}) {
  final header = utf8.encode(
    jsonEncode({
      'run': run,
      'kind': item.kind,
      'seq': item.seq,
      'created_ms': createdMs,
      'bytes': item.bytes,
    }),
  );
  final payload = Uint8List(item.bytes);
  payload.setRange(0, min(header.length, item.bytes), header);
  for (var i = header.length; i < item.bytes; i++) {
    payload[i] = random.nextInt(256);
  }
  return payload;
}

/// The signed envelope the hub's /bundle route parses: exactly the v1
/// shape, so the hub verifies a chunked bundle the same way once it has
/// reassembled it.
List<int> buildBlackoutEnvelope({
  required String run,
  required String id,
  required int createdMs,
  required List<int> payload,
  required List<int> signature,
  required String pubkeyB64,
}) {
  return utf8.encode(
    jsonEncode({
      'run': run,
      'id': id,
      'created_ms': createdMs,
      'payload': base64Encode(payload),
      'sig': base64Encode(signature),
      'pubkey': pubkeyB64,
    }),
  );
}

/// [bytes] cut into pieces of [chunkBytes]; the last piece is the
/// remainder. Empty input yields no chunks.
List<List<int>> splitChunks(List<int> bytes, int chunkBytes) {
  if (chunkBytes < 1) {
    throw ArgumentError.value(chunkBytes, 'chunkBytes', 'must be >= 1');
  }
  final chunks = <List<int>>[];
  for (var start = 0; start < bytes.length; start += chunkBytes) {
    chunks.add(bytes.sublist(start, min(start + chunkBytes, bytes.length)));
  }
  return chunks;
}

/// What the hub said to one chunk POST.
enum ChunkReply {
  /// 200 "ok": stored, more chunks to come.
  stored,

  /// 200 "complete ...": every chunk is in, the envelope was reassembled,
  /// verified and recorded as one bundle_received event.
  complete,

  /// Anything else — a network error, a timeout, a 4xx/5xx.
  failed,
}

/// The three hub routes the forwarder needs, abstracted so a test can
/// stand in for the network.
abstract class BlackoutTransport {
  /// POST /bundle with the whole envelope; true on 200.
  Future<bool> postWhole(String id, List<int> envelope);

  /// GET /have?id=: the chunk indexes the hub already holds, or null when
  /// the hub could not be asked (the window closed).
  Future<List<int>?> have(String id);

  /// POST /chunk with one raw chunk.
  Future<ChunkReply> postChunk({
    required String id,
    required int idx,
    required int n,
    required String sha256,
    required List<int> bytes,
  });
}

/// Drives one bundle through [transport]; the queue's forwarder calls
/// [forward] per bundle and keeps the bundle whenever it returns false.
class BlackoutForwarder {
  BlackoutForwarder(this.transport, {required this.chunkBytes, this.log}) {
    if (chunkBytes < 1) {
      throw ArgumentError.value(chunkBytes, 'chunkBytes', 'must be >= 1');
    }
  }

  final BlackoutTransport transport;
  final int chunkBytes;
  final void Function(String line)? log;

  /// Chunks posted by the most recent [forward] call, for the peer's notes.
  int lastChunksPosted = 0;

  /// True only when the hub holds the whole bundle: a 200 from /bundle, or
  /// "complete" from the chunk that finished it. Stops at the first
  /// failure so the caller's queue keeps the bundle for the next window.
  ///
  /// [sha256] is the hex digest of the whole [envelope]; the hub checks the
  /// reassembled bytes against it and refuses a chunk whose sha disagrees
  /// with the chunks it already holds for that id.
  Future<bool> forward({
    required String id,
    required List<int> envelope,
    required String sha256,
  }) async {
    lastChunksPosted = 0;
    if (envelope.length <= chunkBytes) {
      return transport.postWhole(id, envelope);
    }
    final chunks = splitChunks(envelope, chunkBytes);
    final n = chunks.length;
    final held = await transport.have(id);
    if (held == null) {
      log?.call('bundle $id: /have unreachable');
      return false;
    }
    final heldSet = held.where((idx) => idx >= 0 && idx < n).toSet();
    var missing = [
      for (var idx = 0; idx < n; idx++)
        if (!heldSet.contains(idx)) idx,
    ];
    if (missing.isEmpty) {
      // The hub holds every chunk but the reply that said so never reached
      // the phone (the window closed on the last ack). A chunk POST is
      // idempotent, so re-posting the last one asks for that reply again.
      missing = [n - 1];
    }
    log?.call(
      'bundle $id: $n chunks, hub has ${heldSet.length}, '
      'posting ${missing.length} from #${missing.first}',
    );
    for (final idx in missing) {
      final reply = await transport.postChunk(
        id: id,
        idx: idx,
        n: n,
        sha256: sha256,
        bytes: chunks[idx],
      );
      if (reply == ChunkReply.failed) {
        log?.call('bundle $id: chunk $idx/$n failed, $lastChunksPosted sent');
        return false;
      }
      lastChunksPosted++;
      if (reply == ChunkReply.complete) return true;
    }
    // Every missing chunk was stored yet none completed the bundle: the hub
    // and the phone disagree about what is held. The next window asks
    // /have again rather than trusting this pass.
    log?.call('bundle $id: all chunks posted, no completion');
    return false;
  }
}
