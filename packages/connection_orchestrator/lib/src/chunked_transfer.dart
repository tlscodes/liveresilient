/// Chunked, resumable transfer for large payloads over weak links.
///
/// A large payload is split into fixed-size chunks, each carried as its
/// own bundle (`<transferId>#<index>/<total>`). Delivery progress is
/// tracked per chunk, so after a lane failure or switch only the missing
/// chunks are re-sent — every byte that made it across stays across.
/// The receiving side reassembles once all chunks are present.
library;

/// Naming scheme for chunk bundles, shared by sender and receiver.
class ChunkId {
  const ChunkId(this.transferId, this.index, this.total);

  final String transferId;
  final int index;
  final int total;

  String encode() => '$transferId#$index/$total';

  static ChunkId? decode(String bundleId) {
    final m = RegExp(r'^(.+)#(\d+)/(\d+)$').firstMatch(bundleId);
    if (m == null) return null;
    final index = int.parse(m.group(2)!);
    final total = int.parse(m.group(3)!);
    if (total <= 0 || index < 0 || index >= total) return null;
    return ChunkId(m.group(1)!, index, total);
  }
}

/// One chunk ready to send.
class TransferChunk {
  const TransferChunk({required this.id, required this.payload});

  final ChunkId id;
  final List<int> payload;
}

/// Sender-side state of one resumable transfer.
class ResumableTransfer {
  ResumableTransfer({
    required this.transferId,
    required List<int> payload,
    this.chunkSize = 16 * 1024,
  }) : _payload = List.unmodifiable(payload),
       assert(chunkSize > 0, 'chunkSize must be positive') {
    _total = (_payload.length + chunkSize - 1) ~/ chunkSize;
    if (_total == 0) _total = 1; // empty-guard: payload is validated upstream
  }

  final String transferId;
  final int chunkSize;
  final List<int> _payload;
  late int _total;
  final Set<int> _delivered = {};

  int get totalChunks => _total;
  int get deliveredChunks => _delivered.length;
  bool get complete => _delivered.length == _total;

  /// Fraction 0..1 for progress UI.
  double get progress => _total == 0 ? 1 : _delivered.length / _total;

  /// The chunks still missing — call after any failure to resume with
  /// exactly the remainder, never the whole payload again.
  List<TransferChunk> remainingChunks() => [
    for (var i = 0; i < _total; i++)
      if (!_delivered.contains(i))
        TransferChunk(
          id: ChunkId(transferId, i, _total),
          payload: _payload.sublist(
            i * chunkSize,
            (i + 1) * chunkSize > _payload.length
                ? _payload.length
                : (i + 1) * chunkSize,
          ),
        ),
  ];

  /// Records a confirmed-delivered chunk.
  void markDelivered(int index) {
    if (index >= 0 && index < _total) _delivered.add(index);
  }

  /// Serializable progress so a transfer survives an app restart.
  Map<String, Object?> toJson() => {
    'transferId': transferId,
    'chunkSize': chunkSize,
    'delivered': _delivered.toList()..sort(),
  };

  /// Restores delivered-set from persisted progress (payload re-supplied
  /// by the caller, e.g. re-read from the outbox file).
  void restore(Map<String, Object?> json) {
    final delivered = json['delivered'];
    if (delivered is List) {
      for (final d in delivered) {
        if (d is int) markDelivered(d);
      }
    }
  }
}

/// Receiver-side reassembly of chunked transfers.
class ChunkReassembler {
  final Map<String, Map<int, List<int>>> _parts = {};
  final Map<String, int> _totals = {};

  /// Feeds one received bundle. Returns the fully reassembled payload
  /// when this chunk completes the transfer, else null. Non-chunk ids
  /// return null and are untouched (caller handles them as plain
  /// bundles). Duplicate chunks are idempotent.
  List<int>? accept(String bundleId, List<int> payload) {
    final id = ChunkId.decode(bundleId);
    if (id == null) return null;
    final parts = _parts.putIfAbsent(id.transferId, () => {});
    _totals[id.transferId] = id.total;
    parts[id.index] = payload;
    if (parts.length < id.total) return null;
    final whole = <int>[
      for (var i = 0; i < id.total; i++) ...parts[i]!,
    ];
    _parts.remove(id.transferId);
    _totals.remove(id.transferId);
    return whole;
  }

  /// Progress 0..1 for a transfer in flight (1 when unknown/done).
  double progressOf(String transferId) {
    final total = _totals[transferId];
    if (total == null || total == 0) return 1;
    return (_parts[transferId]?.length ?? 0) / total;
  }
}
