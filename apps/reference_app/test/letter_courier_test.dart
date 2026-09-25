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
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart'
    show HostPort, TxtQueryLane, TxtQueryValve;
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
import 'package:reference_app/src/letter_composer.dart';
import 'package:reference_app/src/letter_courier.dart';
import 'package:reference_app/src/letter_parts.dart';
import 'package:reference_app/src/letter_queue.dart';
import 'package:reference_app/src/letter_rung_ladder.dart';

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
}

/// A lane set the test scripts: which lane is up decides the snapshot,
/// [outcome] decides every deliver's verdict, and every deliver is kept.
class ScriptedLanes implements LetterLanes {
  bool liveUp = false;
  bool doorUp = false;

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
    const https = LaneStatus(
      id: ResilientLaneIds.httpLongPoll,
      eligible: true,
      score: -1.10,
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
