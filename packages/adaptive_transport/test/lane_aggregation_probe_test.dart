import 'dart:math';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

/// Deterministic topology fake: models how a link's capacity is shared, so the
/// probe can be exercised against per-flow, interface-bound, and mixed networks
/// without any I/O.
///
/// Capacity is expressed as delivered goodput (post-loss), because the probe is
/// specified to decide on decoder-side rank growth rather than injected bytes.
class FakeTopology {
  FakeTopology({
    required this.laneInterfaces,
    required this.interfaceCapacityBps,
    this.perFlow = false,
    this.noise = 0.0,
    this.baseOwdMs = 300,
    this.queueMsPerExcessLane = 0,
    int seed = 1,
  }) : _rng = Random(seed);

  /// laneId -> interfaceId.
  final Map<String, String> laneInterfaces;

  /// interfaceId -> delivered goodput available to that interface.
  final Map<String, double> interfaceCapacityBps;

  /// When true, every lane gets the full interface capacity (per-5-tuple
  /// shaping). When false, lanes on one interface divide it.
  final bool perFlow;

  final double noise;
  final int baseOwdMs;

  /// Extra one-way delay per lane beyond the first on a saturated interface —
  /// the queueing signature the delay guard exists to catch.
  final int queueMsPerExcessLane;

  final Random _rng;
  int windowCalls = 0;
  final List<List<String>> trials = [];

  double _goodput(List<String> lanes) {
    var total = 0.0;
    final byInterface = <String, List<String>>{};
    for (final l in lanes) {
      byInterface.putIfAbsent(laneInterfaces[l]!, () => []).add(l);
    }
    for (final entry in byInterface.entries) {
      final cap = interfaceCapacityBps[entry.key] ?? 0;
      total += perFlow ? cap * entry.value.length : cap;
    }
    if (noise > 0) {
      final factor = 1 + (_rng.nextDouble() * 2 - 1) * noise;
      total *= factor;
    }
    return total < 0 ? 0 : total;
  }

  int _owd(List<String> lanes) {
    if (perFlow || queueMsPerExcessLane == 0) return baseOwdMs;
    final byInterface = <String, int>{};
    for (final l in lanes) {
      byInterface.update(laneInterfaces[l]!, (v) => v + 1, ifAbsent: () => 1);
    }
    final excess = byInterface.values.fold<int>(0, (a, b) => a + (b - 1));
    return baseOwdMs + excess * queueMsPerExcessLane;
  }

  /// A [SymbolCarryingWindow] over this topology. Reports zero synthetic bytes
  /// because the windows carry the transfer's own symbols.
  Future<LaneWindowSample> window(List<String> lanes, Duration w) async {
    windowCalls++;
    trials.add(List.of(lanes));
    const symbolBytes = 55;
    final bps = _goodput(lanes);
    final symbols = (bps * w.inMilliseconds / 1000 / 8 / symbolBytes).round();
    return LaneWindowSample(
      innovativeSymbols: symbols,
      elapsed: w,
      owdMs: _owd(lanes),
      symbolBytes: symbolBytes,
    );
  }
}

const _lanes = <LaneCandidate>[
  LaneCandidate(laneId: 'udp0', interfaceId: 'cell', score: 0.9),
  LaneCandidate(laneId: 'udp1', interfaceId: 'cell', score: 0.8),
  LaneCandidate(laneId: 'wss0', interfaceId: 'wifi', score: 0.7),
];

