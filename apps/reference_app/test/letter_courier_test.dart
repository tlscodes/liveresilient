// The courier's verdicts without a network: every lane aimed at a closed
// loopback port, so the policy's tail (door down → parked in the queue)
// and its refusals are decided here, deterministically. The "arrived
// through the door" case needs a responder and is the rig's row.
//
// The second group scripts the lane set instead: which lane ranks usable
// is a flag, every deliver's verdict is a value, and the door watch's
// clock is turned by hand — so the queue's exactly-once is proven without
// a socket and without a sleep.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart'
    show HostPort, TxtProbeAnswer, TxtProbeOutcome, TxtQueryLane, TxtQueryValve;
import 'package:connection_orchestrator/connection_orchestrator.dart'
    show
        CallHistoryStore,
        ConnectivitySnapshot,
        DeliveryOutcome,
        FabricMode,
        LaneStatus,
        ResilientLaneEndpoints,
        ResilientLaneIds;
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/intelligence/disk_json_storage.dart';
import 'package:reference_app/src/intelligence/network_name_resolver.dart';
import 'package:reference_app/src/letter_card.dart';
import 'package:reference_app/src/letter_composer.dart';
import 'package:reference_app/src/letter_courier.dart';
import 'package:reference_app/src/letter_parts.dart';
import 'package:reference_app/src/letter_queue.dart';
import 'package:reference_app/src/letter_rung_ladder.dart';
import 'package:reference_app/src/letter_status_ladder.dart';

const fast = LetterCourierBudget(
  select: Duration(milliseconds: 300),
  carry: Duration(seconds: 15),
  refreshEvery: Duration(milliseconds: 50),
);

/// Nothing listens on 127.0.0.1:9 (discard, never bound here): the relay
/// connect is refused at once and the valve's one probe fails.
ResilientLaneEndpoints deadLanes({bool door = true}) => ResilientLaneEndpoints(
  relayUri: Uri.parse('wss://127.0.0.1:9/'),
  longPollUri: Uri.parse('https://127.0.0.1:9/poll'),
  txtQueryValve: door
      ? const TxtQueryValve(
          domain: 'valve.test',
          resolvers: [HostPort(host: '127.0.0.1', port: 9)],
        )
      : null,
);

