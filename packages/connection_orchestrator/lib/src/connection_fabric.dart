/// The connectivity fabric: one owner for every lane this device has.
///
/// Design in one paragraph: callers hand the fabric a payload once and the
/// fabric guarantees forward progress — it ranks all eligible lanes by
/// cost-adjusted live health, tries them best-first, and when every live
/// lane fails it parks the payload in the delay-tolerant bundle queue.
/// Whenever a lane recovers (a later delivery or an explicit [refresh]
/// succeeds), the fabric automatically drains the queue through the best
/// lane, oldest-highest-priority first. Every change of truth is published
/// as a [ConnectivitySnapshot] on a single broadcast stream.
library;

import 'dart:async';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:device_link/device_link.dart';

import 'connectivity_snapshot.dart';
import 'delivery_planner.dart';
import 'lane.dart';
import 'lane_experience.dart';
import 'micro_learner.dart';
import 'trend_sentinel.dart';

/// How a single delivery ended.
enum DeliveryOutcome {
  /// Carried by a live lane immediately.
  sentLive,

  /// No live lane worked; parked durably for later carriage.
  queuedForLater,

  /// The queue refused the payload (duplicate id, expired, or full).
  rejected,
}

class _Lane {
  _Lane(this.channel, this.profile);

  final TransportChannel channel;
  final LaneProfile profile;

  /// Additive ranking bias seeded from long-term place memory
  /// (positive = this lane is expected to be good HERE).
  double forecastBias = 0;

  /// Cost-adjusted ranking score: live EWMA health minus a small penalty
  /// per cost rank, plus the place-forecast bias, so a cheap lane wins a
  /// near-tie and arriving somewhere familiar pre-ranks lanes before a
  /// single byte is sent.
  double score() =>
      channel.health.score() - profile.costRank * 0.05 + forecastBias;
}

/// The "mother" layer: registers lanes, delivers live-first with
/// store-and-forward fallback, drains the backlog on recovery, and
/// publishes one authoritative connectivity snapshot stream.
class ConnectionFabric {
  ConnectionFabric({
    required DtnBundleQueue fallbackQueue,
    required int Function() nowMs,
    double degradedBelowScore = 0.35,
    LaneExperience? experience,
    DeliveryPlanner planner = const DeliveryPlanner(),
    String Function()? place,
    TrendSentinel? trend,
  }) : _queue = fallbackQueue,
       _nowMs = nowMs,
       _degradedBelowScore = degradedBelowScore,
       experience = experience ?? LaneExperience(),
       _planner = planner,
       _place = place ?? (() => 'unknown'),
       trend = trend ?? TrendSentinel();

  final DtnBundleQueue _queue;
  final int Function() _nowMs;
  final double _degradedBelowScore;

  /// The fabric's learning memory: contextual success statistics per lane,
  /// fed by every delivery attempt. Injectable so the app can persist it.
  final LaneExperience experience;

  final DeliveryPlanner _planner;

  /// Coarse location tag resolver (e.g. current network label). Re-read on
  /// every delivery so movement changes the learning context immediately.
  final String Function() _place;

  /// The most recent plan the conductor produced — telemetry/UI/tests.
  DeliveryPlan? lastPlan;

  /// Proactive trend watch: every refresh feeds each lane's score in, and
  /// a best-lane projected to cross the failure floor fires the unhealthy
  /// hook BEFORE the lane actually dies.
  final TrendSentinel trend;

  final Map<String, _Lane> _lanes = {};
  final _snapshots = StreamController<ConnectivitySnapshot>.broadcast();
  final List<void Function()> _onUnhealthy = [];
  bool _disposed = false;
  ConnectivitySnapshot? _last;

  /// Single source of truth: emits after every registration change,
  /// delivery, refresh, and drain.
  Stream<ConnectivitySnapshot> get snapshots => _snapshots.stream;

  /// Latest published snapshot (computed on demand before the first emit).
  ConnectivitySnapshot get snapshot => _last ?? _compute();