void main() {
  group('candidate ordering', () {
    test('first lane of an unused interface outranks a same-interface lane', () {
      final ordered = LaneAggregationProbe.orderCandidates(_lanes);
      expect(ordered.map((c) => c.laneId), ['udp0', 'wss0', 'udp1']);
    });

    test('a duplicate lane id is rejected, never silently deduplicated', () {
      expect(
        () => LaneAggregationProbe.orderCandidates(const [
          LaneCandidate(laneId: 'udp0', interfaceId: 'cell', score: 0.9),
          LaneCandidate(laneId: 'udp0', interfaceId: 'wifi', score: 0.8),
        ]),
        throwsArgumentError,
      );
    });

    test('pure score order is kept within the first-of-interface group', () {
      final ordered = LaneAggregationProbe.orderCandidates(const [
        LaneCandidate(laneId: 'a', interfaceId: 'x', score: 0.2),
        LaneCandidate(laneId: 'b', interfaceId: 'y', score: 0.9),
      ]);
      expect(ordered.first.laneId, 'b');
    });
  });

  group('classification sweeps', () {
    test('per-flow: every lane is admitted and the class is perFlow', () async {
      final topo = FakeTopology(
        laneInterfaces: {'udp0': 'cell', 'udp1': 'cell', 'wss0': 'wifi'},
        interfaceCapacityBps: {'cell': 4000, 'wifi': 4000},
        perFlow: true,
      );
      final verdict = await LaneAggregationProbe(
        carryWindow: topo.window,
      ).run(networkFingerprint: 'net-a', candidates: _lanes);

      expect(verdict.admitted, ['udp0', 'wss0', 'udp1']);
      expect(verdict.classification, BottleneckClass.perFlow);
      expect(verdict.gainFactor, greaterThanOrEqualTo(2.5)); // gate C14
    });

    test('per-device single interface: no extra lane is admitted', () async {
      final topo = FakeTopology(
        laneInterfaces: {'udp0': 'cell', 'udp1': 'cell', 'udp2': 'cell'},
        interfaceCapacityBps: {'cell': 4000},
      );
      final verdict = await LaneAggregationProbe(carryWindow: topo.window).run(
        networkFingerprint: 'net-b',
        candidates: const [
          LaneCandidate(laneId: 'udp0', interfaceId: 'cell', score: 0.9),
          LaneCandidate(laneId: 'udp1', interfaceId: 'cell', score: 0.8),
          LaneCandidate(laneId: 'udp2', interfaceId: 'cell', score: 0.7),
        ],
      );

      expect(verdict.admitted, ['udp0']);
      expect(verdict.classification, BottleneckClass.perDevice);
      expect(verdict.gainFactor, lessThanOrEqualTo(1.2)); // gate C14
      expect(verdict.aggregationEnabled, isFalse);
    });

    test('mixed: the second interface is admitted, the duplicate is not',
        () async {
      final topo = FakeTopology(
        laneInterfaces: {'udp0': 'cell', 'udp1': 'cell', 'wss0': 'wifi'},
        interfaceCapacityBps: {'cell': 4000, 'wifi': 4000},
      );
      final verdict = await LaneAggregationProbe(
        carryWindow: topo.window,
      ).run(networkFingerprint: 'net-c', candidates: _lanes);

      expect(verdict.admitted, ['udp0', 'wss0']);
      expect(verdict.classification, BottleneckClass.mixed);
    });

    test('noisy sweep stays accurate across all three topologies (gate C18)',
        () async {
      // Hysteresis setting: a candidate must win two consecutive decisions.
      // Measured over 200 seeds, this cuts spurious admissions on the
      // interface-bound topology from 1.5% to 0.5% at no cost in accuracy.
      // Zero is not assertable — measurement noise is unbounded — so the gate
      // is a rate, and the bound below is chosen so that a correct build fails
      // it with probability well under 1%.
      const confirmations = 2;
      var correct = 0;
      var overEnabledOnPerDevice = 0;
      const seeds = 40;

      for (var seed = 1; seed <= seeds; seed++) {
        final perFlow = FakeTopology(
          laneInterfaces: {'udp0': 'cell', 'udp1': 'cell', 'wss0': 'wifi'},
          interfaceCapacityBps: {'cell': 4000, 'wifi': 4000},
          perFlow: true,
          noise: 0.15,
          seed: seed,
        );
        final device = FakeTopology(
          laneInterfaces: {'udp0': 'cell', 'udp1': 'cell', 'udp2': 'cell'},
          interfaceCapacityBps: {'cell': 4000},
          noise: 0.15,
          seed: seed + 1000,
        );
        final mixed = FakeTopology(
          laneInterfaces: {'udp0': 'cell', 'udp1': 'cell', 'wss0': 'wifi'},
          interfaceCapacityBps: {'cell': 4000, 'wifi': 4000},
          noise: 0.15,
          seed: seed + 2000,
        );

        final vFlow = await LaneAggregationProbe(
          carryWindow: perFlow.window,
          confirmations: confirmations,
        ).run(networkFingerprint: 'f$seed', candidates: _lanes);
        final vDevice = await LaneAggregationProbe(
          carryWindow: device.window,
          confirmations: confirmations,
        ).run(
          networkFingerprint: 'd$seed',
          candidates: const [
            LaneCandidate(laneId: 'udp0', interfaceId: 'cell', score: 0.9),
            LaneCandidate(laneId: 'udp1', interfaceId: 'cell', score: 0.8),
            LaneCandidate(laneId: 'udp2', interfaceId: 'cell', score: 0.7),
          ],
        );
        final vMixed = await LaneAggregationProbe(
          carryWindow: mixed.window,
          confirmations: confirmations,
        ).run(networkFingerprint: 'm$seed', candidates: _lanes);

        if (vFlow.admitted.length == 3) correct++;
        if (vDevice.admitted.length == 1) {
          correct++;
        } else {
          overEnabledOnPerDevice++;
        }
        if (vMixed.admitted.length == 2 &&
            vMixed.admitted.contains('wss0') &&
            !vMixed.admitted.contains('udp1')) {
          correct++;
        }
      }

      expect(correct / (seeds * 3), greaterThanOrEqualTo(0.90));
      expect(overEnabledOnPerDevice, lessThanOrEqualTo(2));
    });
  });

  group('guards and invariants', () {
    test('probe never emits synthetic bytes (gate C17)', () async {
      final topo = FakeTopology(
        laneInterfaces: {'udp0': 'cell', 'udp1': 'cell', 'wss0': 'wifi'},
        interfaceCapacityBps: {'cell': 4000, 'wifi': 4000},
        perFlow: true,
      );
      final verdict = await LaneAggregationProbe(
        carryWindow: topo.window,
      ).run(networkFingerprint: 'net-d', candidates: _lanes);

      expect(verdict.syntheticProbeBytes, 0);
      expect(verdict.toTelemetry()['syntheticProbeBytes'], 0);
    });

    test('delay guard aborts before admitting a queueing lane (gate C19)',
        () async {
      final topo = FakeTopology(
        laneInterfaces: {'udp0': 'cell', 'udp1': 'cell'},
        interfaceCapacityBps: {'cell': 4000},
        queueMsPerExcessLane: 400, // 300 -> 700 ms, above the 1.5x guard
      );
      final verdict = await LaneAggregationProbe(carryWindow: topo.window).run(
        networkFingerprint: 'net-e',
        candidates: const [
          LaneCandidate(laneId: 'udp0', interfaceId: 'cell', score: 0.9),
          LaneCandidate(laneId: 'udp1', interfaceId: 'cell', score: 0.8),
        ],
      );

      expect(verdict.abortedByDelay, isTrue);
      expect(verdict.admitted, ['udp0']);
      expect(verdict.classification, BottleneckClass.perDevice);
    });

    test('confirmations require a candidate to win twice before admission',
        () async {
      final topo = FakeTopology(
        laneInterfaces: {'udp0': 'cell', 'wss0': 'wifi'},
        interfaceCapacityBps: {'cell': 4000, 'wifi': 4000},
      );
      final verdict = await LaneAggregationProbe(
        carryWindow: topo.window,
        confirmations: 2,
      ).run(
        networkFingerprint: 'net-i',
        candidates: const [
          LaneCandidate(laneId: 'udp0', interfaceId: 'cell', score: 0.9),
          LaneCandidate(laneId: 'wss0', interfaceId: 'wifi', score: 0.8),
        ],
      );

      // A genuinely additive lane still passes, and it costs one extra
      // median decision: 3 baseline + 3 + 3 confirmation windows.
      expect(verdict.admitted, ['udp0', 'wss0']);
      expect(verdict.windowsUsed, 9);
    });

    test('median of three windows is used per decision', () async {
      final topo = FakeTopology(
        laneInterfaces: {'udp0': 'cell', 'wss0': 'wifi'},
        interfaceCapacityBps: {'cell': 4000, 'wifi': 4000},
      );
      final verdict = await LaneAggregationProbe(carryWindow: topo.window).run(
        networkFingerprint: 'net-f',
        candidates: const [
          LaneCandidate(laneId: 'udp0', interfaceId: 'cell', score: 0.9),
          LaneCandidate(laneId: 'wss0', interfaceId: 'wifi', score: 0.8),
        ],
      );

      expect(verdict.windowsUsed, 6); // baseline + one trial, 3 windows each
      expect(topo.windowCalls, 6);
    });

    test('single candidate yields unknown class and no aggregation', () async {
      final topo = FakeTopology(
        laneInterfaces: {'udp0': 'cell'},
        interfaceCapacityBps: {'cell': 4000},
      );
      final verdict = await LaneAggregationProbe(carryWindow: topo.window).run(
        networkFingerprint: 'net-g',
        candidates: const [
          LaneCandidate(laneId: 'udp0', interfaceId: 'cell', score: 0.9),
        ],
      );

      expect(verdict.classification, BottleneckClass.unknown);
      expect(verdict.aggregationEnabled, isFalse);
    });

    test('memory short-circuits a repeat run and expires with its TTL',
        () async {
      var now = 0;
      final memory = EphemeralAggregationMemory(
        nowMs: () => now,
        ttl: const Duration(minutes: 30),
      );
      final topo = FakeTopology(
        laneInterfaces: {'udp0': 'cell', 'wss0': 'wifi'},
        interfaceCapacityBps: {'cell': 4000, 'wifi': 4000},
      );
      final probe = LaneAggregationProbe(
        carryWindow: topo.window,
        memory: memory,
      );
      const candidates = [
        LaneCandidate(laneId: 'udp0', interfaceId: 'cell', score: 0.9),
        LaneCandidate(laneId: 'wss0', interfaceId: 'wifi', score: 0.8),
      ];

      await probe.run(networkFingerprint: 'net-h', candidates: candidates);
      final callsAfterFirst = topo.windowCalls;

      await probe.run(networkFingerprint: 'net-h', candidates: candidates);
      expect(topo.windowCalls, callsAfterFirst, reason: 'cached');

      now = const Duration(minutes: 31).inMilliseconds;
      await probe.run(networkFingerprint: 'net-h', candidates: candidates);
      expect(topo.windowCalls, greaterThan(callsAfterFirst));
    });

    test('rebind carries every setting to the new port', () async {
      final memory = EphemeralAggregationMemory(nowMs: () => 0);
      final original = LaneAggregationProbe(
        carryWindow: (_, _) async => throw StateError('must not be used'),
        memory: memory,
        minAdd: 0.4,
        windows: 5,
        confirmations: 2,
        window: const Duration(milliseconds: 250),
        delayGuardFactor: 1.8,
        maxLanes: 2,
      );

      final topo = FakeTopology(
        laneInterfaces: {'udp0': 'cell', 'wss0': 'wifi'},
        interfaceCapacityBps: {'cell': 4000, 'wifi': 4000},
      );
      final rebound = original.rebind(topo.window);

      expect(rebound.minAdd, 0.4);
      expect(rebound.windows, 5);
      expect(rebound.confirmations, 2);
      expect(rebound.window, const Duration(milliseconds: 250));
      expect(rebound.delayGuardFactor, 1.8);
      expect(rebound.maxLanes, 2);
      expect(rebound.memory, same(memory));

      // And it actually measures through the new port.
      final verdict = await rebound.run(
        networkFingerprint: 'rebound',
        candidates: const [
          LaneCandidate(laneId: 'udp0', interfaceId: 'cell', score: 0.9),
          LaneCandidate(laneId: 'wss0', interfaceId: 'wifi', score: 0.8),
        ],
      );
      expect(verdict.admitted, ['udp0', 'wss0']);
      expect(topo.windowCalls, greaterThan(0));
    });

    test('rejects invalid configuration', () {
      expect(
        () => LaneAggregationProbe(
          carryWindow: (_, _) async => throw StateError('unused'),
          minAdd: 0,
        ),
        throwsRangeError,
      );
      expect(
        () => LaneAggregationProbe(
          carryWindow: (_, _) async => throw StateError('unused'),
          delayGuardFactor: 1.0,
        ),
        throwsRangeError,
      );
    });
  });

  group('AdaptiveAggregationPolicy', () {
    LaneAggregationVerdict verdictOf(
      BottleneckClass c, {
      List<String> admitted = const ['udp0'],
    }) => LaneAggregationVerdict(
      admitted: admitted,
      classification: c,
      baseGoodputBps: 1000,
      finalGoodputBps: 1000,
      syntheticProbeBytes: 0,
      abortedByDelay: false,
      windowsUsed: 3,
    );

    test('offloads to a second interface only when one exists', () {
      expect(
        AdaptiveAggregationPolicy(
          verdict: verdictOf(BottleneckClass.perDevice),
          distinctInterfaces: 2,
        ).shouldOffloadToSecondInterface,
        isTrue,
      );
      expect(
        AdaptiveAggregationPolicy(
          verdict: verdictOf(BottleneckClass.perDevice),
          distinctInterfaces: 1,
        ).shouldOffloadToSecondInterface,
        isFalse,
      );
      expect(
        AdaptiveAggregationPolicy(
          verdict: verdictOf(BottleneckClass.perDevice),
          distinctInterfaces: 2,
          batteryOk: false,
        ).shouldOffloadToSecondInterface,
        isFalse,
      );
    });

    test('defers enhancement layers unless the link is per-flow', () {
      expect(
        AdaptiveAggregationPolicy(
          verdict: verdictOf(BottleneckClass.perDevice),
          distinctInterfaces: 1,
        ).deferEnhancementLayers,
        isTrue,
      );
      expect(
        AdaptiveAggregationPolicy(
          verdict: verdictOf(
            BottleneckClass.perFlow,
            admitted: ['udp0', 'wss0'],
          ),
          distinctInterfaces: 2,
        ).deferEnhancementLayers,
        isFalse,
      );
    });

    test('block size follows MTU and is never cut to fit a rate cap', () {
      const policy = AdaptiveAggregationPolicy(
        verdict: LaneAggregationVerdict(
          admitted: ['udp0'],
          classification: BottleneckClass.perDevice,
          baseGoodputBps: 100,
          finalGoodputBps: 100,
          syntheticProbeBytes: 0,
          abortedByDelay: false,
          windowsUsed: 3,
        ),
        distinctInterfaces: 1,
      );

      expect(policy.blockSizeFor(laneMtuBytes: 1200), 55);
      expect(policy.blockSizeFor(laneMtuBytes: 60), 55);
      expect(policy.blockSizeFor(laneMtuBytes: 50), 45);

      // 36 = 31 payload + 5 header: the smallest legal datagram, and therefore
      // the boundary itself must work, not merely the values above it.
      expect(policy.blockSizeFor(laneMtuBytes: 36), 31);

      // Below it there is no answer to give. This line used to assert
      // `blockSizeFor(32) == 31` — a block LARGER than the MTU, returned by a
      // method whose contract is "follows the lane MTU". Every datagram built
      // from it would be fragmented or dropped, and the cause would be a
      // number this method invented. Refusing is the only honest option, so
      // the throw is the behaviour under test.
      for (final tooSmall in [35, 32, 5, 0, -1]) {
        expect(
          () => policy.blockSizeFor(laneMtuBytes: tooSmall),
          throwsA(isA<ArgumentError>()),
          reason: 'mtu $tooSmall must be refused, not rounded up to fit',
        );
      }
    });

    test('battery gate collapses to one lane', () {
      final policy = AdaptiveAggregationPolicy(
        verdict: verdictOf(
          BottleneckClass.perFlow,
          admitted: ['udp0', 'wss0', 'udp1'],
        ),
        distinctInterfaces: 2,
        batteryOk: false,
      );
      expect(policy.lanesToUse, 1);
    });
  });
}