void main() {
  test(
    'a letter over the door limit is refused before any lane is touched',
    () async {
      final courier = LetterCourier(
        endpoints: () => throw StateError('lanes must not be built'),
        budget: fast,
      );
      // One byte over what ten letters carry; one byte over ONE letter is
      // no longer refused — it goes as two letters (tests below).
      final state = await courier.send(
        Uint8List(letterMaxTotalBytes() + 1),
        kind: 'typed',
      );
      expect(state, LetterState.notDelivered);
      expect(courier.status.value!.detail, contains('too long'));
      expect(courier.status.value!.detail, contains('$letterMaxParts letters'));
      expect(
        courier.status.value!.detail,
        contains('${TxtQueryLane.maxPayloadBytes}'),
      );
      await courier.dispose();
    },
  );

  test('a build with no lane at all says so instead of waiting', () async {
    final courier = LetterCourier(
      endpoints: () => const ResilientLaneEndpoints(),
      budget: fast,
    );
    await courier.probe();
    expect(courier.status.value!.state, LetterState.notDelivered);
    expect(courier.status.value!.detail, contains('no lane configured'));
    final state = await courier.send(
      Uint8List.fromList([1, 2, 3]),
      kind: 'typed',
    );
    expect(state, LetterState.notDelivered);
    await courier.dispose();
  });

  test(
    'every lane dead: live call unavailable, then queued as parked — never a spinner',
    () async {
      final courier = LetterCourier(
        endpoints: deadLanes,
        budget: fast,
        // One failed probe marks the door down, so the verdict is the
        // queue's and not a 10 s per-chunk wait.
        valveFailThreshold: 1,
      );
      final seen = <LetterState>[];
      courier.status.addListener(() {
        final s = courier.status.value;
        if (s != null) seen.add(s.state);
      });
      await courier.probe();
      expect(courier.status.value!.state, LetterState.liveCallUnavailable);

      final state = await courier.send(
        Uint8List.fromList('hello through the door'.codeUnits),
        kind: 'typed',
      );
      expect(state, LetterState.queued, reason: courier.notes.value.join('\n'));
      expect(courier.status.value!.detail, contains('parked'));
      expect(seen, contains(LetterState.liveCallUnavailable));
      expect(seen.last, LetterState.queued);
      expect(courier.busy.value, isFalse);
      await courier.dispose();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('wired the way main.dart wires it, a letter with no ladder history '
      'does not break', () async {
    final courier = LetterCourier(
      endpoints: deadLanes,
      budget: fast,
      valveFailThreshold: 1,
      networkResolver: const _FixedNetwork('test-net'),
      rungLadder: LetterRungLadder(_MemoryStorage()),
      doorResolverLadder: DoorResolverLadder(_MemoryStorage()),
    );

    final state = await courier.send(
      Uint8List.fromList('hello'.codeUnits),
      kind: 'typed',
    );

    expect(state, LetterState.queued, reason: courier.notes.value.join('\n'));
    await courier.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
    'a second Send while one is in flight is ignored, not stacked',
    () async {
      final courier = LetterCourier(
        endpoints: deadLanes,
        budget: fast,
        valveFailThreshold: 1,
      );
      final first = courier.send(Uint8List.fromList([1]), kind: 'typed');
      final second = await courier.send(Uint8List.fromList([2]), kind: 'typed');
      expect(second, LetterState.queued); // the state of the letter in flight
      await first;
      expect(courier.busy.value, isFalse);
      await courier.dispose();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  group('the startup rung ladder (scripted lanes, no network)', () {
    test('the previous winner is tried alone, overriding the fabric — '
        'and the win is stored again', () async {
      final lanes = ScriptedLanes()
        ..liveUp =
            true // fabric's OWN pick would be wss
        ..doorUp = true; // the door also has a path right now
      final store = _MemoryStorage();
      final ladder = LetterRungLadder(store);
      await ladder.record(
        'test-net',
        const LetterRungAttempt(
          rung: ResilientLaneIds.txtQuery,
          outcome: LetterRungOutcome.delivered,
        ),
      );
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: fast,
        openLanes: () async => lanes,
        networkResolver: const _FixedNetwork('test-net'),
        rungLadder: ladder,
      );

      final state = await courier.send(
        Uint8List.fromList([1, 2, 3]),
        kind: 'typed',
      );

      expect(state, LetterState.arrived);
      // wss was the fabric's top rank; the door won anyway.
      expect(courier.status.value!.detail, contains('through the door'));
      expect(
        await ladder.previousWinner('test-net'),
        ResilientLaneIds.txtQuery,
      );
      await courier.dispose();
    });

    test(
      'all three lanes dead: the letter queues and no rung is stored',
      () async {
        final lanes = ScriptedLanes(); // liveUp/doorUp both false: all dead
        final ladder = LetterRungLadder(_MemoryStorage());
        final courier = LetterCourier(
          endpoints: () => throw StateError('scripted lanes, never assembled'),
          budget: fast,
          openLanes: () async => lanes,
          networkResolver: const _FixedNetwork('test-net'),
          rungLadder: ladder,
        );

        final state = await courier.send(
          Uint8List.fromList([1, 2, 3]),
          kind: 'typed',
        );

        expect(state, LetterState.queued);
        expect(await ladder.previousWinner('test-net'), isNull);
        expect(lanes.delivered, isEmpty); // never even offered to the fabric
        await courier.dispose();
      },
    );

    test(
      'an arrived letter appends one call-history-shaped row — no text',
      () async {
        final lanes = ScriptedLanes()..doorUp = true;
        final history = CallHistoryStore();
        final courier = LetterCourier(
          endpoints: () => throw StateError('scripted lanes, never assembled'),
          budget: fast,
          openLanes: () async => lanes,
          networkResolver: const _FixedNetwork('test-net'),
          callHistory: history,
        );

        final state = await courier.send(
          Uint8List.fromList('secret letter body'.codeUnits),
          kind: 'typed',
        );

        expect(state, LetterState.arrived);
        expect(history.records, hasLength(1));
        final row = history.records.single;
        expect(row.rung, ResilientLaneIds.txtQuery);
        expect(row.endReason, 'delivered');
        expect(row.networkIdentityHash, isNot('test-net')); // hashed, not raw
        expect(row.connectMs, greaterThanOrEqualTo(0));
        // No letter text or byte survives into the row.
        expect(history.toJson().toString(), isNot(contains('secret letter')));
        await courier.dispose();
      },
    );
  });

  group('the six-rung status ladder on the banner', () {
    test('normal reaches the arrived banner when both non-door lanes are '
        'healthy', () async {
      final lanes = ScriptedLanes()
        ..liveUp = true
        ..httpsUp = true;
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: fast,
        openLanes: () async => lanes,
      );

      final state = await courier.send(
        Uint8List.fromList([1, 2, 3]),
        kind: 'typed',
      );

      expect(state, LetterState.arrived);
      expect(courier.ladderStatus.value?.rung, LetterLadderRung.normal);
      expect(courier.status.value!.detail, contains('normal'));
      await courier.dispose();
    });

    test('closed reaches the queued banner — queue and next probe only, '
        'never a second probe', () async {
      var probeCalls = 0;
      final lanes = DoorProbingLanes()
        ..doorUp = true
        ..answer = () {
          probeCalls++;
          return const TxtProbeOutcome(
            groupId: 'g',
            answers: [
              TxtProbeAnswer(index: 0, label: 'udp53:8.8.8.8:53', nonce: 'aa'),
            ],
            winnerIndex: null,
          );
        };
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: fast,
        openLanes: () async => lanes,
      );

      final state = await courier.send(
        Uint8List.fromList([1, 2, 3]),
        kind: 'typed',
      );

      expect(state, LetterState.queued);
      expect(courier.ladderStatus.value?.rung, LetterLadderRung.closed);
      expect(courier.status.value!.detail, contains('closed'));
      expect(courier.status.value!.detail, contains('waiting'));
      expect(courier.status.value!.detail, contains('next probe in'));
      expect(probeCalls, 1); // not a scanner: exactly this Send's probe
      await courier.dispose();
    });

    test('probe() alone sets the rung — no Send, no door probe', () async {
      final lanes = ScriptedLanes()..liveUp = true; // https stays dead
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: fast,
        openLanes: () async => lanes,
      );
      await courier.probe();
      expect(courier.ladderStatus.value?.rung, LetterLadderRung.limited);
      expect(lanes.delivered, isEmpty);
      await courier.dispose();
    });

    test('a multi-part letter names its rung on the arrived banner', () async {
      final lanes = ScriptedLanes()
        ..liveUp = true
        ..httpsUp = true;
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: fast,
        openLanes: () async => lanes,
      );
      final state = await courier.send(
        Uint8List(TxtQueryLane.maxPayloadBytes + 1),
        kind: 'typed',
      );
      expect(state, LetterState.arrived);
      expect(courier.status.value!.detail, contains('letters'));
      expect(courier.status.value!.detail, endsWith('· normal'));
      await courier.dispose();
    });

    test('a letter drained after "closed" does not carry "closed" onto its '
        'arrived banner', () async {
      final clock = ManualClock();
      final lanes = DoorProbingLanes()
        ..doorUp = true
        ..answer = () => const TxtProbeOutcome(
          groupId: 'g',
          answers: [
            TxtProbeAnswer(index: 0, label: 'udp53:8.8.8.8:53', nonce: 'aa'),
          ],
          winnerIndex: null,
        );
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: fast,
        now: () => clock.now,
        openLanes: () async => lanes,
        wait: clock.wait,
        schedulePeriodic: clock.schedule,
      );

      expect(
        await courier.send(Uint8List.fromList([1, 2, 3]), kind: 'typed'),
        LetterState.queued,
      );
      expect(courier.status.value!.detail, contains('closed'));

      await clock.tick(); // the watch drains; the door delivers

      expect(courier.status.value!.state, LetterState.arrived);
      expect(courier.status.value!.detail, isNot(contains('closed')));
      await courier.dispose();
    });
  });

  group('the durable queue behind a down door (scripted lanes, no network)', () {
    test(
      'a letter over the cap goes as parts in a row and lands as ONE record of the whole',
      () async {
        final rig = Rig();
        rig.lanes.doorUp = true;
        final whole = Uint8List.fromList([
          for (var i = 0; i < 9000; i++) i & 0xFF,
        ]);
        final state = await rig.courier.send(whole, kind: 'photo');
        expect(
          state,
          LetterState.arrived,
          reason: rig.courier.notes.value.join('\n'),
        );
        // Three parts of at most 4096 B, each a parsable part of one id.
        expect(rig.lanes.delivered, hasLength(3));
        final ids = <int>{};
        final asm = LetterAssembler(
          parseLetterPart(rig.lanes.delivered.first.$2)!.id,
        );
        for (final (bundle, bytes) in rig.lanes.delivered) {
          expect(bytes.length, lessThanOrEqualTo(4096));
          expect(bundle, matches(RegExp(r'-p[0-2]$')));
          final part = parseLetterPart(bytes)!;
          ids.add(part.id);
          expect(asm.add(part), isTrue);
        }
        expect(ids, hasLength(1));
        expect(asm.assemble(), whole);
        // One ledger record of the whole, under the letter's id.
        expect(rig.courier.ledger.records.value, hasLength(1));
        expect(rig.courier.ledger.records.value.single.bytes, whole);
        expect(
          rig.courier.ledger.records.value.single.sessionId,
          idHex(ids.single),
        );
        expect(rig.courier.status.value!.detail, contains('3 letters'));
        expect(rig.courier.queue.isEmpty, isTrue);
        await rig.courier.dispose();
      },
    );

    test(
      'three parts in flight at once, any order, and a lost part is sent again under its own index only',
      () async {
        final rig = Rig();
        rig.lanes.doorUp = true;
        rig.lanes.holdAll = true;
        final whole = Uint8List.fromList([
          for (var i = 0; i < 40000; i++) (i * 7) & 0xFF,
        ]);
        final sending = rig.courier.send(whole, kind: 'photo');
        await Future<void>.delayed(Duration.zero);
        // Ten parts, but only three are ever in flight.
        expect(rig.lanes.held, hasLength(3));
        expect(rig.lanes.held.map((h) => h.$1), [
          'letter-1789898400000-p0',
          'letter-1789898400000-p1',
          'letter-1789898400000-p2',
        ]);
        // Finish them out of order: p1 first, then p2, then p0.
        Future<void> finish(String suffix, DeliveryOutcome outcome) async {
          final h = rig.lanes.held.firstWhere((h) => h.$1.endsWith(suffix));
          h.$2.complete(outcome);
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);
        }

        await finish('-p1', DeliveryOutcome.sentLive);
        expect(rig.lanes.held, hasLength(3)); // p3 took the slot
        await finish('-p2', DeliveryOutcome.sentLive);
        // p0 is "lost": refused — only p0 is sent again, as p0-r1.
        await finish('-p0', DeliveryOutcome.rejected);
        expect(
          rig.lanes.held.map((h) => h.$1),
          contains('letter-1789898400000-p0-r1'),
        );
        expect(rig.lanes.held, hasLength(3));
        // Drain everything else in whatever order the window holds.
        while (rig.lanes.held.isNotEmpty) {
          await finish(
            rig.lanes.held.last.$1.split('letter-1789898400000').last,
            DeliveryOutcome.sentLive,
          );
        }
        final state = await sending;
        expect(
          state,
          LetterState.arrived,
          reason: rig.courier.notes.value.join('\n'),
        );
        expect(rig.lanes.maxInFlight, 3);
        // Eleven delivers: ten parts and one retry of p0; each index landed once.
        expect(rig.lanes.delivered, hasLength(11));
        final asm = LetterAssembler(
          parseLetterPart(rig.lanes.delivered.first.$2)!.id,
        );
        for (final (_, bytes) in rig.lanes.delivered) {
          asm.add(parseLetterPart(bytes)!);
        }
        expect(asm.assemble(), whole);
        expect(rig.courier.ledger.records.value.single.bytes, whole);
        expect(
          rig.courier.status.value!.detail,
          contains('10 letters, 3 at a time'),
        );
        await rig.courier.dispose();
      },
    );

    test(
      'a part lost three times ends the letter as not delivered, naming the index',
      () async {
        final rig = Rig();
        rig.lanes.doorUp = true;
        rig.lanes.holdAll = true;
        final sending = rig.courier.send(Uint8List(9000), kind: 'photo');
        await Future<void>.delayed(Duration.zero);
        for (var tries = 0; tries < 3; tries++) {
          final h = rig.lanes.held.firstWhere((h) => h.$1.contains('-p1'));
          h.$2.complete(DeliveryOutcome.rejected);
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);
        }
        for (final h in rig.lanes.held.toList()) {
          h.$2.complete(DeliveryOutcome.sentLive);
        }
        final state = await sending;
        expect(state, LetterState.notDelivered);
        expect(
          rig.courier.status.value!.detail,
          contains('letter 2/3 not taken after 3 tries'),
        );
        expect(rig.courier.ledger.records.value, isEmpty);
        await rig.courier.dispose();
      },
    );

    test(
      'the door drops mid-letter: the WHOLE letter is parked, nothing half is recorded',
      () async {
        final rig = Rig();
        rig.lanes.doorUp = true;
        rig.lanes.outcomes.addAll([
          DeliveryOutcome.sentLive,
          DeliveryOutcome.queuedForLater,
        ]);
        final whole = Uint8List(9000);
        final state = await rig.courier.send(whole, kind: 'photo');
        expect(state, LetterState.queued);
        expect(rig.courier.status.value!.detail, contains('parked'));
        // All three parts were launched at once; the door said no to one.
        expect(rig.lanes.delivered, hasLength(3));
        expect(rig.lanes.reclaimed, hasLength(1));
        expect(rig.courier.ledger.records.value, isEmpty);
        expect(rig.courier.queue.length, 1);
        expect(rig.store.contents.single.bytes, whole);
        await rig.courier.dispose();
      },
    );

    test(
      'a part refused by the queue is not delivered, and says which part',
      () async {
        final rig = Rig();
        rig.lanes.doorUp = true;
        // The third part is refused on every one of its three tries; the
        // other two land. Only that index was retried.
        rig.lanes.outcomes.addAll([
          DeliveryOutcome.sentLive,
          DeliveryOutcome.sentLive,
          DeliveryOutcome.rejected,
          DeliveryOutcome.rejected,
          DeliveryOutcome.rejected,
        ]);
        final state = await rig.courier.send(Uint8List(9000), kind: 'photo');
        expect(state, LetterState.notDelivered);
        expect(
          rig.courier.status.value!.detail,
          contains('letter 3/3 not taken after 3 tries'),
        );
        expect(rig.lanes.delivered, hasLength(5));
        expect(rig.courier.ledger.records.value, isEmpty);
        await rig.courier.dispose();
      },
    );

    test(
      'a door that answers but is fresh (−0.14, above the dead line) carries the letter — measured on the phone 2026-09-20',
      () async {
        final rig = Rig();
        rig.lanes.doorUp = true;
        rig.lanes.doorFresh = true;
        final state = await rig.courier.send(
          Uint8List.fromList('through a fresh door'.codeUnits),
          kind: 'typed',
        );
        expect(
          state,
          LetterState.arrived,
          reason: rig.courier.notes.value.join('\n'),
        );
        expect(rig.lanes.delivered, hasLength(1));
        expect(rig.courier.queue.isEmpty, isTrue);
        expect(rig.courier.ledger.records.value, hasLength(1));
        await rig.courier.dispose();
      },
    );

    test(
      'every lane negative and the door down: parked in the app queue, saved',
      () async {
        final rig = Rig();
        final state = await rig.courier.send(
          Uint8List.fromList('parked'.codeUnits),
          kind: 'typed',
        );
        expect(state, LetterState.queued);
        expect(
          rig.courier.status.value!.detail,
          contains('parked in the queue'),
        );
        expect(rig.courier.status.value!.detail, contains('1 waiting'));
        expect(rig.courier.queue.length, 1);
        expect(rig.store.saves, 1);
        expect(rig.store.contents.single.bytes, 'parked'.codeUnits);
        expect(rig.store.contents.single.kind, 'typed');
        // Nothing was offered to the fabric: the watch owns the one deliver.
        expect(rig.lanes.delivered, isEmpty);
        expect(rig.clock.periodic, isNotNull, reason: 'the watch is armed');
        expect(rig.courier.ledger.records.value, isEmpty);
        await rig.courier.dispose();
      },
    );

    test(
      'the door flips up: exactly one deliver, arrived, queue empty, ledger has the bytes',
      () async {
        final rig = Rig();
        await rig.courier.send(
          Uint8List.fromList('parked'.codeUnits),
          kind: 'typed',
        );
        rig.lanes.doorUp = true;
        await rig.clock.tick();
        expect(rig.lanes.delivered, hasLength(1));
        expect(rig.lanes.delivered.single.$2, 'parked'.codeUnits);
        expect(rig.courier.status.value!.state, LetterState.arrived);
        expect(rig.courier.status.value!.detail, contains('through the door'));
        expect(rig.courier.status.value!.detail, contains('session ABC123'));
        expect(rig.courier.queue.isEmpty, isTrue);
        expect(rig.store.contents, isEmpty);
        final record = rig.courier.ledger.records.value.single;
        expect(record.bytes, 'parked'.codeUnits);
        expect(record.kind, 'typed');
        expect(record.sessionId, 'ABC123');
        expect(rig.courier.busy.value, isFalse);
        await rig.courier.dispose();
      },
    );

    test('a second door-up tick delivers nothing more', () async {
      final rig = Rig();
      await rig.courier.send(
        Uint8List.fromList('once'.codeUnits),
        kind: 'typed',
      );
      rig.lanes.doorUp = true;
      await rig.clock.tick();
      await rig.clock.tick();
      await rig.clock.tick();
      expect(rig.lanes.delivered, hasLength(1));
      expect(rig.courier.ledger.records.value, hasLength(1));
      expect(rig.clock.periodic, isNull, reason: 'the watch stops when empty');
      await rig.courier.dispose();
    });

    test(
      'a new courier over the same store rehydrates the letter and sends it once',
      () async {
        final first = Rig();
        await first.courier.send(
          Uint8List.fromList('survive'.codeUnits),
          kind: 'voice',
        );
        expect(first.store.contents, hasLength(1));
        await first.courier.dispose();

        final second = Rig(store: first.store);
        await second.courier.restore();
        expect(second.courier.queue.length, 1);
        expect(second.courier.status.value!.state, LetterState.queued);
        expect(second.clock.periodic, isNotNull, reason: 'the watch resumes');
        second.lanes.doorUp = true;
        await second.clock.tick();
        await second.clock.tick();
        expect(second.lanes.delivered, hasLength(1));
        expect(second.lanes.delivered.single.$2, 'survive'.codeUnits);
        expect(second.courier.ledger.records.value.single.kind, 'voice');
        expect(
          first.store.contents,
          isEmpty,
          reason: 'sent letters leave the store',
        );

        // A third courier over the drained store has nothing to send.
        final third = Rig(store: first.store);
        await third.courier.restore();
        expect(third.courier.queue.isEmpty, isTrue);
        expect(third.clock.periodic, isNull);
        await second.courier.dispose();
        await third.courier.dispose();
      },
    );

    test(
      'a live lane ranking first carries the letter before the door; the queue stays empty',
      () async {
        final rig = Rig();
        rig.lanes.liveUp = true;
        rig.lanes.doorUp = true;
        final state = await rig.courier.send(
          Uint8List.fromList('live'.codeUnits),
          kind: 'typed',
        );
        expect(state, LetterState.arrived);
        expect(rig.courier.status.value!.detail, contains('via wss'));
        expect(rig.courier.status.value!.detail, isNot(contains('door')));
        expect(rig.lanes.delivered, hasLength(1));
        expect(rig.courier.queue.isEmpty, isTrue);
        expect(rig.store.saves, 0);
        expect(rig.clock.periodic, isNull, reason: 'nothing parked, no watch');
        final record = rig.courier.ledger.records.value.single;
        expect(record.laneId, ResilientLaneIds.webSocketRelay);
        expect(record.sessionId, isNull);
        await rig.courier.dispose();
      },
    );

    test(
      'the fabric parks a letter the lanes then refused: reclaimed into the app queue, drained once',
      () async {
        final rig = Rig();
        rig.lanes.doorUp = true;
        rig.lanes.outcome = DeliveryOutcome.queuedForLater;
        final state = await rig.courier.send(
          Uint8List.fromList('refused first'.codeUnits),
          kind: 'typed',
        );
        expect(state, LetterState.queued);
        expect(rig.lanes.delivered, hasLength(1));
        expect(rig.lanes.reclaimed, hasLength(1));
        expect(rig.courier.queue.length, 1);
        rig.lanes.outcome = DeliveryOutcome.sentLive;
        await rig.clock.tick();
        expect(rig.lanes.delivered, hasLength(2));
        expect(rig.courier.queue.isEmpty, isTrue);
        expect(rig.courier.ledger.records.value, hasLength(1));
        await rig.courier.dispose();
      },
    );

    test(
      'the queue is bounded: the letter past the cap is refused, never dropped',
      () async {
        final rig = Rig(maxLetters: 2);
        for (final text in ['one', 'two']) {
          expect(
            await rig.courier.send(
              Uint8List.fromList(text.codeUnits),
              kind: 'typed',
            ),
            LetterState.queued,
          );
        }
        final third = await rig.courier.send(
          Uint8List.fromList('three'.codeUnits),
          kind: 'typed',
        );
        expect(third, LetterState.notDelivered);
        expect(rig.courier.status.value!.detail, contains('queue full'));
        expect(rig.courier.queue.length, 2);
        expect(rig.store.contents, hasLength(2));
        expect(rig.store.contents.first.bytes, 'one'.codeUnits);
        expect(rig.store.saves, 2, reason: 'a refused letter is never saved');
        expect(rig.courier.busy.value, isFalse);
        await rig.courier.dispose();
      },
    );

    test(
      'a Send during the watch\'s pending refresh is refused: busy holds, one carry at a time',
      () async {
        final rig = Rig();
        await rig.courier.send(
          Uint8List.fromList('parked'.codeUnits),
          kind: 'typed',
        );
        rig.lanes.doorUp = true;
        final gate = rig.lanes.refreshGate = Completer<void>();
        await rig.clock.tick();
        expect(rig.courier.busy.value, isTrue, reason: 'the tick owns busy');
        expect(rig.lanes.delivered, isEmpty);

        final fresh = await rig.courier.send(
          Uint8List.fromList('fresh'.codeUnits),
          kind: 'typed',
        );
        expect(fresh, LetterState.queued, reason: 'refused, the head\'s state');
        expect(rig.lanes.delivered, isEmpty);

        rig.lanes.refreshGate = null;
        gate.complete();
        await rig.clock.tick();
        expect(rig.lanes.delivered, hasLength(1));
        expect(rig.lanes.delivered.single.$2, 'parked'.codeUnits);
        expect(rig.courier.busy.value, isFalse);
        expect(rig.courier.ledger.records.value, hasLength(1));
        expect(rig.courier.queue.isEmpty, isTrue);
        await rig.courier.dispose();
      },
    );

    group('a carry that outruns the budget (real 50 ms timeout)', () {
      const slow = LetterCourierBudget(
        select: Duration(milliseconds: 300),
        carry: Duration(milliseconds: 50),
        refreshEvery: Duration(milliseconds: 50),
      );

      Future<Rig> parkedThenHeld() async {
        final rig = Rig(budget: slow);
        await rig.courier.send(
          Uint8List.fromList('slow'.codeUnits),
          kind: 'typed',
        );
        rig.lanes.doorUp = true;
        rig.lanes.holdDeliver = Completer<DeliveryOutcome>();
        await rig.clock.tick();
        expect(rig.lanes.delivered, hasLength(1));
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(rig.courier.status.value!.state, LetterState.notDelivered);
        expect(rig.courier.status.value!.detail, contains('gave up'));
        expect(rig.courier.busy.value, isFalse);
        // Still in flight: a door-up tick must not offer it again.
        expect(rig.courier.queue.length, 1);
        expect(rig.courier.queue.waiting, 0);
        await rig.clock.tick();
        await rig.clock.tick();
        expect(rig.lanes.delivered, hasLength(1), reason: 'no second deliver');
        return rig;
      }

      test('late sentLive: recorded once, leaves the store', () async {
        final rig = await parkedThenHeld();
        rig.lanes.holdDeliver!.complete(DeliveryOutcome.sentLive);
        await rig.clock.tick();
        expect(rig.courier.ledger.records.value, hasLength(1));
        expect(rig.courier.ledger.records.value.single.sessionId, 'ABC123');
        expect(rig.courier.queue.isEmpty, isTrue);
        expect(rig.store.contents, isEmpty);
        expect(rig.courier.status.value!.state, LetterState.arrived);
        await rig.clock.tick();
        expect(rig.lanes.delivered, hasLength(1));
        expect(
          rig.clock.periodic,
          isNull,
          reason: 'the watch stops when empty',
        );
        await rig.courier.dispose();
      });

      test(
        'late queuedForLater: reclaimed from the fabric, offered once more on the next door-up',
        () async {
          final rig = await parkedThenHeld();
          final held = rig.lanes.holdDeliver!;
          rig.lanes.holdDeliver = null;
          held.complete(DeliveryOutcome.queuedForLater);
          await Future<void>.delayed(Duration.zero);
          expect(rig.lanes.reclaimed, [rig.lanes.delivered.single.$1]);
          expect(rig.courier.queue.length, 1);
          expect(rig.courier.queue.waiting, 1);
          expect(rig.courier.ledger.records.value, isEmpty);
          await rig.clock.tick();
          expect(rig.lanes.delivered, hasLength(2));
          expect(rig.lanes.delivered.last.$2, 'slow'.codeUnits);
          expect(rig.courier.ledger.records.value, hasLength(1));
          expect(rig.courier.queue.isEmpty, isTrue);
          await rig.courier.dispose();
        },
      );

      test(
        'a fresh letter whose late answer is sentLive still reaches the ledger',
        () async {
          final rig = Rig(budget: slow);
          rig.lanes.doorUp = true;
          rig.lanes.holdDeliver = Completer<DeliveryOutcome>();
          final state = await rig.courier.send(
            Uint8List.fromList('fresh'.codeUnits),
            kind: 'typed',
          );
          expect(state, LetterState.notDelivered);
          expect(rig.courier.queue.isEmpty, isTrue);
          rig.lanes.holdDeliver!.complete(DeliveryOutcome.sentLive);
          await Future<void>.delayed(Duration.zero);
          expect(rig.courier.ledger.records.value, hasLength(1));
          expect(rig.courier.status.value!.state, LetterState.arrived);
          expect(rig.courier.status.value!.detail, contains('late'));
          await rig.courier.dispose();
        },
      );
    });
  });

  group('the per-letter lab card (scripted lanes, no network)', () {
    test('a sentLive letter writes exactly one sentLive card', () async {
      final lanes = DoorProbingLanes()
        ..doorUp = true
        ..answer = () => const TxtProbeOutcome(
          groupId: 'g1',
          answers: [
            TxtProbeAnswer(index: 0, label: 'res-a', nonce: 'aa'),
            TxtProbeAnswer(index: 1, label: 'res-b', nonce: 'bb'),
          ],
          winnerIndex: 1,
        );
      final cards = RecordingCardSink();
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: fast,
        openLanes: () async => lanes,
        cardSink: cards,
      );

      final state = await courier.send(
        Uint8List.fromList('secret letter body'.codeUnits),
        kind: 'typed',
      );

      expect(state, LetterState.arrived);
      expect(cards.cards, hasLength(1));
      final card = cards.cards.single.toJson();
      expect(card['outcome'], 'sentLive');
      expect(card['best_lane'], ResilientLaneIds.txtQuery);
      expect(card['bytes'], 'secret letter body'.length);
      expect(card['session'], 'ABC123');
      expect(card['resolvers'], ['res-a', 'res-b']);
      expect(card['winner'], 'res-b');
      expect(card['source'], 'phone');
      // The existing ladder's reading is written when a status exists.
      expect(card['rung'], LetterLadderRung.withCourier.name);
      // ...and WHY: the door answered this round, no live lane.
      expect(card['reason'], 'door');
      expect(card['lab'], isTrue);
      // Counts and ids only: no letter text survives into the card.
      expect(jsonEncode(card), isNot(contains('secret letter')));
      await courier.dispose();
    });

    test('a queuedForLater letter writes exactly one queued card', () async {
      final lanes = ScriptedLanes()
        ..doorUp = true
        ..outcome = DeliveryOutcome.queuedForLater;
      final cards = RecordingCardSink();
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: fast,
        openLanes: () async => lanes,
        cardSink: cards,
      );

      final state = await courier.send(
        Uint8List.fromList([1, 2, 3]),
        kind: 'typed',
      );

      expect(state, LetterState.queued);
      expect(cards.cards, hasLength(1));
      final card = cards.cards.single.toJson();
      expect(card['outcome'], 'queued');
      expect(card['best_lane'], ResilientLaneIds.txtQuery);
      expect(card['bytes'], 3);
      expect(card['resolvers'], isEmpty);
      expect(card['rung'], LetterLadderRung.weak.name);
      // WHY weak: no live lane, but the door still had a path (no probe).
      expect(card['reason'], 'dead');
      await courier.dispose();
    });

    test('a closed door writes a queued card with rung closed', () async {
      final lanes = DoorProbingLanes()
        ..doorUp = true
        ..answer = () => const TxtProbeOutcome(
          groupId: 'g',
          answers: [
            TxtProbeAnswer(index: 0, label: 'udp53:8.8.8.8:53', nonce: 'aa'),
          ],
          winnerIndex: null,
        );
      final cards = RecordingCardSink();
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: fast,
        openLanes: () async => lanes,
        cardSink: cards,
      );

      final state = await courier.send(
        Uint8List.fromList([1, 2, 3]),
        kind: 'typed',
      );

      expect(state, LetterState.queued);
      expect(cards.cards, hasLength(1));
      final card = cards.cards.single.toJson();
      expect(card['outcome'], 'queued');
      expect(card['rung'], LetterLadderRung.closed.name);
      // WHY closed: this round's probe logged no nonce anywhere.
      expect(card['reason'], 'nonce');
      expect(card['resolvers'], ['udp53:8.8.8.8:53']);
      expect(card['winner'], isNull);
      await courier.dispose();
    });

    // Rung-absent is unreachable through send() (the ladder is always
    // refreshed first), so the null rung is pinned at the model level.
    test('rung present: the JSON carries the ladder name and reason', () {
      final card = LetterCard(
        at: DateTime.utc(2026, 9, 26, 12),
        source: 'phone',
        session: 'S1',
        bytes: 42,
        outcome: 'sentLive',
        bestLane: 'lane-x',
        resolvers: const ['res-a'],
        winner: 'res-a',
        rung: 'normal',
        reason: 'ok',
      );
      expect(
        jsonEncode(card.toJson()),
        '{"event":"letter_card","v":2,"at":"2026-09-26T12:00:00.000Z",'
        '"source":"phone","session":"S1","bytes":42,"outcome":"sentLive",'
        '"best_lane":"lane-x","resolvers":["res-a"],"winner":"res-a",'
        '"rung":"normal","reason":"ok","lab":true}',
      );
    });

    test(
      'the card\'s JSON key order is pinned byte for byte (rung/reason absent)',
      () {
        final card = LetterCard(
          at: DateTime.utc(2026, 9, 26, 12),
          source: 'mac',
          session: 'S1',
          bytes: 42,
          outcome: 'queued',
          bestLane: 'lane-x',
          resolvers: const ['res-a'],
          winner: 'res-a',
        );
        expect(
          jsonEncode(card.toJson()),
          '{"event":"letter_card","v":2,"at":"2026-09-26T12:00:00.000Z",'
          '"source":"mac","session":"S1","bytes":42,"outcome":"queued",'
          '"best_lane":"lane-x","resolvers":["res-a"],"winner":"res-a",'
          '"rung":null,"reason":null,"lab":true}',
        );
      },
    );

    // ---- The ladder now DECIDES the winner; the card reads WHY (one
    // word), one branch per test, existing fakes, no socket. ----

    test('B1 a lane above threshold wins; rung/reason from the ladder '
        '(limited/down)', () async {
      final lanes = ScriptedLanes()..liveUp = true; // wss up, https dead
      final cards = RecordingCardSink();
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: fast,
        openLanes: () async => lanes,
        cardSink: cards,
      );

      final state = await courier.send(
        Uint8List.fromList([1, 2, 3]),
        kind: 'typed',
      );

      expect(state, LetterState.arrived);
      final card = cards.cards.single.toJson();
      expect(card['best_lane'], ResilientLaneIds.webSocketRelay);
      expect(card['rung'], LetterLadderRung.limited.name);
      expect(card['reason'], 'down');
      await courier.dispose();
    });

    test('B2 wss+https dead, the door alive: the door carries it '
        '(weak/dead, no live lane, no fresh probe)', () async {
      final lanes = ScriptedLanes()
        ..doorUp = true
        ..doorFresh = true; // the door sits at -0.14, above every dead lane
      final cards = RecordingCardSink();
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: fast,
        openLanes: () async => lanes,
        cardSink: cards,
      );

      final state = await courier.send(
        Uint8List.fromList([1, 2, 3]),
        kind: 'typed',
      );

      expect(state, LetterState.arrived);
      final card = cards.cards.single.toJson();
      expect(card['best_lane'], ResilientLaneIds.txtQuery);
      expect(card['rung'], LetterLadderRung.weak.name);
      expect(card['reason'], 'dead');
      await courier.dispose();
    });

    test('B3 all three closed: queued + parked, best_lane null, '
        'closed/dead, nothing delivered', () async {
      final clock = ManualClock();
      final store = MemoryLetterQueueStore();
      final cards = RecordingCardSink();
      final lanes = ScriptedLanes(); // every lane dead by default
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: fast,
        now: () => clock.now,
        queue: LetterQueue(store),
        openLanes: () async => lanes,
        wait: clock.wait,
        schedulePeriodic: clock.schedule,
        cardSink: cards,
      );

      final state = await courier.send(
        Uint8List.fromList([1, 2, 3]),
        kind: 'typed',
      );

      expect(state, LetterState.queued);
      expect(courier.queue.length, 1); // parked, waiting on the watch
      expect(store.contents, isNotEmpty); // durably stored (cc7ffd4 queue)
      expect(lanes.delivered, isEmpty); // never even offered to the fabric
      final card = cards.cards.single.toJson();
      expect(card['outcome'], 'queued');
      expect(card['best_lane'], isNull);
      expect(card['rung'], LetterLadderRung.closed.name);
      expect(card['reason'], 'dead');
      await courier.dispose();
    });

    test('B4 latch: a deliver that gave up pins the rung at weak/late, and '
        'a later healthy reply does not raise it', () async {
      const slow = LetterCourierBudget(
        select: Duration(milliseconds: 300),
        carry: Duration(milliseconds: 50),
        refreshEvery: Duration(milliseconds: 50),
      );
      final cards = RecordingCardSink();
      final lanes = ScriptedLanes()..liveUp = true; // wss up -> limited
      lanes.holdDeliver = Completer<DeliveryOutcome>();
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: slow,
        openLanes: () async => lanes,
        cardSink: cards,
      );

      // First send: the deliver never answers inside carry -> "gave up".
      final first = await courier.send(
        Uint8List.fromList('one'.codeUnits),
        kind: 'typed',
      );
      expect(first, LetterState.notDelivered);
      // The latch fired: the current reading drops to weak/late.
      expect(courier.ladderStatus.value!.rung, LetterLadderRung.weak);
      expect(courier.ladderStatus.value!.reason, 'late');

      // The late answer is healthy — it must NOT lift the rung back.
      lanes.holdDeliver!.complete(DeliveryOutcome.sentLive);
      await Future<void>.delayed(Duration.zero);
      expect(courier.ladderStatus.value!.rung, LetterLadderRung.weak);

      // A fresh, immediately-healthy send: still weak on the card, not
      // limited — the degraded run stays marked degraded.
      lanes.holdDeliver = null;
      final second = await courier.send(
        Uint8List.fromList('two'.codeUnits),
        kind: 'typed',
      );
      expect(second, LetterState.arrived);
      final card = cards.cards.last.toJson();
      expect(card['rung'], LetterLadderRung.weak.name);
      expect(card['reason'], 'late');
      await courier.dispose();
    });

    test('the decision journal is best effort: a card sink that throws '
        'never breaks the Send (sync throw and async error)', () async {
      for (final sink in <LetterCardSink>[
        _ThrowingCardSink(),
        _FutureErrorCardSink(),
      ]) {
        final lanes = ScriptedLanes()..liveUp = true;
        final courier = LetterCourier(
          endpoints: () => throw StateError('scripted lanes, never assembled'),
          budget: fast,
          openLanes: () async => lanes,
          cardSink: sink,
        );

        final state = await courier.send(
          Uint8List.fromList([1, 2, 3]),
          kind: 'typed',
        );

        expect(state, LetterState.arrived);
        await courier.dispose();
      }
    });
  });

  // ---- Adversarial challenge matrix (test-only hardening, HEAD 565ebde).
  // Each case subjects the deciding send path (letter_courier.dart send ->
  // letter_status_ladder.dart classify) to a pressure the B1-B4 branch
  // tests do not. Hard assertions pin current behaviour; two cases
  // (C4 and C5) pin behaviour the design flags as a candidate defect for
  // the owner. C11 now passes: the multi-part give-up latches weak/late,
  // symmetric with B4. Existing fakes only, no socket. ----
  group('adversarial challenge matrix — the deciding send under pressure', () {
    const slow = LetterCourierBudget(
      select: Duration(milliseconds: 300),
      carry: Duration(milliseconds: 50),
      refreshEvery: Duration(milliseconds: 50),
    );

    test('C1 flap up->down->up without a timeout never latches; the parked '
        'letter drains on recovery and writes no card', () async {
      final clock = ManualClock();
      final store = MemoryLetterQueueStore();
      final cards = RecordingCardSink();
      final lanes = ScriptedLanes();
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: fast,
        now: () => clock.now,
        queue: LetterQueue(store),
        openLanes: () async => lanes,
        wait: clock.wait,
        schedulePeriodic: clock.schedule,
        cardSink: cards,
      );

      // A: wss up -> arrives, limited/down.
      lanes.liveUp = true;
      expect(
        await courier.send(Uint8List.fromList([1]), kind: 'typed'),
        LetterState.arrived,
      );
      expect(cards.cards.last.toJson()['rung'], LetterLadderRung.limited.name);
      expect(cards.cards.last.toJson()['reason'], 'down');

      // B: everything down -> parked closed/dead, nothing delivered.
      lanes.liveUp = false;
      expect(
        await courier.send(Uint8List.fromList([2]), kind: 'typed'),
        LetterState.queued,
      );
      expect(courier.queue.length, 1);
      expect(clock.periodic, isNotNull);
      expect(cards.cards.last.toJson()['rung'], LetterLadderRung.closed.name);
      expect(cards.cards.last.toJson()['reason'], 'dead');

      // C: wss up again -> arrives; the latch never fired, so it reads
      // limited/down, NOT weak/late.
      lanes.liveUp = true;
      expect(
        await courier.send(Uint8List.fromList([3]), kind: 'typed'),
        LetterState.arrived,
      );
      expect(courier.ladderStatus.value!.rung, LetterLadderRung.limited);
      expect(courier.ladderStatus.value!.reason, 'down');
      expect(cards.cards.last.toJson()['reason'], isNot('late'));

      // The watch drains B via wss; a drain writes no card.
      await clock.tick();
      expect(courier.queue.isEmpty, isTrue);
      expect(clock.periodic, isNull);
      expect(lanes.delivered, hasLength(3)); // A, C, B-drain
      expect(cards.cards, hasLength(3)); // A, B, C — the drain adds none
      await courier.dispose();
    });

    test('C2 a single timeout mid-flap latches; the latch holds across the '
        'recovery and a later parked letter still reads closed', () async {
      final clock = ManualClock();
      final store = MemoryLetterQueueStore();
      final cards = RecordingCardSink();
      final lanes = ScriptedLanes()..liveUp = true;
      lanes.holdDeliver = Completer<DeliveryOutcome>();
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: slow,
        now: () => clock.now,
        queue: LetterQueue(store),
        openLanes: () async => lanes,
        wait: clock.wait,
        schedulePeriodic: clock.schedule,
        cardSink: cards,
      );

      // A: the deliver never answers inside carry -> gave up, latch on.
      expect(
        await courier.send(Uint8List.fromList([1]), kind: 'typed'),
        LetterState.notDelivered,
      );
      expect(cards.cards.last.toJson()['rung'], LetterLadderRung.weak.name);
      expect(cards.cards.last.toJson()['reason'], 'late');

      // A's late answer is healthy: recorded, but must not lift the rung.
      lanes.holdDeliver!.complete(DeliveryOutcome.sentLive);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(courier.ledger.records.value, hasLength(1)); // A
      expect(courier.ladderStatus.value!.reason, 'late');

      // B: everything down -> closed/dead; closed outranks weak, the latch
      // leaves it untouched.
      lanes.holdDeliver = null;
      lanes.liveUp = false;
      expect(
        await courier.send(Uint8List.fromList([2]), kind: 'typed'),
        LetterState.queued,
      );
      expect(cards.cards.last.toJson()['rung'], LetterLadderRung.closed.name);
      expect(cards.cards.last.toJson()['reason'], 'dead');

      // C: wss up again -> arrives, but the latch pins it weak/late.
      lanes.liveUp = true;
      expect(
        await courier.send(Uint8List.fromList([3]), kind: 'typed'),
        LetterState.arrived,
      );
      expect(cards.cards.last.toJson()['rung'], LetterLadderRung.weak.name);
      expect(cards.cards.last.toJson()['reason'], 'late');

      // The watch drains B via wss; the reading stays weak/late.
      await clock.tick();
      expect(courier.ladderStatus.value!.rung, LetterLadderRung.weak);
      expect(courier.ladderStatus.value!.reason, 'late');
      expect(courier.queue.isEmpty, isTrue);
      expect(courier.ledger.records.value, hasLength(3)); // A, C, B-drain
      await courier.dispose();
    });

    test('C3 resolver poisoning: three answers home but no nonce logged '
        'reads closed/nonce and parks; the drain never re-probes', () async {
      final clock = ManualClock();
      final store = MemoryLetterQueueStore();
      final cards = RecordingCardSink();
      var probeCalls = 0;
      final lanes = DoorProbingLanes()
        ..doorUp = true
        ..answer = () {
          probeCalls++;
          return const TxtProbeOutcome(
            groupId: 'g',
            answers: [
              TxtProbeAnswer(index: 0, label: 'udp53:8.8.8.8:53', nonce: 'aa'),
              TxtProbeAnswer(index: 1, label: 'doh:a', nonce: 'bb'),
              TxtProbeAnswer(index: 2, label: 'doh:b', nonce: 'cc'),
            ],
            winnerIndex: null,
          );
        };
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: fast,
        now: () => clock.now,
        queue: LetterQueue(store),
        openLanes: () async => lanes,
        wait: clock.wait,
        schedulePeriodic: clock.schedule,
        cardSink: cards,
      );

      expect(
        await courier.send(Uint8List.fromList([1, 2, 3]), kind: 'typed'),
        LetterState.queued,
      );
      expect(lanes.delivered, isEmpty); // parked before any carry
      final card = cards.cards.single.toJson();
      expect(card['outcome'], 'queued');
      expect(card['best_lane'], ResilientLaneIds.txtQuery);
      expect(card['resolvers'], ['udp53:8.8.8.8:53', 'doh:a', 'doh:b']);
      expect(card['winner'], isNull);
      expect(card['rung'], LetterLadderRung.closed.name);
      expect(card['reason'], 'nonce');
      expect(
        courier.status.value!.detail,
        contains('closed · next probe in 0s'),
      );
      expect(courier.queue.length, 1);
      expect(clock.periodic, isNotNull);
      expect(probeCalls, 1);

      // The door comes back with a winning answer, but the drain never
      // consults it: the banner reads weak/dead (the drain path passes no
      // probe, L1215), NOT withCourier/door. Documented wording trap.
      lanes.answer = () {
        probeCalls++;
        return const TxtProbeOutcome(
          groupId: 'g2',
          answers: [TxtProbeAnswer(index: 0, label: 'doh:a', nonce: 'dd')],
          winnerIndex: 0,
        );
      };
      await clock.tick();
      expect(courier.status.value!.state, LetterState.arrived);
      expect(probeCalls, 1); // the drain did not probe
      expect(courier.ladderStatus.value!.rung, LetterLadderRung.weak);
      expect(courier.ladderStatus.value!.reason, 'dead');
      expect(courier.status.value!.detail, isNot(contains('closed')));
      expect(lanes.delivered, hasLength(1));
      await courier.dispose();
    });

    test(
      'C4 mixed door history lowers the reason only; a healthy live '
      'network keeps its rung (normal) and the winner (owner decision #1)',
      () async {
        // wss+https both healthy: without door history this reads normal/ok.
        // Mixed door history (ratio 1/6) must NOT demote it — only the reason
        // drops to 'mixed'; the winner stays the live lane.
        final doorStore = _MemoryStorage();
        doorStore.data = <String, Object?>{
          'test-net': <String, Object?>{
            'resolvers': <String, Object?>{
              'doh:a': <String, Object?>{'attempts': 4, 'wins': 1},
              'udp53:x': <String, Object?>{'attempts': 2, 'wins': 0},
            },
          },
        };
        final cards = RecordingCardSink();
        final lanes = ScriptedLanes()
          ..liveUp = true
          ..httpsUp = true;
        final courier = LetterCourier(
          endpoints: () => throw StateError('scripted lanes, never assembled'),
          budget: fast,
          openLanes: () async => lanes,
          networkResolver: const _FixedNetwork('test-net'),
          rungLadder: LetterRungLadder(_MemoryStorage()),
          doorResolverLadder: DoorResolverLadder(doorStore),
          cardSink: cards,
        );

        expect(
          await courier.send(Uint8List.fromList([1, 2, 3]), kind: 'typed'),
          LetterState.arrived,
        );
        final card = cards.cards.single.toJson();
        expect(card['best_lane'], ResilientLaneIds.webSocketRelay); // live won
        expect(card['rung'], LetterLadderRung.normal.name); // rung unchanged
        expect(card['reason'], 'mixed'); // reason lowered (ratio 1/6)
        await courier.dispose();
      },
    );

    test('C4-twin a door history of all-wins (1.0) or all-misses (0) does '
        'NOT demote a healthy live network — both read normal/ok', () async {
      Future<String?> rungFor(Map<String, Object?> resolvers) async {
        final doorStore = _MemoryStorage();
        doorStore.data = <String, Object?>{
          'test-net': <String, Object?>{'resolvers': resolvers},
        };
        final cards = RecordingCardSink();
        final lanes = ScriptedLanes()
          ..liveUp = true
          ..httpsUp = true;
        final courier = LetterCourier(
          endpoints: () => throw StateError('scripted lanes, never assembled'),
          budget: fast,
          openLanes: () async => lanes,
          networkResolver: const _FixedNetwork('test-net'),
          rungLadder: LetterRungLadder(_MemoryStorage()),
          doorResolverLadder: DoorResolverLadder(doorStore),
          cardSink: cards,
        );
        await courier.send(Uint8List.fromList([1]), kind: 'typed');
        final rung = cards.cards.single.toJson()['rung'] as String?;
        await courier.dispose();
        return rung;
      }

      expect(
        await rungFor(<String, Object?>{
          'doh:a': <String, Object?>{'attempts': 3, 'wins': 3},
        }),
        LetterLadderRung.normal.name,
      );
      expect(
        await rungFor(<String, Object?>{
          'udp53:x': <String, Object?>{'attempts': 2, 'wins': 0},
        }),
        LetterLadderRung.normal.name,
      );
    });

    test('C5 probe() and Send read the SAME door history (owner decision '
        '#2): both limited/mixed on the same snapshot', () async {
      final doorStore = _MemoryStorage();
      doorStore.data = <String, Object?>{
        'test-net': <String, Object?>{
          'resolvers': <String, Object?>{
            'doh:a': <String, Object?>{'attempts': 4, 'wins': 1},
            'udp53:x': <String, Object?>{'attempts': 2, 'wins': 0},
          },
        },
      };
      final cards = RecordingCardSink();
      final lanes = ScriptedLanes()..liveUp = true; // https dead -> limited
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: fast,
        openLanes: () async => lanes,
        networkResolver: const _FixedNetwork('test-net'),
        rungLadder: LetterRungLadder(_MemoryStorage()),
        doorResolverLadder: DoorResolverLadder(doorStore),
        cardSink: cards,
      );

      // probe() now resolves the same label Send uses, so it reads the mixed
      // door history too: limited (https down) with the reason lowered.
      await courier.probe();
      expect(courier.ladderStatus.value!.rung, LetterLadderRung.limited);
      expect(courier.ladderStatus.value!.reason, 'mixed');

      // The Send path reads the same history -> the card agrees with probe().
      expect(
        await courier.send(Uint8List.fromList([1, 2, 3]), kind: 'typed'),
        LetterState.arrived,
      );
      final card = cards.cards.single.toJson();
      expect(card['rung'], LetterLadderRung.limited.name);
      expect(card['reason'], 'mixed');
      await courier.dispose();
    });

    test(
      'C6 a throttled-but-alive relay reads weak/slow; the 0.15 boundary '
      'reads limited/down; a relay at the dead line parks closed/dead',
      () async {
        Future<LetterLadderStatus> sendWith(
          double wssScore, {
          bool doorUp = true,
        }) async {
          final clock = ManualClock();
          final lanes = _ThrottledLanes()
            ..liveUp = true
            ..doorUp = doorUp
            ..wssScore = wssScore;
          final courier = LetterCourier(
            endpoints: () =>
                throw StateError('scripted lanes, never assembled'),
            budget: fast,
            now: () => clock.now,
            queue: LetterQueue(MemoryLetterQueueStore()),
            openLanes: () async => lanes,
            wait: clock.wait,
            schedulePeriodic: clock.schedule,
          );
          final state = await courier.send(
            Uint8List.fromList([1]),
            kind: 'typed',
          );
          expect(
            state,
            wssScore > letterDeadAtOrBelow
                ? LetterState.arrived
                : LetterState.queued,
          );
          final status = courier.ladderStatus.value!;
          await courier.dispose();
          return status;
        }

        // 0.05: throttled, but the live lane still carried it.
        final slowRelay = await sendWith(0.05);
        expect(slowRelay.rung, LetterLadderRung.weak);
        expect(slowRelay.reason, 'slow');

        // 0.14: still strictly below 0.15 -> slow.
        final justSlow = await sendWith(0.14);
        expect(justSlow.rung, LetterLadderRung.weak);
        expect(justSlow.reason, 'slow');

        // 0.15: NOT below 0.15 (strict < at L114) -> limited/down.
        final limited = await sendWith(0.15);
        expect(limited.rung, LetterLadderRung.limited);
        expect(limited.reason, 'down');

        // -1.0 exactly: letterLaneHasPath is false (strict > at L94), so the
        // lane the fabric ranks first is not usable -> parked closed/dead.
        final dead = await sendWith(-1.0, doorUp: false);
        expect(dead.rung, LetterLadderRung.closed);
        expect(dead.reason, 'dead');
      },
    );

    test('C7 a fresh door carries while a dead wss cannot; and when the '
        'probe returns null at probe time the door still carries it '
        '(weak/dead, no park)', () async {
      // Part 1: fresh door (-0.14) + a winning probe -> withCourier/door.
      final cards1 = RecordingCardSink();
      final lanes1 = DoorProbingLanes()
        ..doorUp = true
        ..doorFresh = true
        ..answer = () => const TxtProbeOutcome(
          groupId: 'g',
          answers: [
            TxtProbeAnswer(index: 0, label: 'res-a', nonce: 'aa'),
            TxtProbeAnswer(index: 1, label: 'res-b', nonce: 'bb'),
          ],
          winnerIndex: 1,
        );
      final courier1 = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: fast,
        openLanes: () async => lanes1,
        cardSink: cards1,
      );
      expect(
        await courier1.send(Uint8List.fromList([1, 2, 3]), kind: 'typed'),
        LetterState.arrived,
      );
      final card1 = cards1.cards.single.toJson();
      expect(card1['best_lane'], ResilientLaneIds.txtQuery);
      expect(card1['rung'], LetterLadderRung.withCourier.name);
      expect(card1['reason'], 'door');
      expect(card1['winner'], 'res-b');
      await courier1.dispose();

      // Part 2: the valve is absent at probe time (probeDoor -> null). The
      // door still carries the letter; the reading is weak/dead and
      // nothing is parked. Not covered by any existing test.
      final cards2 = RecordingCardSink();
      final lanes2 = DoorProbingLanes()
        ..doorUp = true
        ..doorFresh = true
        ..answer = () => null;
      final courier2 = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: fast,
        openLanes: () async => lanes2,
        cardSink: cards2,
      );
      expect(
        await courier2.send(Uint8List.fromList([1, 2, 3]), kind: 'typed'),
        LetterState.arrived,
      );
      final card2 = cards2.cards.single.toJson();
      expect(card2['best_lane'], ResilientLaneIds.txtQuery);
      expect(card2['rung'], LetterLadderRung.weak.name);
      expect(card2['reason'], 'dead');
      expect(lanes2.delivered, hasLength(1)); // carried, not parked
      await courier2.dispose();
    });

    test('C8 a healthy late reply never raises the rung, and a letter '
        'drained right after the latch stays weak/late', () async {
      final clock = ManualClock();
      final store = MemoryLetterQueueStore();
      final cards = RecordingCardSink();
      final lanes = ScriptedLanes()..liveUp = true;
      lanes.holdDeliver = Completer<DeliveryOutcome>();
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: slow,
        now: () => clock.now,
        queue: LetterQueue(store),
        openLanes: () async => lanes,
        wait: clock.wait,
        schedulePeriodic: clock.schedule,
        cardSink: cards,
      );

      // A gives up -> latch on (card 1).
      expect(
        await courier.send(Uint8List.fromList([1]), kind: 'typed'),
        LetterState.notDelivered,
      );

      // B parks closed/dead while A is still in flight (card 2).
      lanes.liveUp = false;
      expect(
        await courier.send(Uint8List.fromList([2]), kind: 'typed'),
        LetterState.queued,
      );
      expect(courier.queue.length, 1);

      // A's late reply is healthy: recorded + arrived "late", but no card
      // and no raise.
      lanes.holdDeliver!.complete(DeliveryOutcome.sentLive);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(courier.status.value!.state, LetterState.arrived);
      expect(courier.status.value!.detail, contains('late'));
      expect(cards.cards, hasLength(2)); // settleLate writes no card
      expect(courier.ledger.records.value, hasLength(1)); // A
      // settleLate updates only `status`, not the ladder reading, so B's
      // park reading (closed/dead) survives — and was NOT raised by A's
      // healthy late arrival. (The design predicted weak/late here; that
      // was a MEDIUM-confidence guess B's intervening park overrides.)
      expect(courier.ladderStatus.value!.rung, LetterLadderRung.closed);
      expect(courier.ladderStatus.value!.reason, 'dead');

      // Drain B on a now-healthy wss: the latch pulls it back to weak/late.
      lanes.liveUp = true;
      lanes.holdDeliver = null;
      await clock.tick();
      expect(courier.ledger.records.value, hasLength(2)); // A + B
      expect(courier.ladderStatus.value!.rung, LetterLadderRung.weak);
      expect(courier.ladderStatus.value!.reason, 'late');
      expect(courier.queue.isEmpty, isTrue);
      expect(clock.periodic, isNull);
      await courier.dispose();
    });

    test(
      'C9 a late queuedForLater after the latch re-parks exactly once '
      'and arms the watch; the drain carries with the latched reading',
      () async {
        final clock = ManualClock();
        final store = MemoryLetterQueueStore();
        final lanes = ScriptedLanes()..liveUp = true;
        lanes.holdDeliver = Completer<DeliveryOutcome>();
        final courier = LetterCourier(
          endpoints: () => throw StateError('scripted lanes, never assembled'),
          budget: slow,
          now: () => clock.now,
          queue: LetterQueue(store),
          openLanes: () async => lanes,
          wait: clock.wait,
          schedulePeriodic: clock.schedule,
        );

        expect(
          await courier.send(Uint8List.fromList([1, 2, 3]), kind: 'typed'),
          LetterState.notDelivered,
        );

        // The late verdict is "parked": custody moves to the durable queue
        // once (reclaim + enqueue), and the watch is armed.
        lanes.holdDeliver!.complete(DeliveryOutcome.queuedForLater);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(lanes.reclaimed, hasLength(1));
        expect(lanes.reclaimed.single, startsWith('letter-'));
        expect(courier.queue.length, 1);
        expect(store.contents, isNotEmpty);
        expect(clock.periodic, isNotNull);

        // The door comes back; the drain carries it, reading weak/late.
        lanes.holdDeliver = null;
        lanes.liveUp = true;
        await clock.tick();
        expect(courier.status.value!.state, LetterState.arrived);
        expect(courier.ladderStatus.value!.reason, 'late');
        expect(lanes.delivered, hasLength(2)); // the timed-out A + the drain
        expect(courier.queue.isEmpty, isTrue);
        await courier.dispose();
      },
    );

    test('C10 classify pins the precedence the courier relies on: nonce '
        'beats a live lane and a door; mixed beats a door', () {
      ConnectivitySnapshot liveUp() {
        final lanes = [
          LaneStatus(
            id: ResilientLaneIds.webSocketRelay,
            eligible: true,
            score: 0.9,
          ),
          LaneStatus(
            id: ResilientLaneIds.httpLongPoll,
            eligible: true,
            score: 0.9,
          ),
          LaneStatus(id: ResilientLaneIds.txtQuery, eligible: true, score: 0.6),
        ];
        return ConnectivitySnapshot(
          mode: FabricMode.live,
          lanes: lanes,
          bestLaneId: ResilientLaneIds.webSocketRelay,
          pendingBundles: 0,
          atMs: 0,
        );
      }

      const noNonce = TxtProbeOutcome(
        groupId: 'g',
        answers: [TxtProbeAnswer(index: 0, label: 'r', nonce: 'n')],
        winnerIndex: null,
      );
      const reached = TxtProbeOutcome(
        groupId: 'g',
        answers: [TxtProbeAnswer(index: 0, label: 'r', nonce: 'n')],
        winnerIndex: 0,
      );
      final mixed = {'r': (wins: 1, attempts: 6)};

      // A probe that logged no nonce is closed/nonce even with a live lane.
      final a = classifyLetterLadder(snapshot: liveUp(), lastProbe: noNonce);
      expect(a.rung, LetterLadderRung.closed);
      expect(a.reason, 'nonce');

      // ...and even with mixed door history present (nonce still wins).
      final b = classifyLetterLadder(
        snapshot: liveUp(),
        lastProbe: noNonce,
        doorHistory: mixed,
      );
      expect(b.rung, LetterLadderRung.closed);
      expect(b.reason, 'nonce');

      // Reached-server probe + mixed history over a healthy live lane: the
      // live lane keeps its rung (normal), only the reason drops to 'mixed'
      // (owner decision #1; parts a/b show 'closed' still outranks).
      final c = classifyLetterLadder(
        snapshot: liveUp(),
        lastProbe: reached,
        doorHistory: mixed,
      );
      expect(c.rung, LetterLadderRung.normal);
      expect(c.reason, 'mixed');
    });

    test('probe() and the watch tick read the same door history as Send '
        '(owner decision #2): a drained letter reads limited/mixed', () async {
      // Shape of B3: all three lanes dead at Send -> queued + parked. Then a
      // live lane comes up (https still down) and the watch drains it. The
      // tick's ladder read must see the mixed door history, exactly as Send
      // would, so the drained letter and a fresh probe() agree.
      final clock = ManualClock();
      final doorStore = _MemoryStorage();
      doorStore.data = <String, Object?>{
        'test-net': <String, Object?>{
          'resolvers': <String, Object?>{
            'doh:a': <String, Object?>{'attempts': 4, 'wins': 1},
            'udp53:x': <String, Object?>{'attempts': 2, 'wins': 0},
          },
        },
      };
      final cards = RecordingCardSink();
      final lanes = ScriptedLanes(); // every lane dead at first
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: fast,
        now: () => clock.now,
        queue: LetterQueue(MemoryLetterQueueStore()),
        openLanes: () async => lanes,
        wait: clock.wait,
        schedulePeriodic: clock.schedule,
        networkResolver: const _FixedNetwork('test-net'),
        rungLadder: LetterRungLadder(_MemoryStorage()),
        doorResolverLadder: DoorResolverLadder(doorStore),
        cardSink: cards,
      );

      expect(
        await courier.send(Uint8List.fromList([1, 2, 3]), kind: 'typed'),
        LetterState.queued, // nothing reachable -> parked
      );

      // A live lane comes up; the watch's tick drains the parked letter.
      lanes.liveUp = true; // https stays down -> limited
      await clock.tick();

      expect(lanes.delivered, hasLength(1)); // the tick carried it
      // The tick's _updateLadder read the mixed door history, same as Send.
      expect(courier.ladderStatus.value!.rung, LetterLadderRung.limited);
      expect(courier.ladderStatus.value!.reason, 'mixed');

      // A fresh probe() on the same courier reads the same snapshot+history.
      await courier.probe();
      expect(courier.ladderStatus.value!.rung, LetterLadderRung.limited);
      expect(courier.ladderStatus.value!.reason, 'mixed');
      await courier.dispose();
    });

    test('C11 a multi-part letter that exhausts its retries latches weak/late '
        'like a single-part give-up', () async {
      // _carryParts now carries an `outranBudget` flag from the per-part
      // timeout branch to the whole-letter give-up, which calls
      // _markDegraded once — symmetric with the single-part _carry (L917).
      // A >maxPayloadBytes letter that times out on every part ends
      // notDelivered AND latched weak/late, matching B4.
      final lanes = ScriptedLanes()
        ..liveUp = true
        ..holdAll = true; // every part hangs; each attempt times out
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: slow,
        openLanes: () async => lanes,
      );
      final state = await courier.send(
        Uint8List(TxtQueryLane.maxPayloadBytes + 1),
        kind: 'photo',
      );
      expect(state, LetterState.notDelivered);
      // The latch fired: the current reading drops to weak/late, the way
      // a single-part give-up does in B4.
      expect(courier.ladderStatus.value!.rung, LetterLadderRung.weak);
      expect(courier.ladderStatus.value!.reason, 'late');
      await courier.dispose();
    });

    test('C12 complement of C11: a multi-part letter that times out once then '
        'lands on retry delivers and does NOT latch weak/late', () async {
      // The mirror of C11/B4: here one part outruns budget.carry ONCE and
      // then LANDS on retry, so the whole letter delivers (fatal == null).
      // _markDegraded (letter_courier.dart L1092) is reachable only inside
      // the `if (fatal != null)` give-up block, so it never fires. The run
      // must read its normal live-lane rung (limited/down), not weak/late.
      final cards = RecordingCardSink();
      final lanes = _FirstPartHangsLanes()..liveUp = true; // wss up -> limited
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        budget: slow,
        openLanes: () async => lanes,
        cardSink: cards,
      );
      final state = await courier.send(
        Uint8List(TxtQueryLane.maxPayloadBytes + 1), // 2 parts
        kind: 'photo',
      );
      expect(
        state,
        LetterState.arrived,
        reason: courier.notes.value.join('\n'),
      );
      // p0 hung (timed out), p1 landed, p0-r1 is the retry that landed: the
      // retry carries the same index under a fresh id.
      expect(lanes.delivered.map((d) => d.$1), [
        endsWith('-p0'),
        endsWith('-p1'),
        endsWith('-p0-r1'),
      ]);
      expect(
        courier.notes.value,
        contains(contains('letter 1/2 gave up (try 1)')),
      );
      expect(
        courier.ledger.records.value.single.bytes,
        hasLength(TxtQueryLane.maxPayloadBytes + 1),
      );
      // The latch did NOT fire: normal live-lane reading, not weak/late.
      expect(courier.ladderStatus.value!.rung, LetterLadderRung.limited);
      expect(courier.ladderStatus.value!.reason, 'down');
      expect(courier.ladderStatus.value!.reason, isNot('late'));
      expect(cards.cards.last.toJson()['rung'], LetterLadderRung.limited.name);
      expect(cards.cards.last.toJson()['reason'], 'down');
      // A second, immediately-healthy send still reads limited/down (B4's
      // mirror: nothing was latched to carry over).
      expect(
        await courier.send(Uint8List.fromList([1]), kind: 'typed'),
        LetterState.arrived,
      );
      expect(courier.ladderStatus.value!.reason, 'down');
      await courier.dispose();
    });
  });
}

