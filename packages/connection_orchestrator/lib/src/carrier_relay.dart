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
    this.copies = 1,
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

  /// Spray-and-wait copy budget: how many replicas this custodian may
  /// still spawn. 1 = wait phase (direct-to-destination only); >1 =
  /// spray phase (may hand half the budget to another relay). Bounds
  /// total replication to the initial budget regardless of topology.
  final int copies;

  bool expired(int nowMs) => nowMs - acceptedAtMs >= lifetimeMs;

  CustodyBundle nextHop(int nowMs, {int? copies}) => CustodyBundle(
    bundleId: bundleId,
    destination: destination,
    payload: payload,
    acceptedAtMs: nowMs,
    lifetimeMs: lifetimeMs - (nowMs - acceptedAtMs),
    hopCount: hopCount + 1,
    copies: copies ?? this.copies,
  );

  Map<String, Object?> toJson() => {
    'bundleId': bundleId,
    'destination': destination,
    'payload': payload,
    'acceptedAtMs': acceptedAtMs,
    'lifetimeMs': lifetimeMs,
    'hopCount': hopCount,
    'copies': copies,
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
      copies: json['copies'] is int ? json['copies']! as int : 1,
    );
  }
}

/// Why the relay refused custody.
enum CustodyRefusal { duplicate, expired, storeFull, tooManyHops, peerQuota }

/// The custody store: bounded, expiring, duplicate-safe.
class CarrierRelay {
  CarrierRelay({
    this.capacityBundles = 200,
    this.capacityBytes = 8 * 1024 * 1024,
    this.maxHops = 8,
    this.maxAcceptPerPeer = 50,
    this.maxSeenIds = 10000,
  });

  /// Bounded so relaying for others can never exhaust this device.
  final int capacityBundles;
  final int capacityBytes;

  /// Loop/flood guard: a bundle that hopped this many times stops here.
  final int maxHops;

  /// Fairness/flood guard: one chatty peer cannot fill the whole store —
  /// custody is shared across everyone we meet.
  final int maxAcceptPerPeer;

  /// Cap on the dedup/summary vector, so a device that relays for months
  /// does not grow one entry per bundle it has ever touched.
  final int maxSeenIds;

  final Map<String, CustodyBundle> _held = {};

  // Insertion-ordered: ids ever accepted or handed over, oldest first.
  final Set<String> _seen = {};
  final Map<String, int> _acceptedFromPeer = {};

  int get heldCount => _held.length;
  int get heldBytes => _held.values.fold(0, (a, b) => a + b.payload.length);

  /// Offers a bundle for custody. Returns null on acceptance, or the
  /// refusal reason (the offering peer keeps custody on refusal).
  /// [fromPeer] enables the per-peer fairness quota when known.
  CustodyRefusal? accept(
    CustodyBundle bundle, {
    required int nowMs,
    String? fromPeer,
  }) {
    if (_seen.contains(bundle.bundleId)) return CustodyRefusal.duplicate;
    if (bundle.expired(nowMs)) return CustodyRefusal.expired;
    if (bundle.hopCount >= maxHops) return CustodyRefusal.tooManyHops;
    if (fromPeer != null &&
        (_acceptedFromPeer[fromPeer] ?? 0) >= maxAcceptPerPeer) {
      return CustodyRefusal.peerQuota;
    }
    if (_held.length >= capacityBundles ||
        heldBytes + bundle.payload.length > capacityBytes) {
      return CustodyRefusal.storeFull;
    }
    _held[bundle.bundleId] = bundle;
    _rememberSeen(bundle.bundleId);
    if (fromPeer != null) {
      _acceptedFromPeer[fromPeer] = (_acceptedFromPeer[fromPeer] ?? 0) + 1;
    }
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

  /// Spray-and-wait contact plan for a peer that is NOT a bundle's final
  /// destination but can carry it onward.
  ///
  ///  - Only bundles still in the spray phase (copies > 1) are offered.
  ///  - [peerSeenIds] is the peer's summary vector: ids it already has or
  ///    delivered — those are filtered out, so meeting the same relay
  ///    twice moves zero redundant bytes.
  ///  - At most [maxPerContact] bundles per contact (a brief encounter
  ///    hands over the oldest, most-copied few, not the whole store).
  List<CustodyBundle> sprayPlanFor(
    Set<String> peerSeenIds, {
    required int nowMs,
    int maxPerContact = 10,
  }) {
    prune(nowMs: nowMs);
    final candidates =
        _held.values
            .where((b) => b.copies > 1 && !peerSeenIds.contains(b.bundleId))
            .toList()
          ..sort((a, b) {
            final byCopies = b.copies.compareTo(a.copies);
            return byCopies != 0
                ? byCopies
                : a.acceptedAtMs.compareTo(b.acceptedAtMs);
          });
    return candidates.take(maxPerContact).toList();
  }

  /// Executes one spray handover: binary split of the copy budget — the
  /// peer receives floor(copies/2) and this store keeps the rest, so the
  /// original budget bounds total replicas across the whole network.
  /// Returns the bundle to give the peer.
  CustodyBundle spraySplit(String bundleId, {required int nowMs}) {
    final held = _held[bundleId];
    if (held == null || held.copies <= 1) {
      throw StateError('bundle $bundleId is not in the spray phase');
    }
    final give = held.copies ~/ 2;
    _held[bundleId] = CustodyBundle(
      bundleId: held.bundleId,
      destination: held.destination,
      payload: held.payload,
      acceptedAtMs: held.acceptedAtMs,
      lifetimeMs: held.lifetimeMs,
      hopCount: held.hopCount,
      copies: held.copies - give,
    );
    return held.nextHop(nowMs, copies: give);
  }

  /// This store's summary vector — everything it has or has ever had —
  /// sent to a peer so THEIR spray plan skips what we already carry.
  Set<String> summaryVector() => Set.unmodifiable(_seen);

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

  /// Reloads persisted custody. Storage is not trusted to have been
  /// written by this build: a file from a higher-capacity version, or a
  /// tampered one, would otherwise push the store permanently past the
  /// bounds this class advertises. Every row therefore passes the same
  /// capacity and hop gates as a live [accept]; rows beyond them are
  /// dropped. Returns how many bundles were actually restored.
  int restore(Object? json, {required int nowMs}) {
    if (json is! List) return 0;
    var restored = 0;
    for (final row in json) {
      final b = CustodyBundle.fromJson(row);
      if (b == null || b.expired(nowMs)) continue;
      if (b.hopCount >= maxHops) continue;
      if (_held.containsKey(b.bundleId)) continue;
      if (_held.length >= capacityBundles ||
          heldBytes + b.payload.length > capacityBytes) {
        continue;
      }
      _held[b.bundleId] = b;
      _rememberSeen(b.bundleId);
      restored++;
    }
    return restored;
  }

  /// Records a bundle id in the dedup vector, evicting the oldest ids
  /// once the vector is full. Without the cap a long-lived carrier that
  /// meets many peers accumulates every id it has ever touched for the
  /// life of the process; the trade is that an id evicted from the
  /// vector can be accepted a second time, which the hop and expiry
  /// gates still bound.
  void _rememberSeen(String bundleId) {
    if (_seen.contains(bundleId)) return;
    _seen.add(bundleId);
    while (_seen.length > maxSeenIds) {
      _seen.remove(_seen.first);
    }
  }
}
