/// End-to-end delivery ledger: which bundle ids were confirmed delivered
/// and which were received, so reconnection never double-sends and never
/// double-shows — the bookkeeping that makes multi-path + store-and-
/// forward + relay look like one reliable pipe.
library;

/// Bounded, persistable set of confirmed bundle ids (send or receive
/// side — one instance per direction).
class DeliveryLedger {
  DeliveryLedger({this.capacity = 5000});

  /// Oldest entries are evicted beyond this bound.
  final int capacity;

  // Insertion-ordered so eviction drops the oldest confirmations.
  final Set<String> _ids = <String>{};

  int get count => _ids.length;

  /// Records a confirmation. Returns true when newly recorded, false when
  /// it was already known (i.e. a duplicate).
  bool record(String bundleId) {
    if (_ids.contains(bundleId)) return false;
    _ids.add(bundleId);
    if (_ids.length > capacity) {
      _ids.remove(_ids.first);
    }
    return true;
  }

  /// True when [bundleId] was already confirmed — receivers use this to
  /// drop duplicates from dual-send/replicate/relay paths silently.
  bool isDuplicate(String bundleId) => _ids.contains(bundleId);

  List<String> toJson() => _ids.toList();

  void restore(Object? json) {
    if (json is! List) return;
    for (final id in json) {
      if (id is String) record(id);
    }
  }
}