  /// Registers a lane. The channel stays owned by the caller; the fabric
  /// never disposes channels it did not create.
  void registerLane(TransportChannel channel, LaneProfile profile) {
    _checkLive();
    if (_lanes.containsKey(profile.id)) {
      throw ArgumentError.value(profile.id, 'profile.id', 'lane id in use');
    }
    _lanes[profile.id] = _Lane(channel, profile);
    _publish();
  }

  /// Removes a lane; queued bundles are unaffected and will drain through
  /// whichever lanes remain.
  void unregisterLane(String id) {
    _checkLive();
    _lanes.remove(id);
    _publish();
  }

  /// Seeds lane ranking from the long-term place memory: on arriving at
  /// [place], each lane mapped to a known network gets a bias derived
  /// from its learned expected quality there (centered on 0, scaled
  /// gently so live health still dominates once real traffic flows).
  /// Unmapped/unknown lanes keep bias 0.
  void applyPlaceForecast(
    MicroLearner learner,
    String place, {
    required String Function(String laneId) networkOfLane,
  }) {
    _checkLive();
    for (final lane in _lanes.values) {
      final network = networkOfLane(lane.profile.id);
      final forecasts = learner.forecastFor(place);
      final match = forecasts.where((f) => f.networkName == network);
      lane.forecastBias = match.isEmpty
          ? 0
          : (match.first.expectedQuality - 0.5) * 0.4;
    }
    _publish();
  }

  /// Registers a callback fired whenever the fabric leaves [FabricMode.live]
  /// (e.g. wire a call controller's recovery request here).
  void onUnhealthy(void Function() callback) => _onUnhealthy.add(callback);

  /// Delivers [payload]: best eligible lane first, then the rest, then the
  /// delay-tolerant queue. Exactly one of the three outcomes happens.
  Future<DeliveryOutcome> deliver(
    List<int> payload, {
    required String bundleId,
    MeshMessagePriority priority = MeshMessagePriority.bulk,
    int lifetimeMs = 24 * 60 * 60 * 1000,
  }) async {
    _checkLive();
    final ctx = DeliveryContext.at(
      _nowMs(),
      place: _place(),
      priority: priority,
    );
    final byId = {for (final l in _ranked()) l.profile.id: l};
    // Foresight feed: if the trend watch says the current best lane is
    // heading down, the planner duplicates onto the runner-up in advance.
    final bestId = byId.isEmpty ? null : byId.keys.first;
    final bestVerdict = bestId == null
        ? TrendVerdict.unknown
        : trend.verdict(bestId);
    final plan = _planner.plan(
      lanes: [
        for (final l in byId.values)
          PlannerLaneView(
            id: l.profile.id,
            healthScore: l.channel.health.score(),
            learnedScore: experience.ucbScore(l.profile.id, ctx),
            costRank: l.profile.costRank,
          ),
      ],
      context: ctx,
      urgent: priority == MeshMessagePriority.callSignal,
      bestLaneSliding:
          bestVerdict == TrendVerdict.slipping ||
          bestVerdict == TrendVerdict.failingSoon,
    );
    lastPlan = plan;

    _Lane? successLane;
    switch (plan.strategy) {
      case DeliveryStrategy.queueOnly:
        break;
      case DeliveryStrategy.singleBest:
        // Best first with sequential failover; stop on first success.
        for (final id in plan.laneIds) {
          final lane = byId[id]!;
          if (await _attempt(lane, payload, ctx)) {
            successLane = lane;
            break;
          }
        }
      case DeliveryStrategy.raceFanout:
      case DeliveryStrategy.replicate:
        // Concurrent send on every planned lane; receivers dedupe, and
        // every lane's outcome feeds the experience model.
        final lanes = [for (final id in plan.laneIds) byId[id]!];
        final results = await Future.wait([
          for (final lane in lanes) _attempt(lane, payload, ctx),
        ]);
        for (var i = 0; i < lanes.length; i++) {
          if (results[i]) {
            successLane = lanes[i];
            break;
          }
        }
    }
    if (successLane != null) {
      // A working lane may unblock the backlog too.
      await _drainThrough(successLane);
      _publish();
      return DeliveryOutcome.sentLive;
    }
    final admission = _queue.offer(
      DtnBundle(
        id: bundleId,
        payload: payload,
        priority: priority,
        createdAtMs: _nowMs(),
        lifetimeMs: lifetimeMs,
      ),
      nowMs: _nowMs(),
    );
    _publish();
    return admission == BundleAdmission.stored
        ? DeliveryOutcome.queuedForLater
        : DeliveryOutcome.rejected;
  }

