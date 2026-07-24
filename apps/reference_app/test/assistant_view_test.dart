/// The always-on assistant status box reflects the director's judgment
/// live, in every state.
library;

import 'dart:io';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/intelligence/assistant_view.dart';
import 'package:reference_app/src/intelligence/intelligence_boot.dart';
import 'package:reference_app/src/intelligence/network_name_resolver.dart';

class _ToggleChannel implements TransportChannel {
  _ToggleChannel(this.name);
  @override
  final String name;
  bool up = true;
  @override
  final ChannelHealth health = ChannelHealth(
    reliabilityPrior: 0.9,
    bandwidth: 0.8,
    rttMs: 40,
  );
  @override
  Future<bool> probe() async => up;
  @override
  Future<SendResult> send(List<int> p) async => up
      ? const SendResult(SendStatus.ok, rttMs: 20)
      : const SendResult(SendStatus.transient);
  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory tempDir;
  setUp(() => tempDir = Directory.systemTemp.createTempSync('assistview_'));
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
      ),
      nowMs: () => 0,
    ),
  );

  testWidgets('assistant view is always visible and tracks state', (
    tester,
  ) async {
    late IntelligenceStack stack;
    final lane = _ToggleChannel('net');
    await tester.runAsync(() async => stack = await boot(lane));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AssistantView(director: stack.director)),
      ),
    );
    await tester.pump();

    // Present even when calm (unlike the foresight card).
    expect(find.byKey(const Key('assistant-view')), findsOneWidget);
    expect(find.textContaining('healthy'), findsOneWidget);

    // Degrade → the same box reflects the new judgment.
    await tester.runAsync(() async {
      lane.up = false;
      lane.health.availability = 0;
      await stack.fabric.deliver([1], bundleId: 'x');
    });
    await tester.pump();
    expect(find.textContaining('weakening'), findsWidgets);

    await tester.runAsync(() async => stack.dispose());
  });
}
