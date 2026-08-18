/// The probe seam, end to end: a real RlncEncoder feeding
/// `LaneAggregationProbe` through `RlncProbeCarrier`, over fake lanes whose
/// capacity is shared either per-flow or per-device.
///
/// This is the test that would have caught the actual defect — the probe had
/// zero call sites, so nothing could observe whether the port worked at all.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:test/test.dart';

/// Models delivered rank growth per lane set. Per-flow: each lane carries its
/// own budget. Per-device: the lanes divide one budget, so adding a lane moves
/// nothing.
class _Fabric {
  _Fabric({required this.perFlow, this.owdPerExcessLane = 0});

  final bool perFlow;
  final int owdPerExcessLane;

  /// Innovative symbols one lane delivers per window.
  static const int perWindowCapacity = 12;

  final Set<String> _lanesThisWindow = {};
  int rank = 0;
  int sends = 0;
  final Map<String, int> perLaneSends = {};

  /// Deterministic virtual clock: each send costs 1 ms. Wall-clock timing
  /// would make goodput — and therefore the lane decision — depend on how fast
  /// the host happens to be, which is how transport tests become flaky.
  int clockMs = 0;
  int now() => clockMs;

  Future<SendResult> send(String laneId, Uint8List datagram) async {
    sends++;
    clockMs++;
    perLaneSends.update(laneId, (v) => v + 1, ifAbsent: () => 1);
    _lanesThisWindow.add(laneId);
    return const SendResult(SendStatus.ok, rttMs: 200);
  }

  /// Converts "which lanes were driven this window" into delivered rank, then
  /// resets. Called by the carrier before and after each window.
  int readRank() {
    if (_lanesThisWindow.isNotEmpty) {
      final lanes = _lanesThisWindow.length;
      rank += perFlow ? perWindowCapacity * lanes : perWindowCapacity;
      _lanesThisWindow.clear();
    }
    return rank;
  }

  int owd(int laneCount) =>
      perFlow ? 200 : 200 + (laneCount - 1) * owdPerExcessLane;
}

RlncEncoder _encoder() => RlncEncoder(
  Uint8List.fromList(List.generate(4096, (i) => (i * 31) & 0xFF)),
  blockSize: LayeredRedundancyAllocator.mandatedBlockSize,
);

const _candidates = <LaneCandidate>[
  LaneCandidate(laneId: 'udp0', interfaceId: 'cell', score: 0.9),
  LaneCandidate(laneId: 'udp1', interfaceId: 'cell', score: 0.8),
  LaneCandidate(laneId: 'wss0', interfaceId: 'wifi', score: 0.7),
];

/// 6 ms = lcm(1,2,3): with the fabric's 1 ms-per-send clock every lane count
/// fills the window exactly, so elapsed time is identical across trials and a
/// goodput ratio reflects capacity rather than rounding.
const _window = Duration(milliseconds: 6);

RlncProbeCarrier _carrierOver(_Fabric fabric, {OwdReader? owd}) =>
    RlncProbeCarrier(
      sendOnLane: fabric.send,
      readInnovativeRank: fabric.readRank,
      readOwdMs: owd,
      nowMs: fabric.now,
    );