/// A [ScriptedLanes] whose wss score the test sets directly, to reach the
/// throttled-but-alive band (0 < score < 0.15) and the exact dead line
/// (-1.0) the binary fake cannot script. Ranking and mode stay the
/// parent's; only the relay's score moves.
class _ThrottledLanes extends ScriptedLanes {
  double wssScore = 0.05;

  @override
  ConnectivitySnapshot get snapshot {
    final wss = LaneStatus(
      id: ResilientLaneIds.webSocketRelay,
      eligible: true,
      score: wssScore,
    );
    final https = LaneStatus(
      id: ResilientLaneIds.httpLongPoll,
      eligible: true,
      score: httpsUp ? 0.9 : -1.10,
    );
    final door = LaneStatus(
      id: ResilientLaneIds.txtQuery,
      eligible: true,
      score: doorUp ? (doorFresh ? -0.14 : 0.6) : -1.15,
    );
    final lanes = liveUp
        ? [wss, door, https]
        : doorUp
        ? [door, wss, https]
        : [wss, https, door];
    return ConnectivitySnapshot(
      mode: liveUp
          ? FabricMode.live
          : doorUp
          ? FabricMode.degraded
          : FabricMode.storeAndForward,
      lanes: lanes,
      bestLaneId: lanes.first.id,
      pendingBundles: 0,
      atMs: 0,
    );
  }
}

