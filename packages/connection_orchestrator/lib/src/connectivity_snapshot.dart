/// The fabric's single source of truth about connectivity, published to
/// UI and drivers as one immutable value.
library;

/// Overall mode the fabric is operating in.
enum FabricMode {
  /// At least one eligible lane recently succeeded or probes healthy.
  live,

  /// Lanes exist but the best one is struggling (low health score).
  degraded,

  /// No eligible live lane: deliveries are being queued for later.
  storeAndForward,

  /// No lanes registered at all.
  offline,
}

/// One lane's view inside a snapshot.
class LaneStatus {
  const LaneStatus({
    required this.id,
    required this.eligible,
    required this.score,
  });

  final String id;

  /// False when the lane's consent is currently not granted.
  final bool eligible;

  /// Cost-adjusted health score used for ranking (higher is better).
  final double score;

  @override
  String toString() =>
      'LaneStatus($id, eligible=$eligible, score=${score.toStringAsFixed(3)})';
}

/// Immutable connectivity truth at one instant.
class ConnectivitySnapshot {
  const ConnectivitySnapshot({
    required this.mode,
    required this.lanes,
    required this.bestLaneId,
    required this.pendingBundles,
    required this.atMs,
  });

  final FabricMode mode;

  /// All registered lanes, best first.
  final List<LaneStatus> lanes;

  /// Id of the current best eligible lane, or null when none.
  final String? bestLaneId;

  /// Bundles waiting in the delay-tolerant queue.
  final int pendingBundles;

  /// Fabric clock time this snapshot was computed at.
  final int atMs;

  @override
  String toString() =>
      'ConnectivitySnapshot($mode, best=$bestLaneId, '
      'lanes=${lanes.length}, pending=$pendingBundles)';
}
