/// Topology: which addresses a client is allowed to know.
///
/// The concealment property this file enforces is a *negative* one, and it
/// is only worth as much as its weakest holder: the origin address must
/// never reach a client build, a client config file, or a client log. A
/// single leaked origin address ends the concealment permanently — the
/// address cannot be un-learned, and rotating it means rebuilding the
/// deployment. So the rule is checked mechanically here rather than left
/// to review:
///
/// * [EdgeBridgeTopology] is the client-side view. It holds edge nodes and
///   has no field capable of holding an origin address.
/// * [EdgeRelayTopology] is the relay-side view. It holds both, and only
///   ever exists in the relay process.
/// * [EdgeBridgeTopology.fromConfig] rejects a config that names an origin,
///   so a mis-shipped relay config fails loudly at startup instead of
///   quietly turning every client into a beacon for it.
///
/// What this cannot do is stop traffic analysis from correlating an edge
/// node with the origin it fronts: an observer positioned to watch both
/// links sees the timing relationship regardless. This layer conceals the
/// address, not the association.
library;

import 'dart:math';

import 'package:clock/clock.dart';

/// A client config that names something a client must not know.
class TopologyViolation implements Exception {
  const TopologyViolation(this.message);

  final String message;

  @override
  String toString() => 'TopologyViolation: $message';
}

/// One edge relay node a client may connect to.
class EdgeRelayNode {
  EdgeRelayNode({required this.endpoint, this.region, this.priority = 0});

  /// Parses `host:port`, `host`, or a full URL. A bare authority is read
  /// as HTTPS on 443, which is the only shape an edge node should have.
  factory EdgeRelayNode.parse(
    String value, {
    String? region,
    int priority = 0,
  }) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const TopologyViolation('empty edge node address');
    }
    final uri = trimmed.contains('://')
        ? Uri.parse(trimmed)
        : Uri.parse('https://$trimmed');
    if (uri.host.isEmpty) {
      throw TopologyViolation('edge node "$value" has no host');
    }
    return EdgeRelayNode(
      endpoint: uri.hasPort ? uri : uri.replace(port: 443),
      region: region,
      priority: priority,
    );
  }

  final Uri endpoint;

  /// Optional grouping label, used only to prefer nearby nodes.
  final String? region;

  /// Lower sorts first among equally healthy nodes.
  final int priority;

  String get authority => '${endpoint.host}:${endpoint.port}';

  @override
  String toString() =>
      'EdgeRelayNode($authority'
      '${region == null ? '' : ', $region'})';

  @override
  bool operator ==(Object other) =>
      other is EdgeRelayNode && other.endpoint == endpoint;

  @override
  int get hashCode => endpoint.hashCode;
}

/// The client-side topology. There is deliberately no origin field.
class EdgeBridgeTopology {
  EdgeBridgeTopology({required List<EdgeRelayNode> nodes})
    : nodes = List<EdgeRelayNode>.unmodifiable(nodes) {
    if (nodes.isEmpty) {
      throw const TopologyViolation('a client needs at least one edge node');
    }
  }

  /// Builds from a parsed config map, refusing any key that would carry an
  /// origin address into a client.
  ///
  /// The check is on the *keys*, not on their values: a config that names
  /// an origin at all is a relay config, and a relay config in a client
  /// build is a shipping mistake worth failing on.
  factory EdgeBridgeTopology.fromConfig(Map<String, Object?> config) {
    for (final key in config.keys) {
      final lower = key.toLowerCase();
      if (lower.contains('origin') || lower.contains('upstreamserver')) {
        throw TopologyViolation(
          'client config carries "$key"; the origin address must never '
          'reach a client build',
        );
      }
    }
    final raw = config['edgeBridgeNodes'];
    if (raw is! List || raw.isEmpty) {
      throw const TopologyViolation('edgeBridgeNodes must be a non-empty list');
    }
    return EdgeBridgeTopology(
      nodes: [for (final entry in raw) EdgeRelayNode.parse(entry.toString())],
    );
  }

  final List<EdgeRelayNode> nodes;

  List<Uri> get endpoints => [for (final node in nodes) node.endpoint];
}

/// The relay-side topology: edge nodes plus the origin they front.
///
/// Instantiating this in a client process is the mistake the type system
/// is here to make visible — it is exported so a relay can use it, and
/// named so its presence in a client dependency graph is obvious.
class EdgeRelayTopology {
  EdgeRelayTopology({required this.origin, required List<EdgeRelayNode> peers})
    : peers = List<EdgeRelayNode>.unmodifiable(peers);

  /// Where authorized sessions are forwarded. Relay-process only.
  final Uri origin;

  /// Sibling edge nodes, for cross-referral.
  final List<EdgeRelayNode> peers;

  /// The client-facing view of this topology, with the origin removed.
  /// This is the only supported way to derive a client config from a
  /// relay one.
  EdgeBridgeTopology get clientView => EdgeBridgeTopology(nodes: peers);
}

/// Per-node health, with exponential backoff on consecutive failures.
class EdgeNodeHealth {
  EdgeNodeHealth({required this.node});

  final EdgeRelayNode node;

  int consecutiveFailures = 0;
  DateTime? lastSuccess;
  DateTime? backoffUntil;

  /// Whether the node may be tried right now.
  bool get eligible {
    final until = backoffUntil;
    return until == null || !clock.now().isBefore(until);
  }

