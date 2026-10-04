// Cycle B: two consecutive failed carries evict a lane from selection
// until its next healthy answer (arrived, or a door probe our responder
// logged); a lane that loses its path starts over. Scripted lanes, no
// network: which lane the courier selected is read off each letter card.
import 'dart:async';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart'
    show TxtProbeAnswer, TxtProbeOutcome;
import 'package:connection_orchestrator/connection_orchestrator.dart'
    show
        ConnectivitySnapshot,
        DeliveryOutcome,
        FabricMode,
        LaneStatus,
        ResilientLaneIds;
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/letter_card.dart';
import 'package:reference_app/src/letter_courier.dart';
import 'package:reference_app/src/letter_queue.dart';

const _wss = ResilientLaneIds.webSocketRelay;
const _https = ResilientLaneIds.httpLongPoll;
const _door = ResilientLaneIds.txtQuery;

const _budget = LetterCourierBudget(
  select: Duration(milliseconds: 300),
  carry: Duration(seconds: 15),
  refreshEvery: Duration(milliseconds: 50),
);

const _probeWin = TxtProbeOutcome(
  groupId: 'g',
  answers: [TxtProbeAnswer(index: 0, label: 'res-a', nonce: 'aa')],
  winnerIndex: 0,
);
const _probeMiss = TxtProbeOutcome(
  groupId: 'g',
  answers: [TxtProbeAnswer(index: 0, label: 'res-a', nonce: 'aa')],
  winnerIndex: null,
);

void main() {
  late _Lanes lanes;
  late _Cards cards;
  late LetterCourier courier;
  late DateTime now;

  setUp(() {
    lanes = _Lanes();
    cards = _Cards();
    now = DateTime(2026, 10, 4, 12);
    courier = LetterCourier(
      endpoints: () => throw StateError('scripted lanes, never assembled'),
      budget: _budget,
      now: () => now,
      queue: LetterQueue(MemoryLetterQueueStore()),
      openLanes: () async => lanes,
      wait: (d) async => now = now.add(d),
      schedulePeriodic: (_, _) => _HeldTimer(),
      cardSink: cards,
    );
  });

  tearDown(() => courier.dispose());

  /// One Send; returns the lane the courier selected (the card's best_lane).
  Future<String?> send(DeliveryOutcome outcome) async {
    lanes.outcome = outcome;
    now = now.add(const Duration(seconds: 1));
    await courier.send(Uint8List.fromList([1, 2, 3]), kind: 'typed');
    return cards.cards.last.toJson()['best_lane'] as String?;
  }

  test('one failure does not evict: the same lane is selected again', () async {
    lanes.up = {_wss, _https};
    expect(await send(DeliveryOutcome.rejected), _wss);
    expect(await send(DeliveryOutcome.sentLive), _wss);
  });

  test('two consecutive failures drop the winner to the next lane', () async {
    lanes.up = {_wss, _https};
    expect(await send(DeliveryOutcome.rejected), _wss);
    expect(await send(DeliveryOutcome.rejected), _wss);
    expect(await send(DeliveryOutcome.sentLive), _https);
    // Still out after the next lane delivers: only its own healthy
    // answer readmits it.
    expect(await send(DeliveryOutcome.sentLive), _https);
  });

  test('two probe misses evict the door; nothing else has a path, so the '
      'letter parks without a third probe', () async {
    lanes.up = {_door};
    lanes.probe = _probeMiss;
    expect(await send(DeliveryOutcome.sentLive), _door);
    expect(await send(DeliveryOutcome.sentLive), _door);
    expect(lanes.probes, 2);
    expect(await send(DeliveryOutcome.sentLive), isNull);
    expect(lanes.probes, 2);
    expect(courier.queue.length, 3);
  });

  test(
    'arrived readmits: fail, arrive, fail keeps the lane selected',
    () async {
      lanes.up = {_wss, _https};
      expect(await send(DeliveryOutcome.rejected), _wss);
      expect(await send(DeliveryOutcome.sentLive), _wss);
      expect(await send(DeliveryOutcome.rejected), _wss);
      expect(await send(DeliveryOutcome.sentLive), _wss);
    },
  );

  test('probe-win readmits: miss, win, miss keeps the door selected', () async {
    lanes.up = {_door};
    lanes.probe = _probeMiss;
    expect(await send(DeliveryOutcome.sentLive), _door);
    lanes.probe = _probeWin;
    expect(await send(DeliveryOutcome.sentLive), _door);
    lanes.probe = _probeMiss;
    expect(await send(DeliveryOutcome.sentLive), _door);
    expect(await send(DeliveryOutcome.sentLive), _door);
    expect(lanes.probes, 4);
  });

  test('a lane without a path resets its strikes and eviction', () async {
    lanes.up = {_wss, _https};
    expect(await send(DeliveryOutcome.rejected), _wss);
    expect(await send(DeliveryOutcome.rejected), _wss);
    expect(await send(DeliveryOutcome.sentLive), _https); // wss evicted
    lanes.up = {_https}; // wss loses its path
    expect(await send(DeliveryOutcome.sentLive), _https);
    lanes.up = {_wss, _https}; // back, with a clean slate
    expect(await send(DeliveryOutcome.rejected), _wss);
    expect(await send(DeliveryOutcome.sentLive), _wss); // one strike only
  });
}

/// Lanes in [up] score 0.9 (wss 0.9, https 0.8, door 0.7), the rest are
/// dead; ranked best first. Every deliver answers [outcome].
class _Lanes implements LetterLanes, LetterDoorProbe {
  Set<String> up = {};
  DeliveryOutcome outcome = DeliveryOutcome.sentLive;
  TxtProbeOutcome? probe;
  int probes = 0;

  @override
  Future<void> refresh() async {}

  @override
  ConnectivitySnapshot get snapshot {
    LaneStatus lane(String id, double live) => LaneStatus(
      id: id,
      eligible: true,
      score: up.contains(id) ? live : -1.1,
    );
    final lanes = [lane(_wss, 0.9), lane(_https, 0.8), lane(_door, 0.7)]
      ..sort((a, b) => b.score.compareTo(a.score));
    return ConnectivitySnapshot(
      mode: up.isEmpty ? FabricMode.storeAndForward : FabricMode.live,
      lanes: lanes,
      bestLaneId: lanes.first.id,
      pendingBundles: 0,
      atMs: 0,
    );
  }

  @override
  Future<DeliveryOutcome> deliver(
    Uint8List payload, {
    required String bundleId,
  }) async => outcome;

  @override
  Future<TxtProbeOutcome?> probeDoor() async {
    probes++;
    return probe;
  }

  @override
  void reclaim(String bundleId) {}

  @override
  bool get hasDoor => true;

  @override
  String? get doorSessionId => 'ABC123';

  @override
  Future<void> dispose() async {}
}

class _Cards implements LetterCardSink {
  final List<LetterCard> cards = [];

  @override
  Future<void> append(LetterCard card) async => cards.add(card);
}

class _HeldTimer implements Timer {
  bool _active = true;

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}