void main() {
  group('RlncProbeCarrier', () {
    test('emits real transfer symbols and zero synthetic bytes', () async {
      final fabric = _Fabric(perFlow: true);
      final window = _carrierOver(fabric).windowFor(_encoder());

      final sample = await window(['udp0'], _window);

      expect(sample.syntheticBytes, 0);
      expect(fabric.sends, 6); // one per virtual millisecond
      expect(sample.symbolBytes, 55);
      expect(sample.innovativeSymbols, _Fabric.perWindowCapacity);
    });

    test('ESI stride keeps lane symbol streams distinct', () async {
      final seen = <String>[];
      var clock = 0;
      final carrier = RlncProbeCarrier(
        sendOnLane: (laneId, datagram) async {
          // Header is u16 esi big-endian, then u16 blockCount.
          final esi = (datagram[0] << 8) | datagram[1];
          seen.add('$laneId:$esi');
          clock++;
          return const SendResult(SendStatus.ok, rttMs: 100);
        },
        readInnovativeRank: () => 0,
        nowMs: () => clock,
      );
      await carrier.windowFor(_encoder())(['a', 'b', 'c'], _window);

      final esis = seen.map((s) => int.parse(s.split(':')[1])).toList();
      expect(esis.toSet().length, esis.length, reason: 'no duplicate ESIs');
      for (final entry in seen) {
        final parts = entry.split(':');
        expect(int.parse(parts[1]) % 3, 'abc'.indexOf(parts[0]));
      }
    });

    test('successive windows never repeat a symbol', () async {
      final sent = <Uint8List>[];
      var clock = 0;
      final window = RlncProbeCarrier(
        sendOnLane: (_, d) async {
          sent.add(d);
          clock++;
          return const SendResult(SendStatus.ok, rttMs: 100);
        },
        readInnovativeRank: () => 0,
        nowMs: () => clock,
      ).windowFor(_encoder());

      await window(['x'], _window);
      await window(['x'], _window);

      final seen = <int>{};
      for (final d in sent) {
        expect(seen.add((d[0] << 8) | d[1]), isTrue, reason: 'duplicate ESI');
      }
      expect(sent.length, 12);
    });

    test('reports delivered rank growth, not symbols injected', () async {
      final fabric = _Fabric(perFlow: false);
      final window = _carrierOver(fabric).windowFor(_encoder());

      final sample = await window(['udp0', 'udp1'], _window);

      // Two lanes were driven, but a device-wide cap delivers one lane's worth
      // of rank. The sample must follow the rank, not the send count.
      expect(sample.innovativeSymbols, _Fabric.perWindowCapacity);
      expect(fabric.sends, 6);
    });

    test('a symbol budget bounds the window even with a stopped clock',
        () async {
      var sends = 0;
      final carrier = RlncProbeCarrier(
        sendOnLane: (_, _) async {
          sends++;
          return const SendResult(SendStatus.ok, rttMs: 10);
        },
        readInnovativeRank: () => 0,
        nowMs: () => 0, // time never advances: the hang case
        maxSymbolsPerWindow: 8,
      );

      await carrier.windowFor(_encoder())(['a'], const Duration(seconds: 30));
      expect(sends, 8);
    });

    test('stops at the ESI ceiling instead of throwing mid-transfer',
        () async {
      var sends = 0;
      var clock = 0;
      final carrier = RlncProbeCarrier(
        sendOnLane: (_, _) async {
          sends++;
          clock++;
          return const SendResult(SendStatus.ok, rttMs: 10);
        },
        readInnovativeRank: () => 0,
        nowMs: () => clock,
      );
      // Four ESIs below the u16 ceiling, two lanes: two rounds fit, the third
      // would overflow the wire header.
      final window = carrier.windowFor(
        _encoder(),
        startEsi: RlncProbeCarrier.maxEsi - 3,
      );

      await window(['a', 'b'], const Duration(seconds: 5));

      expect(sends, 4);
      expect(carrier.esiSpaceExhausted, isTrue);
    });

    test('rejects a start ESI outside the wire header', () {
      final carrier = RlncProbeCarrier(
        sendOnLane: (_, _) async => const SendResult(SendStatus.ok),
        readInnovativeRank: () => 0,
      );
      expect(
        () => carrier.windowFor(_encoder(), startEsi: 0x10000),
        throwsRangeError,
      );
    });

    test('rejects an invalid symbol budget', () {
      expect(
        () => RlncProbeCarrier(
          sendOnLane: (_, _) async => const SendResult(SendStatus.ok),
          readInnovativeRank: () => 0,
          maxSymbolsPerWindow: 0,
        ),
        throwsRangeError,
      );
    });
  });

  group('probe over the carrier', () {
    test('per-flow fabric: every lane is admitted', () async {
      final fabric = _Fabric(perFlow: true);
      final verdict = await LaneAggregationProbe(
        carryWindow: _carrierOver(fabric).windowFor(_encoder()),
        window: _window,
      ).run(networkFingerprint: 'flow', candidates: _candidates);

      expect(verdict.admitted.length, 3);
      expect(verdict.classification, BottleneckClass.perFlow);
      expect(verdict.syntheticProbeBytes, 0);
      expect(verdict.gainFactor, greaterThanOrEqualTo(2.5)); // gate C14
    });

    test('per-device fabric: nothing extra is admitted', () async {
      final fabric = _Fabric(perFlow: false);
      final verdict = await LaneAggregationProbe(
        carryWindow: _carrierOver(fabric).windowFor(_encoder()),
        window: _window,
      ).run(networkFingerprint: 'device', candidates: _candidates);

      expect(verdict.admitted, ['udp0']);
      expect(verdict.classification, BottleneckClass.perDevice);
      expect(verdict.gainFactor, lessThanOrEqualTo(1.2)); // gate C14
    });

    test('no back-channel means no rank, which means no aggregation',
        () async {
      var clock = 0;
      final carrier = RlncProbeCarrier(
        sendOnLane: (_, _) async {
          clock++;
          return const SendResult(SendStatus.ok, rttMs: 300);
        },
        readInnovativeRank: () => 0, // DTN: rank growth is unobservable
        nowMs: () => clock,
      );
      final verdict = await LaneAggregationProbe(
        carryWindow: carrier.windowFor(_encoder()),
        window: _window,
      ).run(networkFingerprint: 'dtn', candidates: _candidates);

      expect(verdict.admitted, ['udp0']);
      expect(verdict.classification, BottleneckClass.perDevice);
    });

    test('delay guard fires when extra lanes only queue', () async {
      final fabric = _Fabric(perFlow: false, owdPerExcessLane: 400);
      var laneCount = 1;
      final carrier = _carrierOver(fabric, owd: () => fabric.owd(laneCount));
      final inner = carrier.windowFor(_encoder());

      final verdict = await LaneAggregationProbe(
        carryWindow: (lanes, w) {
          laneCount = lanes.length;
          return inner(lanes, w);
        },
        window: _window,
      ).run(
        networkFingerprint: 'bloat',
        candidates: const [
          LaneCandidate(laneId: 'udp0', interfaceId: 'cell', score: 0.9),
          LaneCandidate(laneId: 'udp1', interfaceId: 'cell', score: 0.8),
        ],
      );

      expect(verdict.abortedByDelay, isTrue);
      expect(verdict.admitted, ['udp0']);
    });

    test('probeLanesForTransfer rebinds and returns the same decision',
        () async {
      final fabric = _Fabric(perFlow: true);
      final verdict = await probeLanesForTransfer(
        probe: LaneAggregationProbe(
          carryWindow: (_, _) async => throw StateError('placeholder port'),
          window: _window,
        ),
        carrier: _carrierOver(fabric),
        tier0Encoder: _encoder(),
        networkFingerprint: 'rebound',
        candidates: _candidates,
      );

      expect(verdict.admitted.length, 3);
      expect(verdict.classification, BottleneckClass.perFlow);
      expect(verdict.syntheticProbeBytes, 0);
    });

    test('the verdict becomes a router setting', () async {
      const base = RouterConfig(maxFailover: 2, fanout: 1);

      final flow = _Fabric(perFlow: true);
      final flowVerdict = await LaneAggregationProbe(
        carryWindow: _carrierOver(flow).windowFor(_encoder()),
        window: _window,
      ).run(networkFingerprint: 'flow2', candidates: _candidates);
      final flowConfig = routerConfigFor(flowVerdict, current: base);
      expect(flowConfig.fanout, 3);
      expect(flowConfig.maxFailover, greaterThanOrEqualTo(3));

      final device = _Fabric(perFlow: false);
      final deviceVerdict = await LaneAggregationProbe(
        carryWindow: _carrierOver(device).windowFor(_encoder()),
        window: _window,
      ).run(networkFingerprint: 'device2', candidates: _candidates);
      final deviceConfig = routerConfigFor(deviceVerdict, current: base);
      expect(deviceConfig.fanout, 1);
      expect(deviceConfig.maxFailover, 2, reason: 'unchanged');

      // Low battery collapses even a per-flow win to a single lane.
      final saving = routerConfigFor(
        flowVerdict,
        current: base,
        batteryOk: false,
      );
      expect(saving.fanout, 1);
    });

    test('the policy turns a per-device verdict into single-lane transport',
        () async {
      final fabric = _Fabric(perFlow: false);
      final verdict = await LaneAggregationProbe(
        carryWindow: _carrierOver(fabric).windowFor(_encoder()),
        window: _window,
      ).run(networkFingerprint: 'policy', candidates: _candidates);

      final policy = AdaptiveAggregationPolicy(
        verdict: verdict,
        distinctInterfaces: 2,
      );
      expect(policy.lanesToUse, 1);
      expect(policy.shouldOffloadToSecondInterface, isTrue);
      expect(policy.deferEnhancementLayers, isTrue);
      expect(policy.blockSizeFor(laneMtuBytes: 1200), 55);
    });
  });
}
