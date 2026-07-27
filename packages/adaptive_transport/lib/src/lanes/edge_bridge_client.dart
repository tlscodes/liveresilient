/// Client-side assembly: directory-ordered edge selection, health
/// feedback, and lane construction.
///
/// This is a policy object, not another transport. [DomesticEdgeBridgeLane]
/// already owns connection rotation, sequence-preserving failover, and its
/// own adaptive health-check backoff; re-implementing any of that here to
/// add discovery would mean two rotation policies disagreeing under load.
/// So this class does the two things the lane cannot: it decides *which*
/// endpoints the lane is given, and it feeds per-node outcomes back into
/// [EdgeNodeDirectory] so a node that fails gets an exponential penalty
/// rather than being retried at the same rate forever.
library;

import 'dart:async';

import '../probe_defense/traffic_shaper.dart';
import 'domestic_edge_bridge_lane.dart';
import 'edge_relay_topology.dart';

/// Builds a lane over the current edge pool and keeps the pool current.
class EdgeBridgeClient {
  EdgeBridgeClient({
    required this.directory,
    required EdgeBridgeConnector connector,
    this.shaper,
    this.jitter,
    this.connectTimeout = const Duration(seconds: 3),
  }) : _connector = connector;

  final EdgeNodeDirectory directory;
  final EdgeBridgeConnector _connector;

  /// Length shaping applied to every payload, or null for none.
  final TrafficShaper? shaper;

  /// Send pacing, or null for none.
  final AdaptiveJitter? jitter;

  final Duration connectTimeout;

  DomesticEdgeBridgeLane? _lane;
  List<Uri> _laneEndpoints = const [];

  /// The lane currently in service, built on first use.
  DomesticEdgeBridgeLane get lane => _lane ??= _build();

  /// The endpoint order the live lane was built with.
  List<Uri> get laneEndpoints => List.unmodifiable(_laneEndpoints);

  DomesticEdgeBridgeLane _build() {
    _laneEndpoints = directory.preferredEndpoints;
    return DomesticEdgeBridgeLane(
      endpoints: _laneEndpoints,
      connector: _instrumentedConnector,
      connectTimeout: connectTimeout,
      shaper: shaper,
      jitter: jitter,
    );
  }

  /// Wraps the caller's connector so every attempt updates node health.
  ///
  /// Health is recorded on the *connect* outcome specifically: it is the
  /// signal that distinguishes a blocked edge from a bad call, and it is
  /// the one the lane does not attribute per-node.
  Future<EdgeBridgeConnection> _instrumentedConnector(Uri endpoint) async {
    final node = _nodeFor(endpoint);
    directory.advanceRotation();
    try {
      final connection = await _connector(endpoint);
      if (node != null) directory.recordSuccess(node);
      return connection;
    } catch (_) {
      if (node != null) directory.recordFailure(node);
      rethrow;
    }
  }

  EdgeRelayNode? _nodeFor(Uri endpoint) {
    for (final entry in directory.health) {
      if (entry.node.endpoint == endpoint) return entry.node;
    }
    return null;
  }

  /// Runs discovery and rebuilds the lane when the pool has changed.
  ///
  /// Returns true when a rebuild happened. A rebuild starts a fresh
  /// session sequence, so it is deliberately *not* done on every health
  /// change — only when the set of reachable endpoints actually differs,
  /// which is what discovery is for. Mid-call rotation within the existing
  /// pool stays the lane's job and keeps the sequence intact.
  Future<bool> refresh() async {
    await directory.refreshDiscovery();
    final desired = directory.preferredEndpoints;
    if (_sameSet(desired, _laneEndpoints)) return false;

    final previous = _lane;
    _lane = null;
    _laneEndpoints = const [];
    lane; // rebuild now, so the next send does not pay for it
    await previous?.dispose();
    return true;
  }

  /// Disposes the live lane.
  Future<void> dispose() async {
    final lane = _lane;
    _lane = null;
    await lane?.dispose();
  }

  static bool _sameSet(List<Uri> a, List<Uri> b) {
    if (a.length != b.length) return false;
    final left = a.map((u) => u.toString()).toSet();
    final right = b.map((u) => u.toString()).toSet();
    return left.length == right.length && left.containsAll(right);
  }
}
