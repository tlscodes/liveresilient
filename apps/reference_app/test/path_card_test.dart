import 'dart:async';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/ui/path_card.dart';

ConnectivitySnapshot _snapshot({
  required FabricMode mode,
  String? bestLaneId,
  int pendingBundles = 0,
}) => ConnectivitySnapshot(
  mode: mode,
  lanes: const <LaneStatus>[],
  bestLaneId: bestLaneId,
  pendingBundles: pendingBundles,
  atMs: 0,
);

void main() {
  group('laneLabel', () {
    test('names every lane the fabric registers today', () {
      expect(laneLabel('webrtc-media'), 'direct media');
      expect(laneLabel('resilient.udp'), 'direct UDP fallback');
      expect(laneLabel('resilient.wss'), 'relay (WebSocket)');
      expect(laneLabel('resilient.https'), 'relay (HTTPS long-poll)');
      expect(laneLabel('resilient.dns-valve'), 'DNS valve');
      expect(laneLabel('resilient.mesh'), 'local mesh');
    });

    test('an id it does not know is shown, not hidden', () {
      expect(laneLabel('resilient.carrier-pigeon'), 'resilient.carrier-pigeon');
    });
  });

  group('pathLabel', () {
    test('the best lane by name', () {
      expect(
        pathLabel(
          _snapshot(
            mode: FabricMode.degraded,
            bestLaneId: 'resilient.dns-valve',
          ),
        ),
        'DNS valve',
      );
    });

    test('no lane: says whether messages are being stored', () {
      expect(pathLabel(_snapshot(mode: FabricMode.offline)), 'none');
      expect(
        pathLabel(
          _snapshot(mode: FabricMode.storeAndForward, pendingBundles: 3),
        ),
        'none — 3 message(s) stored',
      );
    });
  });

  group('PathCard', () {
    testWidgets('renders the lane and the mode from the snapshot stream', (
      tester,
    ) async {
      final snapshots = StreamController<ConnectivitySnapshot>.broadcast();
      addTearDown(snapshots.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PathCard(connectivity: snapshots.stream)),
        ),
      );
      expect(find.text('Path: not reported yet'), findsOneWidget);
      expect(find.byKey(const Key('path-card-mode')), findsNothing);

      // A broadcast stream delivers on a microtask and the builder rebuilds
      // on the frame after: one pump for the event, one for the frame.
      Future<void> deliver(ConnectivitySnapshot next) async {
        snapshots.add(next);
        await tester.pump();
        await tester.pump();
      }

      await deliver(
        _snapshot(mode: FabricMode.degraded, bestLaneId: 'resilient.dns-valve'),
      );
      expect(find.text('Path: DNS valve'), findsOneWidget);
      expect(find.text('degraded'), findsOneWidget);

      await deliver(
        _snapshot(mode: FabricMode.live, bestLaneId: 'webrtc-media'),
      );
      expect(find.text('Path: direct media'), findsOneWidget);
      expect(find.text('live'), findsOneWidget);
    });
  });
}
