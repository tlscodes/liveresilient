/// Real user chat sends are tapped into the intelligence fabric: the brain
/// observes live traffic, not just the boot probe.
library;

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart' show DtnBundleQueue;
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/chat_demo_controller.dart';

class _OkChannel implements TransportChannel {
  int sends = 0;
  final bundleSizes = <int>[];
  @override
  String get name => 'tap-net';
  @override
  final ChannelHealth health = ChannelHealth(
    reliabilityPrior: 0.9,
    bandwidth: 0.8,
    rttMs: 20,
  );
  @override
  Future<bool> probe() async => true;
  @override
  Future<SendResult> send(List<int> payload) async {
    sends++;
    bundleSizes.add(payload.length);
    return const SendResult(SendStatus.ok, rttMs: 20);
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  test('a real chat send is carried live by the fabric', () async {
    final channel = _OkChannel();
    final fabric =
        ConnectionFabric(fallbackQueue: DtnBundleQueue(), nowMs: () => 0)
          ..registerLane(
            channel,
            LaneProfile(id: channel.name, kind: LaneKind.internet),
          );

    final chat = ChatDemoController(intelligenceFabric: fabric);
    await chat.sendText('hello world');
    // Let the best-effort fabric tap complete.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(channel.sends, greaterThan(0));
    expect(fabric.snapshot.mode, FabricMode.live);
    chat.dispose();
    await fabric.dispose();
  });

  test(
    'an attachment rides the fabric as a resumable chunked transfer',
    () async {
      final channel = _OkChannel();
      final fabric =
          ConnectionFabric(fallbackQueue: DtnBundleQueue(), nowMs: () => 0)
            ..registerLane(
              channel,
              LaneProfile(id: channel.name, kind: LaneKind.internet),
            );
      final bigBytes = List<int>.filled(48 * 1024, 7);
      final transfer = await fabric.deliverChunked(
        bigBytes,
        transferId: 'photo-1',
      );

      expect(transfer.complete, isTrue);
      expect(transfer.totalChunks, greaterThan(1), reason: 'actually chunked');
      expect(
        channel.sends,
        greaterThan(transfer.totalChunks),
        reason: 'data + parity chunks all carried',
      );
      await fabric.dispose();
    },
  );
}