  /// Probes every registered lane, recomputes the mode, and — when an
  /// eligible lane is back — drains the queued backlog through it.
  /// Returns the number of bundles delivered from the backlog.
  Future<int> refresh() async {
    _checkLive();
    for (final lane in _lanes.values) {
      await lane.channel.probe();
    }
    var drained = 0;
    final ranked = _ranked();
    if (ranked.isNotEmpty) {
      drained = await _drainThrough(ranked.first);
    }
    // Feed the trend watch and act on the forecast: a best lane heading
    // for the floor triggers recovery while the call is still alive.
    final now = _nowMs();
    for (final lane in _lanes.values) {
      trend.observe(lane.profile.id, lane.channel.health.score(), nowMs: now);
    }
    final bestNow = ranked.isEmpty ? null : ranked.first;
    if (bestNow != null &&
        trend.verdict(bestNow.profile.id) == TrendVerdict.failingSoon) {
      for (final cb in _onUnhealthy) {
        cb();
      }
    }
    _publish();
    return drained;
  }

  /// One attempt on one lane: sends, updates live health AND the learned
  /// experience model, returns whether the payload was delivered.
  Future<bool> _attempt(
    _Lane lane,
    List<int> payload,
    DeliveryContext ctx,
  ) async {
    final result = await lane.channel.send(payload);
    lane.channel.health.observe(result);
    final delivered =
        result.status == SendStatus.ok || result.status == SendStatus.duplicate;
    experience.record(lane.profile.id, ctx, success: delivered);
    return delivered;
  }

  Future<int> _drainThrough(_Lane lane) async {
    if (_queue.pendingCount == 0) return 0;
    return _queue.flush((bundle) async {
      final result = await lane.channel.send(bundle.payload);
      lane.channel.health.observe(result);
      return result.status == SendStatus.ok ||
          result.status == SendStatus.duplicate;
    }, nowMs: _nowMs());
  }

  List<_Lane> _ranked() {
    final eligible = _lanes.values.where((l) => l.profile.eligible).toList()
      ..sort((a, b) => b.score().compareTo(a.score()));
    return eligible;
  }

  ConnectivitySnapshot _compute() {
    final ordered = _lanes.values.toList()
      ..sort((a, b) => b.score().compareTo(a.score()));
    final statuses = [
      for (final l in ordered)
        LaneStatus(
          id: l.profile.id,
          eligible: l.profile.eligible,
          score: l.score(),
        ),
    ];
    final best = _ranked().isEmpty ? null : _ranked().first;
    final FabricMode mode;
    if (_lanes.isEmpty) {
      mode = FabricMode.offline;
    } else if (best == null) {
      mode = FabricMode.storeAndForward;
    } else if (best.score() < _degradedBelowScore) {
      mode = FabricMode.degraded;
    } else {
      mode = FabricMode.live;
    }
    return ConnectivitySnapshot(
      mode: mode,
      lanes: statuses,
      bestLaneId: best?.profile.id,
      pendingBundles: _queue.pendingCount,
      atMs: _nowMs(),
    );
  }

  void _publish() {
    final next = _compute();
    final wasLive = _last?.mode == FabricMode.live;
    _last = next;
    _snapshots.add(next);
    if (wasLive && next.mode != FabricMode.live) {
      for (final cb in _onUnhealthy) {
        cb();
      }
    }
  }

  void _checkLive() {
    if (_disposed) {
      throw StateError('ConnectionFabric used after dispose');
    }
  }

  /// Closes the snapshot stream. Channels and the queue remain owned by
  /// the caller and are not touched.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _snapshots.close();
  }
}
