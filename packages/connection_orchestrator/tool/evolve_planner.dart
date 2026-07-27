/// Evolutionary tuning bench for the delivery brain.
///
/// Generates seeded random multi-factor crisis timelines (lane slides,
/// flaps, blackouts, link-only phases, recoveries), runs the REAL
/// [ConnectionFabric] + [DeliveryPlanner] + [TrendMonitor] through each,
/// and scores: live delivery reward minus redundancy spend minus queue
/// latency. A small evolution loop then searches the planner/sentinel
/// constants for the highest-scoring configuration.
///
/// Manual bench, not part of the CI gate:
///   dart run tool/evolve_planner.dart [generations] [scenarios]
library;

import 'dart:math';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart';

/// One lane's scripted state at one step.
class LaneState {
  const LaneState(this.up, this.quality); // quality 0..1 drives availability

  final bool up;
  final double quality;
}

/// A scripted crisis: per-step state for each of three lanes.
class Scenario {
  Scenario(this.steps);

  final List<Map<String, LaneState>> steps;

  /// Random but structured: phases of calm, slide, flap, blackout,
  /// link-only and recovery, so the timelines look like real crises.
  factory Scenario.random(Random rng, {int length = 20}) {
    final steps = <Map<String, LaneState>>[];
    var wifi = 0.9, cell = 0.6, link = 0.0;
    var phase = 0;
    for (var i = 0; i < length; i++) {
      if (i % 4 == 3) phase = rng.nextInt(5);
      switch (phase) {
        case 0: // calm / drift
          wifi = (wifi + rng.nextDouble() * 0.1 - 0.05).clamp(0.0, 1.0);
        case 1: // wifi slide
          wifi = (wifi - 0.25 - rng.nextDouble() * 0.15).clamp(0.0, 1.0);
        case 2: // cell flap
          cell = rng.nextBool() ? 0.0 : 0.55;
        case 3: // blackout pressure
          wifi = (wifi - 0.4).clamp(0.0, 1.0);
          cell = (cell - 0.4).clamp(0.0, 1.0);
          link = rng.nextBool() ? 0.3 : 0.0;
        case 4: // recovery
          wifi = (wifi + 0.3).clamp(0.0, 1.0);
          cell = (cell + 0.2).clamp(0.0, 0.7);
      }
      steps.add({
        'wifi': LaneState(wifi > 0.05, wifi),
        'cell': LaneState(cell > 0.05, cell),
        'link': LaneState(link > 0.05, link),
      });
    }
    return Scenario(steps);
  }
}

class ScriptedChannel implements TransportChannel {
  ScriptedChannel(this.name);

  @override
  final String name;

  LaneState state = const LaneState(true, 0.9);
  int sends = 0;

  @override
  final ChannelHealth health = ChannelHealth(
    reliabilityPrior: 0.7,
    bandwidth: 0.7,
    rttMs: 60,
  );

  @override
  Future<bool> probe() async => state.up;

  @override
  Future<SendResult> send(List<int> payload) async {
    sends++;
    // Delivery succeeds with probability = scripted quality.
    final ok = state.up && state.quality > 0.25;
    return ok
        ? const SendResult(SendStatus.ok, rttMs: 40)
        : const SendResult(SendStatus.transient);
  }

  @override
  Future<void> dispose() async {}
}

/// The tunable genome: planner + sentinel constants.
class Genome {
  Genome(this.g);

  final Map<String, double> g;

  static final Map<String, (double, double)> bounds = {
    'raceMargin': (0.0, 0.5),
    'credibleFloor': (0.05, 0.5),
    'costPenalty': (0.0, 0.2),
    'healthWeight': (0.2, 0.8), // learnedWeight = 1 - healthWeight
    'slipSlopePerSec': (-0.05, -0.002),
    'trendFloor': (0.1, 0.4),
  };

  factory Genome.defaults() => Genome({
    'raceMargin': 0.15,
    'credibleFloor': 0.2,
    'costPenalty': 0.05,
    'healthWeight': 0.5,
    'slipSlopePerSec': -0.01,
    'trendFloor': 0.2,
  });

  factory Genome.random(Random rng) => Genome({
    for (final e in bounds.entries)
      e.key: e.value.$1 + rng.nextDouble() * (e.value.$2 - e.value.$1),
  });

  Genome mutate(Random rng, {double rate = 0.35}) {
    final child = Map<String, double>.from(g);
    for (final e in bounds.entries) {
      if (rng.nextDouble() < rate) {
        final span = e.value.$2 - e.value.$1;
        child[e.key] = (child[e.key]! + (rng.nextDouble() - 0.5) * span * 0.4)
            .clamp(e.value.$1, e.value.$2);
      }
    }
    return Genome(child);
  }