/// A [ScriptedLanes] whose FIRST deliver of part 0 hangs forever (the future
/// never completes), so the carry timeout fires exactly once; every other
/// deliver — the other part and the p0 retry — answers through the parent.
/// The timeout does not cancel the hung future (letter_courier.dart L1026),
/// exactly as on the rig: the part is simply retried under a fresh id.
class _FirstPartHangsLanes extends ScriptedLanes {
  bool hung = false;

  @override
  Future<DeliveryOutcome> deliver(
    Uint8List payload, {
    required String bundleId,
  }) {
    if (!hung && bundleId.endsWith('-p0')) {
      hung = true;
      delivered.add((bundleId, payload));
      return Completer<DeliveryOutcome>().future; // outruns budget.carry
    }
    return super.deliver(payload, bundleId: bundleId);
  }
}

/// Records every card the courier appends; no disk.
class RecordingCardSink implements LetterCardSink {
  final List<LetterCard> cards = [];

  @override
  Future<void> append(LetterCard card) async => cards.add(card);
}

/// A sink whose disk is "full": [append] throws SYNCHRONOUSLY the moment
/// it is called — the arrow body runs before any future is returned, so
/// the throw escapes into the caller unless the courier guards it.
class _ThrowingCardSink implements LetterCardSink {
  @override
  Future<void> append(LetterCard card) => throw StateError('disk full (sync)');
}

