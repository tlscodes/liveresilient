/// Delay-tolerant store-and-forward bundle queue (the RFC 9171 Bundle
/// Protocol pattern, in pure Dart).
///
/// When no live transport is available, outgoing payloads are held here as
/// *bundles* and released, in priority then arrival order, the moment a
/// transport comes up — the standard store-carry-forward model for
/// intermittently connected networks. This is the durable-queue layer the
/// graceful-degradation ladder falls back to once even the low-rate voice
/// floor and the reliable outbox cannot reach the peer directly.
///
/// This class owns ONLY the scheduling policy: priority ordering, lifetime
/// expiry, de-duplication, and bounded-capacity shedding (lowest priority,
/// then oldest, dropped first — mirroring [MeshMessagePriority] shedding in
/// this package). Persistence is a seam ([BundleStore]); the in-memory
/// store ships here, a disk/SQLite store is the app's platform concern. The
/// payload is opaque bytes — expected to already be end-to-end ciphertext,
/// so a carrier that store-and-forwards a bundle never learns its content.
library;

import 'dart:collection';

import 'mesh_flow_control.dart' show MeshMessagePriority;

/// One stored bundle awaiting a transport.
class DtnBundle {
  DtnBundle({
    required this.id,
    required this.payload,
    required this.priority,
    required this.createdAtMs,
    required this.lifetimeMs,
  }) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    if (payload.isEmpty) {
      throw ArgumentError.value(payload, 'payload', 'must not be empty');
    }
    if (createdAtMs < 0) {
      throw ArgumentError.value(createdAtMs, 'createdAtMs', 'must be >= 0');
    }
    if (lifetimeMs <= 0) {
      throw ArgumentError.value(lifetimeMs, 'lifetimeMs', 'must be > 0');
    }
  }

  /// De-duplication key: a bundle with an id already stored (and not yet
  /// expired) is ignored on re-offer.
  final String id;

  /// Opaque bytes to deliver — expected to be end-to-end ciphertext.
  final List<int> payload;

  final MeshMessagePriority priority;

  /// Creation time on the caller's clock.
  final int createdAtMs;

  /// How long, from [createdAtMs], the bundle is worth delivering. Past
  /// this it is dropped undelivered (RFC 9171 bundle lifetime).
  final int lifetimeMs;

  int get expiresAtMs => createdAtMs + lifetimeMs;

  bool isExpiredAt(int nowMs) => nowMs >= expiresAtMs;

  int get sizeBytes => payload.length;
}

/// Persistence seam for the queue. The default is in-memory; a durable
/// implementation (disk/SQLite) survives an app restart and is supplied by
/// the platform layer. Implementations need not be ordered — the queue
/// applies its own priority/arrival ordering over [values].
abstract interface class BundleStore {
  void put(DtnBundle bundle);
  void remove(String id);
  bool contains(String id);
  Iterable<DtnBundle> values();
  int get length;
}

/// Insertion-ordered in-memory [BundleStore]. Non-durable: cleared on
/// restart. Good for tests and best-effort forwarding within one session.
class InMemoryBundleStore implements BundleStore {
  final LinkedHashMap<String, DtnBundle> _bundles =
      LinkedHashMap<String, DtnBundle>();

  @override
  void put(DtnBundle bundle) => _bundles[bundle.id] = bundle;

  @override
  void remove(String id) => _bundles.remove(id);

  @override
  bool contains(String id) => _bundles.containsKey(id);

  @override
  Iterable<DtnBundle> values() => _bundles.values;

  @override
  int get length => _bundles.length;
}

/// The outcome of offering a bundle to the queue.
enum BundleAdmission {
  /// Stored, awaiting a transport.
  stored,

  /// Already present (same id, not expired) — ignored.
  duplicate,

  /// Already past its lifetime at offer time — not stored.
  expired,

  /// The queue was at capacity and this bundle was not important enough to
  /// evict an existing one — dropped.
  rejectedFull,
}

/// Delivers one bundle over whatever transport is currently up. Returns
/// true when the bundle was handed off (and may be removed from the store);
/// false leaves it queued for a later attempt.
typedef BundleForwarder = Future<bool> Function(DtnBundle bundle);

