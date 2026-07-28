/// A deterministic world for testing the one thing this project actually
/// promises: that a delivery degrades instead of disappearing.
///
/// Every other test in this workspace checks a detail. This one checks the
/// claim. It builds a fabric over lanes that fail, revive, slow down, lose
/// payloads and lie about their health, drives thousands of random events
/// through it, and after every single event asserts the properties that
/// must never break.
///
/// Three design choices make it a test rather than a stress toy:
///
///  * **Seeded and reproducible.** The whole run is a pure function of one
///    integer. A failure prints the seed, and that seed replays the exact
///    same world.
///  * **Shrinking.** On failure the harness re-runs shorter and shorter
///    prefixes of the same event stream to find the smallest one that still
///    breaks, so what gets reported is a minimal counterexample rather than
///    ten thousand events with a bug somewhere in them.
///  * **Invariants, not expectations.** Nothing here asserts a particular
///    outcome. It asserts things that must hold no matter what the world
///    did — which is the only kind of check that can catch behaviour nobody
///    thought to write a test for.
library;

import 'dart:async';
import 'dart:math';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart';

/// How a lane is behaving right now.
enum LaneMood {
  /// Sends succeed.
  healthy,

  /// Sends fail cleanly. The fabric should route around it.
  failing,

  /// Sends throw. A lane that breaks rudely must not break the fabric.
  throwing,

  /// Sends report success and quietly drop the payload.
  ///
  /// The nastiest mood, and the one worth having: it is indistinguishable
  /// from success at the call site, so only end-to-end accounting catches
  /// it.
  blackHole,
}

/// A transport whose behaviour the world dictates.
class ChaosLane implements TransportChannel {
  ChaosLane(this.name, {this.latencyMs = 20});

  @override
  final String name;

  final int latencyMs;

  LaneMood mood = LaneMood.healthy;

  /// Payloads this lane really carried, in order.
  final List<List<int>> carried = [];

  /// Payloads this lane *claimed* to carry.
  ///
  /// Identical to [carried] for an honest lane, and a superset for a black
  /// hole. The distinction is the whole point: a fabric can only ever
  /// promise "handed to a lane that accepted it", because detecting a lane
  /// that lies about delivery is not possible at this layer and belongs to
  /// an end-to-end acknowledgement above it.
  final List<List<int>> claimed = [];

  int sendAttempts = 0;
  int probeCalls = 0;

  @override
  final ChannelHealth health = ChannelHealth(
    reliabilityPrior: 0.9,
    bandwidth: 0.6,
    rttMs: 20,
  );

  /// Drives the health the fabric ranks on.
  ///
  /// Health is a live measurement the channel owns, so the world sets it
  /// the same way reality would: by moving the numbers, not by replacing
  /// the object the fabric already holds.
  void setHealth({
    required bool reachable,
    int rttMs = 20,
    double availability = 1.0,
  }) {
    health
      ..pathDegraded = !reachable
      ..availability = reachable ? availability : 0.0
      ..rttMs = rttMs;
  }

  /// Whether this lane currently looks usable to the fabric.
  bool get looksReachable => !health.pathDegraded && health.availability > 0;

  @override
  Future<bool> probe() async {
    probeCalls += 1;
    return mood == LaneMood.healthy || mood == LaneMood.blackHole;
  }

  @override
  Future<SendResult> send(List<int> payload) async {
    sendAttempts += 1;
    switch (mood) {
      case LaneMood.healthy:
        carried.add(List<int>.unmodifiable(payload));
        claimed.add(List<int>.unmodifiable(payload));
        return SendResult(SendStatus.ok, rttMs: latencyMs);
      case LaneMood.failing:
        return const SendResult(SendStatus.unavailable);
      case LaneMood.throwing:
        throw StateError('$name died mid-send');
      case LaneMood.blackHole:
        // Claims success, carries nothing.
        claimed.add(List<int>.unmodifiable(payload));
        return SendResult(SendStatus.ok, rttMs: latencyMs);
    }
  }

  @override
  Future<void> dispose() async {}
}

/// One thing that happens to the world.
sealed class ChaosEvent {
  const ChaosEvent();
}

class SendPayload extends ChaosEvent {
  const SendPayload(this.index, this.priority);

  final int index;
  final LinkMessagePriority priority;

  @override
  String toString() => 'send($index, ${priority.name})';
}

class SetMood extends ChaosEvent {
  const SetMood(this.lane, this.mood);

  final int lane;
  final LaneMood mood;

  @override
  String toString() => 'mood(lane $lane -> ${mood.name})';
}