/// A sink whose append future completes with an error (async disk fault):
/// becomes an uncaught zone error unless the courier swallows it.
class _FutureErrorCardSink implements LetterCardSink {
  @override
  Future<void> append(LetterCard card) async =>
      throw StateError('disk full (async)');
}

/// A lane set the test scripts: which lane is up decides the snapshot,
/// [outcome] decides every deliver's verdict, and every deliver is kept.
class ScriptedLanes implements LetterLanes {
  bool liveUp = false;
  bool doorUp = false;

  /// Defaults dead like every other test expects; only the new ladder
  /// tests raise it, to reach a snapshot where BOTH non-door lanes are
  /// healthy (the ladder's "normal" rung).
  bool httpsUp = false;

  /// The door answers but has one reply's worth of health: the fabric
  /// scores it 0.01 − 0.15 = −0.14, still above every dead lane.
  bool doorFresh = false;
  DeliveryOutcome outcome = DeliveryOutcome.sentLive;

  /// When set, each deliver takes the next outcome here (then [outcome]).
  final List<DeliveryOutcome> outcomes = [];
  final List<(String, Uint8List)> delivered = [];
  final List<String> reclaimed = [];
  int refreshes = 0;

  /// When set, every refresh waits on it: the test holds the fabric's
  /// probing open the way a down door's DNS round does.
  Completer<void>? refreshGate;

