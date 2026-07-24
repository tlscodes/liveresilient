/// Chunked, resumable, self-healing transfer for large payloads over
/// weak links.
///
/// A large payload is split into chunks, each carried as its own bundle
/// (`<transferId>#<index>/<total>`). Per group of [ResumableTransfer
/// .parityGroupSize] data chunks, one XOR parity bundle
/// (`<transferId>#P<group>/<total>`) is added, so the receiver rebuilds
/// any single lost chunk per group WITHOUT a retransmission round-trip.
/// Delivery progress is tracked per chunk: after a lane failure or
/// switch only the missing chunks are re-sent — every byte that made it
/// across stays across. Chunk size adapts to the link (small on slow or
/// lossy lanes so a failure wastes little; large on fast clean ones so
/// framing overhead stays negligible).
library;

import 'weak_link_codec.dart';

/// Naming scheme for chunk bundles, shared by sender and receiver.
/// Data: `id#3/10` — parity: `id#P0/10@52341` (parity of data group 0;
/// `@bytes` carries the transfer's exact total byte length so the
/// receiver can rebuild even the final, shorter chunk to its true size).
class ChunkId {
  const ChunkId(
    this.transferId,
    this.index,
    this.total, {
    this.parity = false,
    this.totalBytes,
  });

  final String transferId;

  /// Data-chunk index, or the GROUP index when [parity] is true.
  final int index;
  final int total;
  final bool parity;

  /// Exact payload length in bytes — present on parity ids only.
  final int? totalBytes;

  String encode() => parity
      ? '$transferId#P$index/$total@${totalBytes ?? 0}'
      : '$transferId#$index/$total';

  static ChunkId? decode(String bundleId) {
    final m = RegExp(r'^(.+)#(P?)(\d+)/(\d+)(?:@(\d+))?$').firstMatch(bundleId);
    if (m == null) return null;
    final parity = m.group(2)!.isNotEmpty;
    final index = int.parse(m.group(3)!);
    final total = int.parse(m.group(4)!);
    if (total <= 0 || index < 0 || (!parity && index >= total)) return null;
    return ChunkId(
      m.group(1)!,
      index,
      total,
      parity: parity,
      totalBytes: m.group(5) == null ? null : int.parse(m.group(5)!),
    );
  }
}

/// One chunk ready to send.
class TransferChunk {
  const TransferChunk({required this.id, required this.payload});

  final ChunkId id;
  final List<int> payload;
}

/// Picks a chunk size from live link quality: slow/lossy lanes get small
/// chunks (a failure wastes little; parity groups heal faster), fast
/// clean lanes get large ones (framing overhead stays negligible).
int adaptiveChunkSize({
  required double linkScore,
  int floorBytes = 2 * 1024,
  int ceilingBytes = 64 * 1024,
}) {
  final clamped = linkScore.clamp(0.0, 1.0);
  return (floorBytes + ((ceilingBytes - floorBytes) * clamped)).round();
}

/// Sender-side state of one resumable, parity-protected transfer.
class ResumableTransfer {
  ResumableTransfer({
    required this.transferId,
    required List<int> payload,
    this.chunkSize = 16 * 1024,
    this.parityGroupSize = 4,
  }) : _payload = List.unmodifiable(payload),
       assert(chunkSize > 0, 'chunkSize must be positive'),
       assert(parityGroupSize >= 2, 'a parity group needs >= 2 data chunks') {
    _total = (_payload.length + chunkSize - 1) ~/ chunkSize;
    if (_total == 0) _total = 1; // empty-guard: payload is validated upstream
  }

  final String transferId;
  final int chunkSize;

  /// Data chunks per XOR parity chunk (overhead = 1/parityGroupSize).
  final int parityGroupSize;

  final List<int> _payload;
  late int _total;
  final Set<int> _delivered = {};
  final Set<int> _parityDelivered = {};

  int get totalChunks => _total;
  int get totalParityChunks => (_total + parityGroupSize - 1) ~/ parityGroupSize;
  int get deliveredChunks => _delivered.length;
  bool get complete => _delivered.length == _total;

  /// Fraction 0..1 for progress UI (data chunks only).
  double get progress => _total == 0 ? 1 : _delivered.length / _total;

  List<int> _dataChunk(int i) => _payload.sublist(
    i * chunkSize,
    (i + 1) * chunkSize > _payload.length
        ? _payload.length
        : (i + 1) * chunkSize,
  );

  /// The data chunks still missing — call after any failure to resume
  /// with exactly the remainder, never the whole payload again.
  List<TransferChunk> remainingChunks() => [
    for (var i = 0; i < _total; i++)
      if (!_delivered.contains(i))
        TransferChunk(
          id: ChunkId(transferId, i, _total),
          payload: _dataChunk(i),
        ),
  ];

  /// Parity chunks still to send — one per not-yet-covered group. Sent
  /// after the group's data so the receiver can heal one loss per group.
  List<TransferChunk> remainingParityChunks() {
    const parityCodec = ParityGroup();
    return [
      for (var g = 0; g < totalParityChunks; g++)
        if (!_parityDelivered.contains(g))
          TransferChunk(
            id: ChunkId(
              transferId,
              g,
              _total,
              parity: true,
              totalBytes: _payload.length,
            ),
            payload: parityCodec.parityOf([
              for (
                var i = g * parityGroupSize;
                i < (g + 1) * parityGroupSize && i < _total;
                i++
              )
                _dataChunk(i),
            ]),
          ),
    ];
  }