/// The store-and-forward scheduler.
class DtnBundleQueue {
  DtnBundleQueue({
    BundleStore? store,
    this.maxBundles = 1024,
    this.maxBytes = 8 * 1024 * 1024,
  }) : _store = store ?? InMemoryBundleStore() {
    if (maxBundles < 1) {
      throw ArgumentError.value(maxBundles, 'maxBundles', 'must be >= 1');
    }
    if (maxBytes < 1) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'must be >= 1');
    }
  }

  final BundleStore _store;

  /// Upper bound on stored bundles; beyond it the least-important, then
  /// oldest, bundle is evicted to make room (never a higher-priority one).
  final int maxBundles;

  /// Upper bound on total stored payload bytes, enforced the same way.
  final int maxBytes;

  int _storedBytes = 0;

  int get pendingCount => _store.length;
  int get pendingBytes => _storedBytes;

  /// Offers a bundle for eventual delivery. Expired-on-arrival and
  /// duplicate bundles are not stored. When full, the bundle is stored only
  /// if it can evict a strictly-less-important (or equally-important but
  /// older) existing bundle.
  BundleAdmission offer(DtnBundle bundle, {required int nowMs}) {
    if (bundle.isExpiredAt(nowMs)) return BundleAdmission.expired;
    if (_store.contains(bundle.id)) return BundleAdmission.duplicate;

    _dropExpired(nowMs);

    while (_isOverCapacity(bundle)) {
      final victim = _evictionCandidate(incoming: bundle);
      if (victim == null) return BundleAdmission.rejectedFull;
      _removeBundle(victim);
    }

    _store.put(bundle);
    _storedBytes += bundle.sizeBytes;
    return BundleAdmission.stored;
  }

  bool _isOverCapacity(DtnBundle incoming) =>
      _store.length + 1 > maxBundles ||
      _storedBytes + incoming.sizeBytes > maxBytes;

  /// The bundle to evict for [incoming]: the lowest priority, breaking ties
  /// by oldest. Returns null when every stored bundle is strictly more
  /// important than [incoming] (so [incoming] itself is refused instead).
  DtnBundle? _evictionCandidate({required DtnBundle incoming}) {
    DtnBundle? worst;
    for (final b in _store.values()) {
      if (worst == null ||
          b.priority.index < worst.priority.index ||
          (b.priority.index == worst.priority.index &&
              b.createdAtMs < worst.createdAtMs)) {
        worst = b;
      }
    }
    if (worst == null) return null;
    // Only evict for an incoming bundle that is at least as important as the
    // weakest resident; otherwise the incoming one is the one to drop.
    if (incoming.priority.index < worst.priority.index) return null;
    return worst;
  }

  void _removeBundle(DtnBundle bundle) {
    _store.remove(bundle.id);
    _storedBytes -= bundle.sizeBytes;
  }

  void _dropExpired(int nowMs) {
    final expired = _store
        .values()
        .where((b) => b.isExpiredAt(nowMs))
        .toList(growable: false);
    for (final b in expired) {
      _removeBundle(b);
    }
  }

  /// Drops every expired bundle; returns how many were removed. Call
  /// periodically so a long-offline queue does not hold dead bundles.
  int purgeExpired(int nowMs) {
    final before = _store.length;
    _dropExpired(nowMs);
    return before - _store.length;
  }

  /// Bundles in delivery order: highest priority first, oldest first within
  /// a priority, expired ones excluded.
  List<DtnBundle> pendingInDeliveryOrder(int nowMs) {
    final live = _store.values().where((b) => !b.isExpiredAt(nowMs)).toList();
    live.sort((a, b) {
      final byPriority = b.priority.index.compareTo(a.priority.index);
      if (byPriority != 0) return byPriority;
      return a.createdAtMs.compareTo(b.createdAtMs);
    });
    return live;
  }

  /// Attempts to flush the queue through [forward] when a transport is up.
  /// Delivers in priority/arrival order; a bundle that forwards is removed,
  /// one that fails stops the flush (the transport just went down again) and
  /// stays queued. A [forward] call that *throws* counts as a failed
  /// hand-off too — the throwing bundle and everything after it stay queued
  /// for a later attempt, exactly as if it had returned false; the
  /// exception is swallowed here, not rethrown. Expired bundles are
  /// dropped, not delivered. Returns the number of bundles successfully
  /// forwarded.
  Future<int> flush(BundleForwarder forward, {required int nowMs}) async {
    _dropExpired(nowMs);
    var delivered = 0;
    for (final bundle in pendingInDeliveryOrder(nowMs)) {
      if (bundle.isExpiredAt(nowMs)) continue;
      bool ok;
      try {
        ok = await forward(bundle);
      } catch (_) {
        ok = false;
      }
      if (!ok) break;
      _removeBundle(bundle);
      delivered++;
    }
    return delivered;
  }
}
