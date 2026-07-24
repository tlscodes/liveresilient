/// The expert playbook must always return exactly one situation-matched
/// insight — never nothing, never a dump.
library;

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/intelligence/connectivity_playbook.dart';

ConnectivitySnapshot snap(
  FabricMode mode, {
  List<LaneStatus> lanes = const [],
  String? best,
  int pending = 0,
}) => ConnectivitySnapshot(
  mode: mode,
  lanes: lanes,
  bestLaneId: best,
  pendingBundles: pending,
  atMs: 0,
);

void main() {
  const playbook = ConnectivityPlaybook();
  const upLane = LaneStatus(id: 'wifi', eligible: true, score: 0.8);
  const backup = LaneStatus(id: 'cell', eligible: true, score: 0.6);

  test('offline → reassurance that nothing is lost', () {
    final i = playbook.match(snap(FabricMode.offline), TrendVerdict.unknown);
    expect(i.id, 'offline-no-lanes');
  });

  test('store-and-forward → queue discipline with the pending count', () {
    final i = playbook.match(
      snap(FabricMode.storeAndForward, pending: 7),
      TrendVerdict.unknown,
    );
    expect(i.id, 'dtn-queue-discipline');
    expect(i.guidance, contains('7'));
  });

  test('failingSoon beats mode → pre-emptive duplication insight', () {
    final i = playbook.match(
      snap(FabricMode.live, lanes: [upLane, backup], best: 'wifi'),
      TrendVerdict.failingSoon,
    );
    expect(i.id, 'preemptive-duplication');
    expect(i.actionHint, 'dual-send-window-open');
  });

  test('slipping → act-on-trend insight', () {
    final i = playbook.match(
      snap(FabricMode.live, lanes: [upLane, backup], best: 'wifi'),
      TrendVerdict.slipping,
    );
    expect(i.id, 'trend-beats-present');
  });

  test('degraded with one usable path → fragility warning', () {
    final i = playbook.match(
      snap(FabricMode.degraded, lanes: [upLane], best: 'wifi'),
      TrendVerdict.steady,
    );
    expect(i.id, 'single-path-fragility');
  });

  test('healthy with redundancy → standby reassurance', () {
    final i = playbook.match(
      snap(FabricMode.live, lanes: [upLane, backup], best: 'wifi'),
      TrendVerdict.steady,
    );
    expect(i.id, 'redundancy-standing-by');
  });
}
