/// The receive half of the cliff-free path, plus the addressing that makes it
/// work without adding a single byte to the wire.
///
/// THE ADDRESSING PROBLEM. A symbol must say which object and which layer it
/// belongs to, or the receiver cannot route it to a decoder. Adding an object
/// header to every 60-byte datagram would cost 8-10% — the entire framing
/// budget — and adding a manifest datagram creates a bootstrap the manifest
/// itself has to survive.
///
/// THE ANSWER. `TaggedDatagram.transferId` is already carried by
/// `MediaCarriage` for every datagram. Packing (objectId, layerCount,
/// layerIndex) into that existing integer names a symbol completely, so the
/// spec's "a symbol is fully named by transferId + its own esi" becomes true in
/// code at zero marginal cost. Nothing new is transmitted.
///
/// WHAT THE RECEIVER GUARANTEES. Layers decode independently and in any order;
/// the base layer is rendered the moment it completes, long before the object
/// is whole. A layer that never arrives costs quality, never correctness — the
/// decoded prefix is always byte-exact.
library;

import 'dart:typed_data';

import 'cliff_free_reassembler.dart';
import 'resilient_media_transport.dart' show MediaType;

/// Packs and unpacks the three identifiers a symbol needs.
///
/// Layout, low to high: 8 bits layerIndex · 8 bits layerCount · 16 bits
/// objectId. 32 bits total, well inside the platform integer on every target
/// including web (53-bit safe integers).
///
/// A plain class rather than an extension type: this value crosses a package
/// boundary and is stored in maps, and a zero-cost wrapper buys nothing here
/// while adding a language-feature dependency to a transport primitive.
final class CliffFreeTransferId {
  /// Wraps an id already on the wire.
  const CliffFreeTransferId(this.raw);

  /// Builds an id from its parts, refusing anything that would truncate.
  factory CliffFreeTransferId.of({
    required int objectId,
    required int layerCount,
    required int layerIndex,
  }) {
    if (objectId < 0 || objectId > maxObjectId) {
      throw RangeError.range(objectId, 0, maxObjectId, 'objectId');
    }
    if (layerCount < 1 || layerCount > maxLayers) {
      throw RangeError.range(layerCount, 1, maxLayers, 'layerCount');
    }
    if (layerIndex < 0 || layerIndex >= layerCount) {
      throw RangeError.range(layerIndex, 0, layerCount - 1, 'layerIndex');
    }
    return CliffFreeTransferId(
      (objectId << 16) | (layerCount << 8) | layerIndex,
    );
  }

  static const int maxObjectId = 0xFFFF;
  static const int maxLayers = 0xFF;

  /// The integer that travels as `TaggedDatagram.transferId`.
  final int raw;

  int get objectId => (raw >> 16) & 0xFFFF;
  int get layerCount => (raw >> 8) & 0xFF;
  int get layerIndex => raw & 0xFF;

  @override
  bool operator ==(Object other) =>
      other is CliffFreeTransferId && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;

  @override
  String toString() =>
      'CliffFreeTransferId(object $objectId, layer $layerIndex/$layerCount)';
}

/// What the UI is told when the renderable prefix grows.
class CliffFreeRenderEvent {
  const CliffFreeRenderEvent({
    required this.objectId,
    required this.type,
    required this.usableLayers,
    required this.layerCount,
    required this.bytes,
    required this.isComplete,
  });

  final int objectId;
  final MediaType type;

  /// Length of the decoded prefix starting at layer 0.
  final int usableLayers;
  final int layerCount;

  /// Concatenated bytes of that prefix — always exact, never partial.
  final Uint8List bytes;

  /// True when every layer, including any bit-exact tail, has decoded.
  final bool isComplete;

  /// The first render: a recognizable object from the base layer alone.
  bool get isFirstRender => usableLayers == 1;
}

/// Routes incoming symbols to per-object, per-layer decoders.
/// Why an object left the inbox without completing.
enum CliffFreeDropReason {
  /// Pushed out to make room. Its decoded prefix is gone; a re-send starts
  /// from zero rank.
  evicted,

  /// The wire named a layer this object does not have, or named zero layers.
  malformedAddress,
}

class CliffFreeInbox {
  CliffFreeInbox({this.maxConcurrentObjects = 8, this.onDropped}) {
    // A zero bound is not a small bound — it is a leak. With 0, the eviction
    // sweep removes the id from the order list while the map insert still
    // happens, so the object becomes unevictable and the map grows forever.
    if (maxConcurrentObjects < 1) {
      throw RangeError.value(
        maxConcurrentObjects,
        'maxConcurrentObjects',
        'must be >= 1',
      );
    }
  }

  /// Called when an object is discarded before completing.
  ///
  /// Dropping a half-decoded photo with no signal is silent data loss: the UI
  /// keeps showing a render that will never improve and never completes. The
  /// caller gets told, and can decide whether to ask for a re-send or to show
  /// the failure.
  final void Function(int objectId, CliffFreeDropReason reason)? onDropped;

  /// Bound on in-flight objects. Each open object holds elimination matrices;
  /// an unbounded inbox is a memory leak a peer can trigger by starting
  /// objects it never finishes. The oldest object is evicted, and because the
  /// code is rateless a re-sent object simply starts again.
  final int maxConcurrentObjects;

  final Map<int, CliffFreeReassembler> _byObject = {};
  final Map<int, MediaType> _typeByObject = {};
  final Map<int, int> _layerCountByObject = {};

