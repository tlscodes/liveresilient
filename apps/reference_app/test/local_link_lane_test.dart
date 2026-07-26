/// The consent-gated local peer-to-peer link lane and its failover role.
library;

import 'dart:io';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:device_link/device_link.dart' show DeviceLinkConsent;
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/intelligence/intelligence_boot.dart';
import 'package:reference_app/src/intelligence/local_link_lane.dart';
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
  setUp(() => tempDir = Directory.systemTemp.createTempSync('link_'));
  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('LocalLinkLane', () {
    LocalLinkLane lane({
      required bool granted,
      required int peers,
      bool sendOk = true,
    }) => LocalLinkLane(
      consent: _consent(granted),
      binding: LocalLinkBinding(
        discoverAndConnect: () async => peers > 0,
        sendBytes: (_) async => sendOk,
        peerCount: () => peers,
      ),
    );

    test('denied consent sends nothing', () async {
      final result = await lane(granted: false, peers: 3).send([1]);
      expect(result.status, SendStatus.unavailable);
    });

    test('granted consent with a peer delivers', () async {
      final result = await lane(granted: true, peers: 1).send([1]);
      expect(result.status, SendStatus.ok);
    });

    test('no peer in range is a retryable failure, not a crash', () async {
      final result = await lane(granted: true, peers: 0).send([1]);
      expect(result.status, SendStatus.transient);
    });
  });

  testWidgets('fabric fails over to the link lane when internet dies', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final internet = _ToggleChannel('net');
      final link = LocalLinkLane(
        consent: _consent(true),
        binding: LocalLinkBinding(
          discoverAndConnect: () async => true,
          sendBytes: (_) async => true,
          peerCount: () => 2,
        ),
      );
      final stack = await bootIntelligence(
        storageDirFactory: () => tempDir,
        primaryLane: internet,
        localLinkLane: link,
        nowMs: () => 0,
        resolver: CachingNetworkResolver(
          HardwareNetworkResolver(
            transportProbe: () async => NetworkTransport.wifi,
          ),
          nowMs: () => 0,
        ),
      );

      internet.up = false;
      internet.health.availability = 0;
      final outcome = await stack.fabric.deliver([1], bundleId: 'x');

      // Internet lane is dead; the link lane carries it live — no queue.
      expect(outcome.name, 'sentLive');
      expect(stack.fabric.snapshot.pendingBundles, 0);
      await stack.dispose();
    });
  });
}

// A tiny concrete DeviceLinkConsent for the lane under test.
_RealConsent _consent(bool granted) => _RealConsent(granted);

class _RealConsent implements DeviceLinkConsent {
  const _RealConsent(this.granted);
  @override
  final bool granted;
}