  /// When set, every deliver answers with it instead of [outcome]: the
  /// test decides when — and whether — the fabric comes back.
  Completer<DeliveryOutcome>? holdDeliver;

  /// When true, every deliver is parked here until the test completes it:
  /// the list's length IS the number of parts in flight.
  bool holdAll = false;
  final List<(String, Completer<DeliveryOutcome>)> held = [];
  int maxInFlight = 0;

  @override
  Future<void> refresh() async {
    refreshes++;
    final gate = refreshGate;
    if (gate != null) await gate.future;
  }

  @override
  ConnectivitySnapshot get snapshot {
    final wss = LaneStatus(
      id: ResilientLaneIds.webSocketRelay,
      eligible: true,
      score: liveUp ? 0.9 : -1.05,
    );
    final https = LaneStatus(
      id: ResilientLaneIds.httpLongPoll,
      eligible: true,
      score: httpsUp ? 0.9 : -1.10,
    );
    final door = LaneStatus(
      id: ResilientLaneIds.txtQuery,
      eligible: true,
      score: doorUp ? (doorFresh ? -0.14 : 0.6) : -1.15,
    );
    // Best first, the way the fabric ranks: a live lane over the door,
    // the door over dead lanes, and dead lanes in cost order.
    final lanes = liveUp
        ? [wss, door, https]
        : doorUp
        ? [door, wss, https]
        : [wss, https, door];
    return ConnectivitySnapshot(
      mode: liveUp
          ? FabricMode.live
          : doorUp
          ? FabricMode.degraded
          : FabricMode.storeAndForward,
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
  }) async {
    delivered.add((bundleId, payload));
    if (holdAll) {
      final c = Completer<DeliveryOutcome>();
      this.held.add((bundleId, c));
      if (this.held.length > maxInFlight) maxInFlight = this.held.length;
      return c.future.whenComplete(() {
        this.held.removeWhere((h) => identical(h.$2, c));
      });
    }
    final held = holdDeliver;
    if (held != null) return held.future;
    if (outcomes.isNotEmpty) return outcomes.removeAt(0);
    return outcome;
  }