class SetHealth extends ChaosEvent {
  const SetHealth(this.lane, this.reachable, this.rttMs, this.loss);

  final int lane;
  final bool reachable;
  final int rttMs;
  final double loss;

  @override
  String toString() =>
      'health(lane $lane, reachable=$reachable, rtt=$rttMs, loss=$loss)';
}

class Refresh extends ChaosEvent {
  const Refresh();

  @override
  String toString() => 'refresh()';
}

class AdvanceClock extends ChaosEvent {
  const AdvanceClock(this.byMs);

  final int byMs;

  @override
  String toString() => 'advance(${byMs}ms)';
}

/// An invariant that broke, with everything needed to understand it.
class InvariantBreach implements Exception {
  InvariantBreach(this.name, this.detail, this.history);

  final String name;
  final String detail;
  final List<ChaosEvent> history;

  @override
  String toString() {
    final buffer = StringBuffer()
      ..writeln('invariant broken: $name')
      ..writeln(detail)
      ..writeln('after ${history.length} event(s):');
    for (final event in history) {
      buffer.writeln('  $event');
    }
    return buffer.toString();
  }
}

/// Builds a random event stream for a seed.
List<ChaosEvent> chaosScript(
  int seed, {
  required int laneCount,
  int steps = 120,
}) {
  final random = Random(seed);
  final moods = LaneMood.values;
  return [
    for (var i = 0; i < steps; i++)
      switch (random.nextInt(10)) {
        0 || 1 || 2 || 3 => SendPayload(
          i,
          random.nextBool()
              ? LinkMessagePriority.bulk
              : LinkMessagePriority.callSignal,
        ),
        4 || 5 => SetMood(
          random.nextInt(laneCount),
          moods[random.nextInt(moods.length)],
        ),
        6 => SetHealth(
          random.nextInt(laneCount),
          random.nextBool(),
          1 + random.nextInt(2000),
          random.nextDouble() * 60,
        ),
        7 || 8 => const Refresh(),
        _ => AdvanceClock(1 + random.nextInt(5000)),
      },
  ];
}

/// Runs one world and checks every invariant after every event.
class ChaosWorld {
  ChaosWorld({required this.laneCount, this.queueLimit = 64});

  final int laneCount;
  final int queueLimit;

  final List<ChaosLane> lanes = [];
  late final ConnectionFabric fabric;
  late final DtnBundleQueue queue;

  int _clockMs = 1000;
  final Map<String, List<int>> _sent = {};
  final Set<String> _queued = {};
  final List<ChaosEvent> _history = [];

  void _build() {
    queue = DtnBundleQueue(maxBundles: queueLimit, maxBytes: 1 << 20);
    fabric = ConnectionFabric(fallbackQueue: queue, nowMs: () => _clockMs);
    for (var i = 0; i < laneCount; i++) {
      final lane = ChaosLane('lane$i', latencyMs: 10 + i * 15);
      lanes.add(lane);
      fabric.registerLane(
        lane,
        LaneProfile(id: 'lane$i', kind: LaneKind.internet, costRank: i),
      );
    }
  }

  /// Runs [script], returning the number of events applied.
  Future<int> run(List<ChaosEvent> script) async {
    _build();
    try {
      for (final event in script) {
        _history.add(event);
        await _apply(event);
        _check();
      }
      return script.length;
    } finally {
      await fabric.dispose();
    }
  }

  Future<void> _apply(ChaosEvent event) async {
    switch (event) {
      case SendPayload(:final index, :final priority):
        final id = 'bundle-$index';
        final payload = List<int>.generate(
          8 + (index % 17),
          (i) => (index * 31 + i) & 0xFF,
        );
        _sent[id] = payload;
        final outcome = await fabric.deliver(
          payload,
          bundleId: id,
          priority: priority,
        );
        switch (outcome) {
          case DeliveryOutcome.sentLive:
            _queued.remove(id);
          case DeliveryOutcome.queuedForLater:
            _queued.add(id);
          case DeliveryOutcome.rejected:
            // The queue refused it: full, expired, or a duplicate id. The
            // payload is accounted as neither live nor pending, which the
            // accounting invariant allows only because the caller was told.
            _queued.remove(id);
            _sent.remove(id);
        }
      case SetMood(:final lane, :final mood):
        lanes[lane].mood = mood;
        lanes[lane].setHealth(
          reachable: mood != LaneMood.failing && mood != LaneMood.throwing,
        );
      case SetHealth(:final lane, :final reachable, :final rttMs, :final loss):
        lanes[lane].setHealth(
          reachable: reachable,
          rttMs: rttMs,
          availability: (100 - loss) / 100,
        );
      case Refresh():
        await fabric.refresh();
      case AdvanceClock(:final byMs):
        _clockMs += byMs;
    }
  }