  /// Least-recently-fed first. Refreshed on every accepted datagram, so a
  /// stalled object is evicted before a live one.
  final List<int> _order = [];

  /// Objects evicted for exceeding [maxConcurrentObjects]. Telemetry: a
  /// non-zero count means the peer is opening more objects than this device
  /// agreed to hold.
  int evictedObjects = 0;

  /// Datagrams refused because their transfer id named a layer that cannot
  /// exist. Non-zero means corruption on the wire or a peer sending nonsense;
  /// either way it is a fact worth surfacing rather than an exception.
  int malformedDatagrams = 0;

  /// Absorbs one datagram. Returns a render event when the usable prefix grew,
  /// null otherwise (including for duplicates, which cost nothing).
  CliffFreeRenderEvent? accept(int transferId, Uint8List datagram, MediaType type) {
    final id = CliffFreeTransferId(transferId);
    final objectId = id.objectId;

    // THE WIRE IS NOT TRUSTED. `CliffFreeTransferId.of` validates when WE build
    // an id; `accept` receives one that a peer — or a corrupted datagram —
    // chose. Without this check `layerCount == 0` throws out of the
    // reassembler's constructor and `layerIndex >= layerCount` throws a
    // RangeError, both escaping a datagram-receive path where an exception is
    // a remotely-triggerable crash.
    if (id.layerCount < 1 || id.layerIndex >= id.layerCount) {
      malformedDatagrams++;
      onDropped?.call(objectId, CliffFreeDropReason.malformedAddress);
      return null;
    }

    // A second stream that reuses an objectId with a DIFFERENT layerCount
    // would have the reassembler keep the first count while render events
    // reported the second — two disagreeing numbers handed to the UI, and a
    // usable-prefix that can exceed the reported total. Reachable in normal
    // operation, because object ids wrap at 0xFFFF.
    final existingCount = _layerCountByObject[objectId];
    if (existingCount != null && existingCount != id.layerCount) {
      malformedDatagrams++;
      onDropped?.call(objectId, CliffFreeDropReason.malformedAddress);
      return null;
    }

    // Make room BEFORE inserting, and never inside putIfAbsent's callback:
    // mutating the map during its own putIfAbsent is outside the documented
    // contract, and evicting after insertion can evict the object just added.
    if (!_byObject.containsKey(objectId)) _evictIfNeeded();

    final reassembler = _byObject.putIfAbsent(objectId, () {
      _order.add(objectId);
      _typeByObject[objectId] = type;
      _layerCountByObject[objectId] = id.layerCount;
      return CliffFreeReassembler(layerCount: id.layerCount);
    });

    final before = reassembler.usableLayerCount;
    reassembler.addDatagram(id.layerIndex, datagram);
    final after = reassembler.usableLayerCount;

    // Freshness for the LRU: an object receiving symbols is alive, and
    // evicting it in favour of one that has been idle is how a loaded inbox
    // stops completing anything at all.
    if (_order.length > 1 && _order.last != objectId) {
      _order
        ..remove(objectId)
        ..add(objectId);
    }

    if (after == before) return null;

    return CliffFreeRenderEvent(
      objectId: objectId,
      type: _typeByObject[objectId] ?? type,
      usableLayers: after,
      layerCount: id.layerCount,
      bytes: reassembler.usableBytes(),
      isComplete: reassembler.isComplete,
    );
  }

  /// Drops an object's decoders once the caller has consumed it.
  void release(int objectId) {
    _byObject.remove(objectId);
    _typeByObject.remove(objectId);
    _layerCountByObject.remove(objectId);
    _order.remove(objectId);
  }

  /// Frees every COMPLETED object.
  ///
  /// Exists because forgetting `release` is the default: a completed object
  /// keeps its fully decoded bytes resident until something pushes it out, and
  /// under load those idle completions are what evict objects still in flight.
  /// A caller that renders on completion can call this instead of tracking ids.
  int releaseCompleted() {
    final done = [
      for (final e in _byObject.entries)
        if (e.value.isComplete) e.key,
    ];
    for (final id in done) {
      release(id);
    }
    return done.length;
  }

  int get openObjects => _byObject.length;

  bool isComplete(int objectId) => _byObject[objectId]?.isComplete ?? false;

  /// Frees a slot, preferring a COMPLETED object over one still in flight.
  ///
  /// The original swept strictly oldest-first, which under sustained load
  /// evicted the object currently being received in favour of one that had
  /// already finished — so a new arrival killed an in-progress transfer, that
  /// transfer restarted from zero rank on its next symbol, and with more than
  /// [maxConcurrentObjects] in flight nothing ever completed. Completed
  /// objects are dead weight; unfinished ones are work in progress.
  void _evictIfNeeded() {
    while (_order.length >= maxConcurrentObjects) {
      final completed = _order.firstWhere(
        (id) => _byObject[id]?.isComplete ?? false,
        orElse: () => -1,
      );
      final victim = completed != -1 ? completed : _order.first;
      final wasComplete = _byObject[victim]?.isComplete ?? false;
      _order.remove(victim);
      _byObject.remove(victim);
      _typeByObject.remove(victim);
      _layerCountByObject.remove(victim);
      evictedObjects++;
      // Only an UNFINISHED object is a loss worth telling the caller about;
      // reclaiming a completed one is housekeeping.
      if (!wasComplete) {
        onDropped?.call(victim, CliffFreeDropReason.evicted);
      }
    }
  }
}