  @override
  String toString() =>
      g.entries.map((e) => '${e.key}=${e.value.toStringAsFixed(3)}').join(' ');
}

Future<double> scoreGenome(Genome genome, List<Scenario> scenarios) async {
  var total = 0.0;
  for (final scenario in scenarios) {
    var clockMs = 0;
    final queue = DtnBundleQueue();
    final channels = {
      for (final id in ['wifi', 'cell', 'link']) id: ScriptedChannel(id),
    };
    final fabric = ConnectionFabric(
      fallbackQueue: queue,
      nowMs: () => clockMs,
      planner: DeliveryPlanner(
        raceMargin: genome.g['raceMargin']!,
        credibleFloor: genome.g['credibleFloor']!,
        costPenalty: genome.g['costPenalty']!,
        healthWeight: genome.g['healthWeight']!,
        learnedWeight: 1 - genome.g['healthWeight']!,
      ),
      trend: TrendMonitor(
        slipSlopePerSec: genome.g['slipSlopePerSec']!,
        floor: genome.g['trendFloor']!,
      ),
    );
    var i = 0;
    for (final e in channels.entries) {
      fabric.registerLane(
        e.value,
        LaneProfile(
          id: e.key,
          kind: e.key == 'link' ? LaneKind.localPeer : LaneKind.internet,
          costRank: i++,
        ),
      );
    }
    var delivered = 0, queuedLatency = 0;
    for (var s = 0; s < scenario.steps.length; s++) {
      final step = scenario.steps[s];
      for (final e in channels.entries) {
        e.value.state = step[e.key]!;
        // Health tracks scripted quality with EWMA-ish inertia.
        e.value.health.availability =
            0.5 * e.value.health.availability + 0.5 * step[e.key]!.quality;
      }
      clockMs += 1000;
      await fabric.refresh(); // probes lanes + feeds the trend sentinel
      final outcome = await fabric.deliver(
        [s],
        bundleId: 'b$s',
        priority: LinkMessagePriority.presence,
        lifetimeMs: 120000,
      );
      if (outcome == DeliveryOutcome.sentLive) delivered++;
      queuedLatency += queue.pendingCount;
    }
    final totalSends = channels.values.fold(0, (a, c) => a + c.sends);
    total += 2.0 * delivered - 0.02 * totalSends - 0.05 * queuedLatency;
    await fabric.dispose();
  }
  return total / scenarios.length;
}

Future<void> main(List<String> args) async {
  final generations = args.isNotEmpty ? int.parse(args[0]) : 12;
  final scenarioCount = args.length > 1 ? int.parse(args[1]) : 24;
  final rng = Random(42);
  final scenarios = [
    for (var i = 0; i < scenarioCount; i++) Scenario.random(rng),
  ];

  final defaults = Genome.defaults();
  final defaultScore = await scoreGenome(defaults, scenarios);
  print('DEFAULTS  score=${defaultScore.toStringAsFixed(2)}  $defaults');

  var population = <Genome>[
    defaults,
    for (var i = 0; i < 15; i++) Genome.random(rng),
  ];
  var best = defaults;
  var bestScore = defaultScore;
  for (var gen = 0; gen < generations; gen++) {
    final scored = <(Genome, double)>[];
    for (final genome in population) {
      scored.add((genome, await scoreGenome(genome, scenarios)));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    if (scored.first.$2 > bestScore) {
      best = scored.first.$1;
      bestScore = scored.first.$2;
    }
    print(
      'gen$gen best=${scored.first.$2.toStringAsFixed(2)} '
      'median=${scored[scored.length ~/ 2].$2.toStringAsFixed(2)}',
    );
    final elite = [for (final s in scored.take(4)) s.$1];
    population = [
      ...elite,
      for (final e in elite) e.mutate(rng),
      for (final e in elite) e.mutate(rng, rate: 0.6),
    ];
  }
  print('\nBEST      score=${bestScore.toStringAsFixed(2)}  $best');
  print(
    'UPLIFT    ${(100 * (bestScore - defaultScore) / defaultScore.abs()).toStringAsFixed(1)}% '
    'over defaults on ${scenarios.length} training scenarios',
  );

  // Held-out validation: fresh scenarios from an independent seed, so an
  // uplift that only memorised the training set is exposed here.
  final valRng = Random(4242);
  final validation = [
    for (var i = 0; i < scenarioCount * 2; i++) Scenario.random(valRng),
  ];
  final valDefault = await scoreGenome(defaults, validation);
  final valBest = await scoreGenome(best, validation);
  print(
    'HELD-OUT  defaults=${valDefault.toStringAsFixed(2)} '
    'best=${valBest.toStringAsFixed(2)} '
    'uplift=${(100 * (valBest - valDefault) / valDefault.abs()).toStringAsFixed(1)}% '
    'on ${validation.length} unseen scenarios',
  );
}
