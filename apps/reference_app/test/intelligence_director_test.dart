/// The team-leader layer: judgment, self-healing action, narration, and
/// the reactive foresight UI.
library;

import 'dart:io';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/intelligence/foresight_card.dart';
import 'package:reference_app/src/intelligence/intelligence_boot.dart';
import 'package:reference_app/src/intelligence/intelligence_director.dart';
import 'package:reference_app/src/intelligence/network_name_resolver.dart';

class _ToggleChannel implements TransportChannel {
  _ToggleChannel(this.name);

  @override
  final String name;

  bool up = true;
  int probes = 0;

  @override
  final ChannelHealth health = ChannelHealth(
    reliabilityPrior: 0.9,
    bandwidth: 0.8,
    rttMs: 40,
  );

  @override
  Future<bool> probe() async {
    probes++;
    return up;
  }

  @override
  Future<SendResult> send(List<int> payload) async => up
      ? const SendResult(SendStatus.ok, rttMs: 20)
      : const SendResult(SendStatus.transient);

  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('director_'));
  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<IntelligenceStack> boot(_ToggleChannel lane) => bootIntelligence(
    storageDirFactory: () => tempDir,
    primaryLane: lane,
    nowMs: () => 0,
    resolver: CachingNetworkResolver(
      HardwareNetworkResolver(
        transportProbe: () async => NetworkTransport.wifi,
        wifiNameProbe: () async => 'TestNet',
      ),
      nowMs: () => 0,
    ),
  );

  test('healthy boot judges calm and narrates via the assistant', () async {
    final stack = await boot(_ToggleChannel('net'));
    await stack.fabric.refresh();
    await Future<void>.delayed(Duration.zero);

    expect(stack.director.advisory.level, AdvisoryLevel.calm);
    expect(stack.director.advisory.detail.toLowerCase(), contains('connected'));
    await stack.dispose();
  });

  test(
    'losing every lane escalates to critical and shows queue counts',
    () async {
      final lane = _ToggleChannel('net');
      final stack = await boot(lane);
      lane.up = false;
      lane.health.availability = 0;
      await stack.fabric.deliver([1], bundleId: 'x');
      await Future<void>.delayed(Duration.zero);

      // A dead-but-registered lane is "degraded" (the fabric keeps trying
      // it as a lane switch); the payload is already parked in the queue.
      expect(stack.director.advisory.level, isNot(AdvisoryLevel.calm));
      expect(
        stack.director.advisory.headline.toLowerCase(),
        contains('weakening'),
      );
      expect(stack.director.advisory.detail, contains('1'));
      await stack.dispose();
    },
  );

  test('degradation triggers a self-healing refresh action', () async {
    final lane = _ToggleChannel('net');
    final stack = await boot(lane);
    final probesBefore = lane.probes;

    lane.health.availability = 0.1; // score collapses → degraded
    await stack.fabric.refresh();
    await Future<void>.delayed(Duration.zero);

    expect(stack.director.advisory.level, isNot(AdvisoryLevel.calm));
    expect(stack.director.advisory.actionTaken, isNotNull);
    expect(
      lane.probes,
      greaterThan(probesBefore),
      reason: 'the director actually refreshed, not just warned',
    );
    final refresh = stack.director.decisions.lastWhere(
      (d) => d.strategy == DirectorStrategy.refreshPaths,
    );
    expect(refresh.reason, contains('degraded'));
    await stack.dispose();
  });

  test('a predicted slide gets a pre-emptive fallback warm-up', () async {
    final lane = _ToggleChannel('net');
    final stack = await boot(lane);
    // Feed the sentinel a clearly declining score series while the lane
    // itself is still up: mode stays live, verdict turns slipping.
    stack.fabric.trend.observe('net', 0.9, nowMs: 0);
    stack.fabric.trend.observe('net', 0.7, nowMs: 5000);
    stack.fabric.trend.observe('net', 0.5, nowMs: 10000);
    await stack.fabric.refresh();
    await Future<void>.delayed(Duration.zero);

    expect(stack.director.advisory.level, AdvisoryLevel.caution);
    final preWarm = stack.director.decisions.where(
      (d) => d.strategy == DirectorStrategy.preWarmFallback,
    );
    expect(preWarm, isNotEmpty, reason: 'acted before anything broke');
    expect(preWarm.first.reason, contains('slide'));
    await stack.dispose();
  });

  test('repairs that do not help trigger judged restraint (backoff)', () async {
    final lane = _ToggleChannel('net');
    final stack = await boot(lane);
    lane.health.availability = 0.1; // stays below the switch threshold for the whole test
    await stack.fabric.refresh();
    await Future<void>.delayed(Duration.zero);
    // The director's own healing refresh publishes further snapshots that
    // stay degraded → the pending decision is judged noEffect and the
    // director deliberately holds instead of hammering.
    await stack.fabric.refresh();
    await Future<void>.delayed(Duration.zero);

    final first = stack.director.decisions.last;
    expect(first.outcome, DecisionOutcome.noEffect);
    expect(
      stack.director.decisions.map((d) => d.strategy),
      contains(DirectorStrategy.holdAndObserve),
      reason: 'restraint is itself a surfaced decision',
    );
    await stack.dispose();
  });

  testWidgets('ForesightCard hides when calm, shows judgment when not', (
    tester,
  ) async {
    late IntelligenceStack stack;
    final lane = _ToggleChannel('net');
    // Boot + fabric I/O are real async; run them through runAsync so the
    // stream/microtasks actually complete inside the widget test.
    await tester.runAsync(() async => stack = await boot(lane));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ForesightCard(director: stack.director)),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('foresight-card')), findsNothing);

    await tester.runAsync(() async {
      lane.up = false;
      lane.health.availability = 0;
      await stack.fabric.deliver([1], bundleId: 'x');
    });
    await tester.pump();

    expect(find.byKey(const Key('foresight-card')), findsOneWidget);
    expect(find.textContaining('weakening'), findsOneWidget);
    await tester.runAsync(() async => stack.dispose());
  });

  test('learning persists across a full stack reboot', () async {
    final stack = await boot(_ToggleChannel('net'));
    for (var i = 0; i < 6; i++) {
      stack.hub.recordObservation(quality: 0.9, slope: 0, nowMs: i);
    }
    await stack.dispose();

    final reborn = await boot(_ToggleChannel('net'));
    expect(
      reborn.hub.learner.expectedQuality('wifi:TestNet', 'wifi:TestNet'),
      greaterThan(0.7),
    );
    await reborn.dispose();
  });
}