  /// Records a confirmed-delivered data chunk.
  void markDelivered(int index) {
    if (index >= 0 && index < _total) _delivered.add(index);
  }

  /// Records a confirmed-delivered parity chunk (by group index).
  void markParityDelivered(int group) {
    if (group >= 0 && group < totalParityChunks) _parityDelivered.add(group);
  }

  /// Serializable progress so a transfer survives an app restart.
  Map<String, Object?> toJson() => {
    'transferId': transferId,
    'chunkSize': chunkSize,
    'parityGroupSize': parityGroupSize,
    'delivered': _delivered.toList()..sort(),
    'parityDelivered': _parityDelivered.toList()..sort(),
  };

  /// Restores delivered-sets from persisted progress (payload re-supplied
  /// by the caller, e.g. re-read from the outbox file).
  void restore(Map<String, Object?> json) {
    final delivered = json['delivered'];
    if (delivered is List) {
      for (final d in delivered) {
        if (d is int) markDelivered(d);
      }
    }
    final parity = json['parityDelivered'];
    if (parity is List) {
      for (final g in parity) {
        if (g is int) markParityDelivered(g);
      }
    }
  }
}

/// Receiver-side reassembly with per-group parity healing: a transfer
/// completes even when one data chunk per parity group never arrives.
class ChunkReassembler {
  ChunkReassembler({this.parityGroupSize = 4});

  final int parityGroupSize;

  final Map<String, Map<int, List<int>>> _parts = {};
  final Map<String, Map<int, List<int>>> _parityParts = {};
  final Map<String, int> _totals = {};
  final Map<String, int> _totalBytes = {};

  /// Feeds one received bundle (data or parity). Returns the fully
  /// reassembled payload when the transfer completes (directly or via
  /// parity healing), else null. Non-chunk ids return null untouched.
  /// Duplicates are idempotent.
  List<int>? accept(String bundleId, List<int> payload) {
    final id = ChunkId.decode(bundleId);
    if (id == null) return null;
    _totals[id.transferId] = id.total;
    if (id.parity) {
      _parityParts.putIfAbsent(id.transferId, () => {})[id.index] = payload;
      if (id.totalBytes != null && id.totalBytes! > 0) {
        _totalBytes[id.transferId] = id.totalBytes!;
      }
    } else {
      _parts.putIfAbsent(id.transferId, () => {})[id.index] = payload;
    }
    return _tryComplete(id.transferId);
  }

  List<int>? _tryComplete(String transferId) {
    final total = _totals[transferId];
    if (total == null) return null;
    final parts = _parts.putIfAbsent(transferId, () => {});
    _healWithParity(transferId, parts, total);
    if (parts.length < total) return null;
    final whole = <int>[
      for (var i = 0; i < total; i++) ...parts[i]!,
    ];
    _parts.remove(transferId);
    _parityParts.remove(transferId);
    _totals.remove(transferId);
    _totalBytes.remove(transferId);
    return whole;
  }

  /// Rebuilds any group that is missing exactly one data chunk and has
  /// its parity chunk. The last chunk of the payload may be shorter than
  /// the rest; its true length is recovered from the parity width vs the
  /// survivors (XOR of equal-padded chunks preserves trailing bytes).
  void _healWithParity(
    String transferId,
    Map<int, List<int>> parts,
    int total,
  ) {
    final parityParts = _parityParts[transferId];
    if (parityParts == null) return;
    const parityCodec = ParityGroup();
    final groups = (total + parityGroupSize - 1) ~/ parityGroupSize;
    for (var g = 0; g < groups; g++) {
      final parity = parityParts[g];
      if (parity == null) continue;
      final members = [
        for (
          var i = g * parityGroupSize;
          i < (g + 1) * parityGroupSize && i < total;
          i++
        )
          i,
      ];
      final missing = [
        for (final i in members)
          if (!parts.containsKey(i)) i,
      ];
      if (missing.length != 1) continue;
      final present = [
        for (final i in members)
          if (i != missing.single) parts[i]!,
      ];
      // Exact lost length: every chunk is full-width except the
      // transfer's final one, whose true size derives from the total
      // byte length the parity id carries. Full width comes from the
      // widest data chunk received so far (a lone-tail parity group's
      // parity is narrower than a full chunk).
      final bytes = _totalBytes[transferId];
      final fullWidth = parts.values.fold(
        parity.length,
        (a, c) => c.length > a ? c.length : a,
      );
      final isLast = missing.single == total - 1;
      final lostLength = isLast && bytes != null && fullWidth > 0
          ? bytes - (total - 1) * fullWidth
          : fullWidth;
      if (lostLength <= 0 || lostLength > parity.length) continue;
      parts[missing.single] = parityCodec.recover(
        present,
        parity,
        lostLength: lostLength,
      );
    }
  }

  /// Progress 0..1 for a transfer in flight (1 when unknown/done).
  double progressOf(String transferId) {
    final total = _totals[transferId];
    if (total == null || total == 0) return 1;
    return (_parts[transferId]?.length ?? 0) / total;
  }
}