  @override
  String toString() =>
      'EdgeNodeHealth(${node.authority}, '
      'failures: $consecutiveFailures, eligible: $eligible)';
}

/// Discovers edge nodes at runtime — a signed config fetch, a DNS lookup,
/// whatever the deployment uses. Returning an empty list means "no change".
typedef EdgeNodeDiscovery = Future<List<EdgeRelayNode>> Function();

/// Tracks which edge nodes are worth trying, in what order.
///
/// Ordering is by fewest consecutive failures, then by declared priority,
/// then round-robin — so a node that just failed is not retried first, a
/// recovered node re-enters service without an explicit reset, and no
/// single node carries a whole call.
class EdgeNodeDirectory {
  EdgeNodeDirectory({
    required EdgeBridgeTopology topology,
    this.minBackoff = const Duration(seconds: 5),
    this.maxBackoff = const Duration(minutes: 2),
    this.discovery,
  }) {
    for (final node in topology.nodes) {
      _health[node.authority] = EdgeNodeHealth(node: node);
    }
  }

  /// Floor of the per-node backoff, doubling per consecutive failure.
  final Duration minBackoff;

  /// Ceiling of that backoff. A node is never dropped permanently: a
  /// blocked edge often becomes reachable again, and forgetting it would
  /// shrink the pool every time the network misbehaves.
  final Duration maxBackoff;

  final EdgeNodeDiscovery? discovery;

  final Map<String, EdgeNodeHealth> _health = {};
  int _rotation = 0;

  /// Every known node's health, in insertion order.
  List<EdgeNodeHealth> get health => List.unmodifiable(_health.values);

  /// Nodes currently outside their backoff window.
  List<EdgeRelayNode> get eligibleNodes => [
    for (final entry in _health.values)
      if (entry.eligible) entry.node,
  ];

  /// The order to try nodes in, best first. Never empty while any node is
  /// known: if every node is backing off, the least-recently-failed one is
  /// offered anyway, because refusing to try at all is worse than trying
  /// early.
  List<EdgeRelayNode> get preferredOrder {
    final entries = _health.values.toList();
    if (entries.isEmpty) return const [];
    entries.sort((a, b) {
      if (a.eligible != b.eligible) return a.eligible ? -1 : 1;
      final byFailures = a.consecutiveFailures.compareTo(b.consecutiveFailures);
      if (byFailures != 0) return byFailures;
      return a.node.priority.compareTo(b.node.priority);
    });
    // Rotate within the leading group of equally-ranked nodes so calls
    // spread across the pool instead of stacking on one node.
    final leadFailures = entries.first.consecutiveFailures;
    final leadEligible = entries.first.eligible;
    final lead = entries
        .where(
          (e) =>
              e.eligible == leadEligible &&
              e.consecutiveFailures == leadFailures,
        )
        .toList();
    final rest = entries.where((e) => !lead.contains(e)).toList();
    final offset = lead.isEmpty ? 0 : _rotation % lead.length;
    final rotated = [...lead.sublist(offset), ...lead.sublist(0, offset)];
    return [
      for (final entry in [...rotated, ...rest]) entry.node,
    ];
  }

  /// Endpoints in [preferredOrder], ready to hand to a lane.
  List<Uri> get preferredEndpoints => [
    for (final node in preferredOrder) node.endpoint,
  ];

  /// Advances the round-robin cursor. Called once per connect attempt.
  void advanceRotation() => _rotation++;

  /// Marks [node] healthy, clearing its backoff.
  void recordSuccess(EdgeRelayNode node) {
    final entry = _health[node.authority];
    if (entry == null) return;
    entry.consecutiveFailures = 0;
    entry.backoffUntil = null;
    entry.lastSuccess = clock.now();
  }

  /// Marks [node] failed and pushes its next attempt out exponentially.
  void recordFailure(EdgeRelayNode node) {
    final entry = _health[node.authority];
    if (entry == null) return;
    entry.consecutiveFailures++;
    var micros = minBackoff.inMicroseconds;
    for (var i = 1; i < entry.consecutiveFailures; i++) {
      micros *= 2;
      if (micros >= maxBackoff.inMicroseconds) {
        micros = maxBackoff.inMicroseconds;
        break;
      }
    }
    entry.backoffUntil = clock.now().add(
      Duration(microseconds: min(micros, maxBackoff.inMicroseconds)),
    );
  }

  /// Current backoff for [node], or null when it is not backing off.
  Duration? backoffOf(EdgeRelayNode node) {
    final until = _health[node.authority]?.backoffUntil;
    if (until == null) return null;
    final remaining = until.difference(clock.now());
    return remaining.isNegative ? null : remaining;
  }

  /// Runs [discovery] and folds the result in: new nodes are added with
  /// clean health, known nodes keep theirs (a rediscovered node that has
  /// been failing has not thereby been fixed), and nodes absent from the
  /// result are removed.
  ///
  /// Returns the number of nodes added.
  Future<int> refreshDiscovery() async {
    final discover = discovery;
    if (discover == null) return 0;
    final discovered = await discover();
    if (discovered.isEmpty) return 0;

    var added = 0;
    final seen = <String>{};
    for (final node in discovered) {
      seen.add(node.authority);
      if (_health.containsKey(node.authority)) continue;
      _health[node.authority] = EdgeNodeHealth(node: node);
      added++;
    }
    _health.removeWhere((authority, _) => !seen.contains(authority));
    return added;
  }
}