  @override
  void reclaim(String bundleId) => reclaimed.add(bundleId);

  @override
  bool get hasDoor => true;

  @override
  String? get doorSessionId => 'ABC123';

  @override
  Future<void> dispose() async {}
}

/// A [ScriptedLanes] that also answers door probes — a SEPARATE class so
/// every existing test (which relies on `lanes is LetterDoorProbe` being
/// false) is untouched.
class DoorProbingLanes extends ScriptedLanes implements LetterDoorProbe {
  TxtProbeOutcome? Function()? answer;

  @override
  Future<TxtProbeOutcome?> probeDoor() async => answer?.call();
}

/// Time the test drives: [wait] advances the clock instead of sleeping,
/// and the watch's periodic timer is held as [periodic] for [tick] to fire.
class ManualClock {
  DateTime now = DateTime(2026, 9, 20, 12);
  HeldTimer? periodic;

  Future<void> wait(Duration d) async {
    now = now.add(d);
  }

  Timer schedule(Duration period, void Function() tick) {
    final timer = HeldTimer(tick, onCancel: () => periodic = null);
    periodic = timer;
    return timer;
  }

  /// One period elapses: the tick runs and every future it chains settles.
  Future<void> tick() async {
    now = now.add(const Duration(seconds: 1));
    periodic?.fire();
    // The tick is unawaited inside the courier; let its chain drain.
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

class HeldTimer implements Timer {
  HeldTimer(this._tick, {required this.onCancel});

  final void Function() _tick;
  final void Function() onCancel;
  bool _active = true;
  int _count = 0;

  void fire() {
    if (!_active) return;
    _count++;
    _tick();
  }

  @override
  void cancel() {
    if (!_active) return;
    _active = false;
    onCancel();
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => _count;
}

/// One courier over scripted lanes, a manual clock and a memory store.
class Rig {
  Rig({
    MemoryLetterQueueStore? store,
    LetterCourierBudget budget = fast,
    int maxLetters = LetterQueue.defaultMaxLetters,
  }) : store = store ?? MemoryLetterQueueStore() {
    courier = LetterCourier(
      endpoints: () => throw StateError('scripted lanes, never assembled'),
      budget: budget,
      now: () => clock.now,
      queue: LetterQueue(this.store, maxLetters: maxLetters),
      openLanes: () async => lanes,
      wait: clock.wait,
      schedulePeriodic: clock.schedule,
    );
  }

  final ScriptedLanes lanes = ScriptedLanes();
  final ManualClock clock = ManualClock();
  final MemoryLetterQueueStore store;
  late final LetterCourier courier;
}

/// Always the same coarse label — the ladder's memory keyed on one
/// network, deterministically, with no hardware probe.
class _FixedNetwork implements NetworkNameResolver {
  const _FixedNetwork(this.label);
  final String label;

  @override
  Future<String> resolveNetworkLabel() async => label;
}

/// In-memory [PersistentStorage] so the ladder's tests need no disk.
class _MemoryStorage implements PersistentStorage {
  Map<String, Object?> data = {};

  @override
  Future<Map<String, Object?>> load() async => Map<String, Object?>.from(data);

  @override
  Future<void> save(Map<String, Object?> data) async {
    this.data = Map<String, Object?>.from(data);
  }
}
