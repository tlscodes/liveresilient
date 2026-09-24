// The courier's door probe (TxtLetterProbe) on Send: when the door is the
// path, three resolvers are raced first; the nonce our responder logged
// first picks the resolver, and when none was logged the letter is queued
// without a deliver. A live lane never pays for the probe.
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart'
    show TxtProbeAnswer, TxtProbeOutcome;
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/letter_courier.dart';
import 'package:reference_app/src/letter_queue.dart';

import 'letter_courier_test.dart' show ManualClock, ScriptedLanes, fast;

class ProbingLanes extends ScriptedLanes implements LetterDoorProbe {
  TxtProbeOutcome? next;
  int probes = 0;

  @override
  Future<TxtProbeOutcome?> probeDoor() async {
    probes++;
    return next;
  }
}

TxtProbeOutcome outcome({int? winner}) => TxtProbeOutcome(
  groupId: '0011223344556677',
  winnerIndex: winner,
  answers: [
    for (var i = 0; i < 3; i++)
      TxtProbeAnswer(
        index: i,
        label: ['udp53:10.0.0.1:53', 'udp53:8.8.8.8:53', 'udp53:1.1.1.1:53'][i],
        nonce: 'aaaaaaaaaaaaaaa$i',
        winnerNonce: winner == null ? null : 'aaaaaaaaaaaaaaa$winner',
        rank: winner == null ? null : i + 1,
        error: winner == null ? StateError('timeout') : null,
      ),
  ],
);

({LetterCourier courier, ProbingLanes lanes, List<String> notes}) rig() {
  final lanes = ProbingLanes();
  final clock = ManualClock();
  final courier = LetterCourier(
    endpoints: () => throw StateError('scripted lanes, never assembled'),
    budget: fast,
    now: () => clock.now,
    queue: LetterQueue(MemoryLetterQueueStore()),
    openLanes: () async => lanes,
    wait: clock.wait,
    schedulePeriodic: clock.schedule,
  );
  final notes = <String>[];
  courier.notes.addListener(
    () => notes
      ..clear()
      ..addAll(courier.notes.value),
  );
  return (courier: courier, lanes: lanes, notes: notes);
}

void main() {
  test('door path, no nonce logged: queued, never delivered', () async {
    final r = rig();
    r.lanes.doorUp = true;
    r.lanes.next = outcome();

    await r.courier.send(Uint8List.fromList('salam'.codeUnits), kind: 'typed');

    expect(r.lanes.probes, 1);
    expect(r.lanes.delivered, isEmpty);
    expect(r.courier.queue.isEmpty, isFalse);
    expect(
      r.notes.join('\n'),
      contains('probe group=0011223344556677 winner=null'),
    );
    await r.courier.dispose();
  });

  test('door path, a nonce logged: the letter goes out', () async {
    final r = rig();
    r.lanes.doorUp = true;
    r.lanes.next = outcome(winner: 1);

    await r.courier.send(Uint8List.fromList('salam'.codeUnits), kind: 'typed');

    expect(r.lanes.probes, 1);
    expect(r.lanes.delivered, hasLength(1));
    expect(r.notes.join('\n'), contains('winner=1'));
    await r.courier.dispose();
  });

  test('a live lane carries it without a probe', () async {
    final r = rig();
    r.lanes.liveUp = true;
    r.lanes.next = outcome();

    await r.courier.send(Uint8List.fromList('salam'.codeUnits), kind: 'typed');

    expect(r.lanes.probes, 0);
    expect(r.lanes.delivered, hasLength(1));
    await r.courier.dispose();
  });
}