  /// Whether some lane accepted these exact bytes.
  bool _wasAccepted(List<int> payload) {
    for (final lane in lanes) {
      for (final carried in lane.claimed) {
        if (carried.length != payload.length) continue;
        var same = true;
        for (var i = 0; i < payload.length; i++) {
          if (carried[i] != payload[i]) {
            same = false;
            break;
          }
        }
        if (same) return true;
      }
    }
    return false;
  }

  void _fail(String name, String detail) =>
      throw InvariantBreach(name, detail, List.of(_history));

  void _check() {
    // 1. Nothing is corrupted. Every byte a lane carried is exactly what
    //    some caller handed the fabric.
    for (final lane in lanes) {
      for (final carried in lane.carried) {
        final match = _sent.values.any(
          (sent) =>
              sent.length == carried.length &&
              List.generate(
                sent.length,
                (i) => sent[i] == carried[i],
              ).every((ok) => ok),
        );
        if (!match) {
          _fail(
            'no corruption',
            '${lane.name} carried bytes that were never sent: $carried',
          );
        }
      }
    }

    // 2. The queue respects its own bound. A resilience mechanism that
    //    grows without limit is a memory leak with good intentions.
    if (queue.pendingCount > queueLimit) {
      _fail(
        'bounded queue',
        'queue holds ${queue.pendingCount}, limit is $queueLimit',
      );
    }

    // 3. Nothing is silently lost. Every payload the fabric accepted is
    //    either on a lane, or still pending — never neither.
    final pending = {
      for (final bundle in queue.pendingInDeliveryOrder(_clockMs)) bundle.id,
    };
    // A payload the fabric parked may leave the queue in exactly three
    // ways, all of them things the caller was told about or asked for:
    // it went out on a lane, it was evicted because the queue is full, or
    // it expired. Vanishing for any other reason is the failure this whole
    // design exists to prevent.
    final full = queue.pendingCount >= queueLimit;
    for (final id in _queued.toList()) {
      if (pending.contains(id)) continue;
      final payload = _sent[id];
      if (payload != null && _wasAccepted(payload)) {
        _queued.remove(id);
        continue;
      }
      if (full) {
        // Overflow eviction: bounded on purpose, and the bound is
        // asserted separately above.
        _queued.remove(id);
        continue;
      }
      _fail(
        'nothing is lost',
        '$id was parked for later, is no longer pending, and no lane accepted '
            'it (queue holds ${queue.pendingCount}/$queueLimit)',
      );
    }

    // 4. The snapshot never claims a health it does not have. A fabric
    //    reporting itself online with no usable lane is worse than one
    //    reporting itself down, because the caller acts on it.
    final snapshot = fabric.snapshot;
    final anyReachable = lanes.any((l) => l.looksReachable);
    if (snapshot.mode == FabricMode.live && !anyReachable) {
      _fail(
        'honest snapshot',
        'fabric reports itself live while every lane is unreachable',
      );
    }
    if (snapshot.lanes.length != lanes.length) {
      _fail(
        'complete snapshot',
        'snapshot lists ${snapshot.lanes.length} of ${lanes.length} lanes',
      );
    }
  }
}

/// Runs [seed] and returns the breach, or null when the world held.
Future<InvariantBreach?> runSeed(
  int seed, {
  int laneCount = 4,
  int steps = 120,
}) async {
  final script = chaosScript(seed, laneCount: laneCount, steps: steps);
  try {
    await ChaosWorld(laneCount: laneCount).run(script);
    return null;
  } on InvariantBreach catch (breach) {
    return breach;
  }
}

/// Finds the shortest prefix of [seed]'s script that still breaks.
///
/// A counterexample of four events is a bug report; the same bug inside a
/// hundred and twenty events is a puzzle.
Future<InvariantBreach?> shrink(
  int seed, {
  int laneCount = 4,
  int steps = 120,
}) async {
  final script = chaosScript(seed, laneCount: laneCount, steps: steps);
  InvariantBreach? smallest;
  for (var length = 1; length <= script.length; length++) {
    try {
      await ChaosWorld(laneCount: laneCount).run(script.sublist(0, length));
    } on InvariantBreach catch (breach) {
      smallest = breach;
      break;
    }
  }
  return smallest;
}
