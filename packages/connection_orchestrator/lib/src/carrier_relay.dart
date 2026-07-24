/// Store-carry-forward custody relay: this device can carry bundles that
/// are destined for someone else, hold them durably, and hand them over
/// on any future contact — the delay-tolerant-networking custody model
/// that makes delivery work even with NO end-to-end path at any moment.
///
/// Implements the [LaneKind.carrier] semantics: a phone that met the
/// sender at noon and meets the recipient at night IS the network.
library;

/// One bundle held in custody for a destination that is not this device.
class CustodyBundle {
  const CustodyBundle({
    required this.bundleId,
    required this.destination,
    required this.payload,
    required this.acceptedAtMs,
    required this.lifetimeMs,
    this.hopCount = 0,
  });

  final String bundleId;

  /// Opaque destination identity (peer id / route tag) — the relay only
  /// matches it against contacts, never interprets it.
  final String destination;
  final List<int> payload;
  final int acceptedAtMs;
  final int lifetimeMs;

  /// How many custody transfers this bundle has already made.
  final int hopCount;

  bool expired(int nowMs) => nowMs - acceptedAtMs >= lifetimeMs;

  CustodyBundle nextHop(int nowMs) => CustodyBundle(
    bundleId: bundleId,
    destination: destination,
    payload: payload,
    acceptedAtMs: nowMs,
    lifetimeMs: lifetimeMs - (nowMs - acceptedAtMs),
    hopCount: hopCount + 1,
  );

  Map<String, Object?> toJson() => {
    'bundleId': bundleId,
    'destination': destination,
    'payload': payload,
    'acceptedAtMs': acceptedAtMs,
    'lifetimeMs': lifetimeMs,
    'hopCount': hopCount,
  };

  static CustodyBundle? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['bundleId'], dest = json['destination'];
    final payload = json['payload'], at = json['acceptedAtMs'];
    final life = json['lifetimeMs'];
    if (id is! String || dest is! String || payload is! List) return null;
    if (at is! int || life is! int) return null;
    return CustodyBundle(
      bundleId: id,
      destination: dest,
      payload: payload.whereType<int>().toList(),
      acceptedAtMs: at,
      lifetimeMs: life,
      hopCount: json['hopCount'] is int ? json['hopCount']! as int : 0,
    );
  }
}

/// Why the relay refused custody.
enum CustodyRefusal { duplicate, expired, storeFull, tooManyHops }

/// The custody store: bounded, expiring, duplicate-safe.
class CarrierRelay {
  CarrierRelay({
    this.capacityBundles = 200,
    this.capacityBytes = 8 * 1024 * 1024,
    this.maxHops = 8,
  });

  /// Bounded so relaying for others can never exhaust this device.
  final int capacityBundles;
  final int capacityBytes;

  /// Loop/flood guard: a bundle that hopped this many times stops here.
  final int maxHops;

  final Map<String, CustodyBundle> _held = {};
  final Set<String> _seen = {}; // ids ever accepted or handed over

  int get heldCount => _held.length;
  int get heldBytes =>
      _held.values.fold(0, (a, b) => a + b.payload.length);

  /// Offers a bundle for custody. Returns null on acceptance, or the
  /// refusal reason (the offering peer keeps custody on refusal).
  CustodyRefusal? accept(CustodyBundle bundle, {required int nowMs}) {
    if (_seen.contains(bundle.bundleId)) return CustodyRefusal.duplicate;
    if (bundle.expired(nowMs)) return CustodyRefusal.expired;
    if (bundle.hopCount >= maxHops) return CustodyRefusal.tooManyHops;
    if (_held.length >= capacityBundles ||
        heldBytes + bundle.payload.length > capacityBytes) {
      return CustodyRefusal.storeFull;
    }
    _held[bundle.bundleId] = bundle;
    _seen.add(bundle.bundleId);
    return null;
  }

  /// Bundles to hand over on contact with [peerDestination] — exact
  /// destination matches, oldest first (fairness: longest-carried wins).
  List<CustodyBundle> bundlesFor(String peerDestination, {required int nowMs}) {
    prune(nowMs: nowMs);
    final matches =
        _held.values.where((b) => b.destination == peerDestination).toList()
          ..sort((a, b) => a.acceptedAtMs.compareTo(b.acceptedAtMs));
    return matches;
  }

  /// Marks a handover complete: custody moves to the next carrier (or the
  /// final recipient), and this store frees the space.
  void handedOver(String bundleId) => _held.remove(bundleId);

  /// Drops expired bundles; returns how many were dropped.
  int prune({required int nowMs}) {
    final expired = [
      for (final b in _held.values)
        if (b.expired(nowMs)) b.bundleId,
    ];
    expired.forEach(_held.remove);
    return expired.length;
  }

  /// Full persisted form (the app writes this through its storage seam).
  List<Map<String, Object?>> toJson() => [
    for (final b in _held.values) b.toJson(),
  ];

  void restore(Object? json, {required int nowMs}) {
    if (json is! List) return;
    for (final row in json) {
      final b = CustodyBundle.fromJson(row);
      if (b != null && !b.expired(nowMs)) {
        _held[b.bundleId] = b;
        _seen.add(b.bundleId);
      }
    }
  }
}
