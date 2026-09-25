// The delivered letter as a row in the Chats list: the ledger's newest
// record is the row's preview (text verbatim, a voice or thumbnail
// label), an empty ledger puts no row in the list, the thread page shows
// every record, and the courier writes exactly one record — the same
// bytes — when the fabric reports sentLive.
import 'dart:typed_data';

import 'package:connection_orchestrator/connection_orchestrator.dart'
    show
        ConnectivitySnapshot,
        DeliveryOutcome,
        FabricMode,
        LaneStatus,
        ResilientLaneIds;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/letter_composer.dart';
import 'package:reference_app/src/letter_courier.dart';
import 'package:reference_app/src/letter_ledger.dart';
import 'package:reference_app/src/letter_queue.dart';
import 'package:reference_app/src/letter_status_ladder.dart';
import 'package:reference_app/src/ui/conversations_screen.dart';
import 'package:reference_app/src/ui/letter_thread.dart';
import 'package:reference_app/src/ui/network_truth.dart';
import 'package:reference_app/src/ui/tokens.dart';

final DateTime fixedNow = DateTime(2026, 9, 20, 12, 0);

LetterRecord textLetter(String text) => LetterRecord(
  bytes: Uint8List.fromList(text.codeUnits),
  kind: 'typed',
  sentAt: fixedNow.subtract(const Duration(seconds: 20)),
  laneId: ResilientLaneIds.txtQuery,
  sessionId: 'L5AJDQ',
);

/// A 1x1 white JPEG's worth of bytes is not needed here: the thread only
/// hands them to Image.memory, and the row only counts them.
final LetterRecord thumbnailLetter = LetterRecord(
  bytes: Uint8List(3372),
  kind: 'photo',
  sentAt: fixedNow.subtract(const Duration(seconds: 10)),
  laneId: ResilientLaneIds.txtQuery,
  sessionId: 'Q4N53Q',
);

final LetterRecord voiceLetter = LetterRecord(
  bytes: Uint8List(3007),
  kind: 'voice',
  sentAt: fixedNow.subtract(const Duration(seconds: 5)),
  laneId: ResilientLaneIds.txtQuery,
  sessionId: '37NHE2',
  duration: const Duration(seconds: 30),
);

ConversationSummary loopbackRow() => ConversationSummary(
  id: 'loopback',
  title: 'Loopback peer',
  lastMessage: 'Say hello to the demo loop',
  lastAt: fixedNow.subtract(const Duration(minutes: 5)),
  avatarSeed: 0x5EED,
);

QueuedLetter parkedLetter(String text) => QueuedLetter(
  id: 'letter-1',
  bytes: Uint8List.fromList(text.codeUnits),
  kind: 'typed',
  queuedAt: fixedNow.subtract(const Duration(seconds: 2)),
);

/// The list the way main.dart assembles it: the letters' row first when
/// the ledger has one or the queue holds one, never when both are empty.
Widget screen(
  List<LetterRecord> records, {
  List<QueuedLetter> pending = const [],
}) => MaterialApp(
  theme: buildAppThemeData(Brightness.light),
  home: ConversationsScreen(
    conversations: [
      ?letterSummary(records, pending: pending),
      loopbackRow(),
    ],
    onOpen: (_) {},
    now: () => fixedNow,
  ),
);

void main() {
  testWidgets('one text letter: the row carries the title and the text', (
    tester,
  ) async {
    await tester.pumpWidget(screen([textLetter('hello through the door')]));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('conversation-tile-letter')), findsOne);
    expect(find.text('Letter through the door'), findsOneWidget);
    expect(find.text('hello through the door'), findsOneWidget);
    // Ours, delivered: the summary says so for the trailing badge.
    final summary = letterSummary([textLetter('x')])!;
    expect(summary.lastIsMine, isTrue);
    expect(summary.lastStatus, MessageTruthStatus.delivered);
    expect(summary.id, 'letter');
  });

  testWidgets('voice and thumbnail letters: their labels, newest wins', (
    tester,
  ) async {
    await tester.pumpWidget(screen([thumbnailLetter]));
    await tester.pumpAndSettle();
    expect(find.text('Thumbnail · 3372 B'), findsOneWidget);

    await tester.pumpWidget(screen([thumbnailLetter, voiceLetter]));
    await tester.pumpAndSettle();
    expect(find.text('Voice letter · 30 s'), findsOneWidget);
    expect(find.text('Thumbnail · 3372 B'), findsNothing);

    // A take whose length the composer never knew is labelled by size.
    expect(
      letterPreview(
        LetterRecord(bytes: Uint8List(211), kind: 'voice', sentAt: fixedNow),
      ),
      'Voice letter · 211 B',
    );
    // Bytes that are not UTF-8 are named, never printed as garbage.
    expect(
      letterPreview(
        LetterRecord(
          bytes: Uint8List.fromList([0xff, 0xfe, 0x00]),
          kind: 'typed',
          sentAt: fixedNow,
        ),
      ),
      '<binary, 3 B>',
    );
  });

  testWidgets(
    'a letter parked behind a down door has a row: its text, queued, no spinner',
    (tester) async {
      await tester.pumpWidget(
        screen(const [], pending: [parkedLetter('wait')]),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('conversation-tile-letter')), findsOne);
      expect(find.text('Letter through the door'), findsOneWidget);
      expect(find.text('wait · queued, door down'), findsOneWidget);
      final summary = letterSummary(const [], pending: [parkedLetter('wait')])!;
      expect(summary.lastIsMine, isTrue);
      // No badge: the sending badge is a spinner, and this letter waits.
      expect(summary.lastStatus, isNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(summary.lastAt, fixedNow.subtract(const Duration(seconds: 2)));
    },
  );

  testWidgets(
    'the parked letter owns the row over an older arrival, and yields once drained',
    (tester) async {
      final parked = [parkedLetter('second')];
      final arrived = [textLetter('first')];
      final queued = letterSummary(arrived, pending: parked)!;
      expect(queued.lastMessage, 'second · queued, door down');
      expect(queued.lastStatus, isNull);
      final drained = letterSummary(arrived)!;
      expect(drained.lastMessage, 'first');
      expect(drained.lastStatus, MessageTruthStatus.delivered);
      await tester.pumpWidget(screen(arrived, pending: parked));
      await tester.pumpAndSettle();
      expect(find.text('second · queued, door down'), findsOneWidget);
      await tester.pumpWidget(screen(arrived));
      await tester.pumpAndSettle();
      expect(find.text('second · queued, door down'), findsNothing);
      expect(find.text('first'), findsOneWidget);
    },
  );

  testWidgets('an empty ledger puts no letter row in the list', (tester) async {
    expect(letterSummary(const []), isNull);
    await tester.pumpWidget(screen(const []));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('conversation-tile-letter')),
      findsNothing,
    );
    expect(find.text('Letter through the door'), findsNothing);
    expect(find.byKey(const ValueKey('conversation-tile-loopback')), findsOne);
  });

  testWidgets('the thread page lists every record in order', (tester) async {
    final ledger = LetterLedger();
    addTearDown(ledger.dispose);
    ledger.add(textLetter('first'));
    ledger.add(voiceLetter);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppThemeData(Brightness.light),
        home: LetterThreadPage(ledger: ledger),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('first'), findsOneWidget);
    expect(find.text('Voice letter · 30 s'), findsOneWidget);
    expect(find.byKey(const ValueKey('letter-bubble-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('letter-bubble-1')), findsOneWidget);
    expect(find.textContaining('session L5AJDQ'), findsOneWidget);
    // A third letter lands while the page is open: the list follows.
    ledger.add(textLetter('third'));
    await tester.pumpAndSettle();
    expect(find.text('third'), findsOneWidget);
    // No queue and no snapshot handed in: the lane line says so, no probe.
    expect(find.text('Lanes not probed yet'), findsOneWidget);
  });

  testWidgets(
    'the thread shows a parked letter after the records, and the lanes as the fabric last saw them',
    (tester) async {
      final ledger = LetterLedger();
      addTearDown(ledger.dispose);
      ledger.add(textLetter('arrived earlier'));
      final pending = ValueNotifier<List<QueuedLetter>>([
        parkedLetter('still waiting'),
      ]);
      addTearDown(pending.dispose);
      final lanes = ValueNotifier<ConnectivitySnapshot?>(null);
      addTearDown(lanes.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppThemeData(Brightness.light),
          home: LetterThreadPage(
            ledger: ledger,
            pending: pending,
            lanes: lanes,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('arrived earlier'), findsOneWidget);
      expect(find.text('still waiting'), findsOneWidget);
      expect(find.byKey(const ValueKey('letter-bubble-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('letter-queued-0')), findsOneWidget);
      expect(
        find.text('queued, door down · goes once the door answers'),
        findsOneWidget,
      );
      expect(find.text('Lanes not probed yet'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      // The courier's own refresh publishes a snapshot: relay down, door up.
      lanes.value = ConnectivitySnapshot(
        mode: FabricMode.degraded,
        lanes: const [
          LaneStatus(id: 'resilient.wss', eligible: true, score: -1.05),
          LaneStatus(id: 'resilient.https', eligible: true, score: -1.10),
          LaneStatus(
            id: ResilientLaneIds.txtQuery,
            eligible: true,
            score: 0.60,
          ),
        ],
        bestLaneId: ResilientLaneIds.txtQuery,
        pendingBundles: 0,
        atMs: fixedNow.millisecondsSinceEpoch,
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'relay -1.05 down · long-poll -1.10 down · door 0.60 up · '
          'mode degraded · best door',
        ),
        findsOneWidget,
      );
      // A freshly answering door scores −0.14 (health 0.01 − penalty 0.15)
      // and is up; only −1.0 and below is dead (the fabric's deadLaneScore).
      expect(
        laneStateLine(
          ConnectivitySnapshot(
            mode: FabricMode.degraded,
            lanes: const [
              LaneStatus(
                id: ResilientLaneIds.txtQuery,
                eligible: true,
                score: -0.14,
              ),
              LaneStatus(id: 'resilient.wss', eligible: true, score: -1.05),
            ],
            bestLaneId: ResilientLaneIds.txtQuery,
            pendingBundles: 0,
            atMs: 0,
          ),
        ),
        'door -0.14 up · relay -1.05 down · mode degraded · best door',
      );

      // The door drains it: the queue empties, the record lands, one bubble.
      pending.value = const [];
      ledger.add(textLetter('still waiting'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('letter-queued-0')), findsNothing);
      expect(find.byKey(const ValueKey('letter-bubble-1')), findsOneWidget);
      expect(find.text('still waiting'), findsOneWidget);
    },
  );

  testWidgets(
    'the thread names the letter\'s own rung under the lane line, the '
    'same word Director says',
    (tester) async {
      final ledger = LetterLedger();
      addTearDown(ledger.dispose);
      final ladder = ValueNotifier<LetterLadderStatus?>(
        const LetterLadderStatus(LetterLadderRung.closed),
      );
      addTearDown(ladder.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppThemeData(Brightness.light),
          home: LetterThreadPage(ledger: ledger, ladder: ladder),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('letter-thread-rung')), findsOneWidget);
      expect(find.text('closed'), findsOneWidget);

      // The rung moves with the courier's own updates, live on screen.
      ladder.value = const LetterLadderStatus(LetterLadderRung.normal);
      await tester.pumpAndSettle();
      expect(find.text('normal'), findsOneWidget);
      expect(find.text('closed'), findsNothing);
    },
  );

  test(
    'the courier writes exactly one record, the same bytes, on sentLive',
    () async {
      final lanes = OneLaneUp();
      final courier = LetterCourier(
        endpoints: () => throw StateError('scripted lanes, never assembled'),
        now: () => fixedNow,
        openLanes: () async => lanes,
        wait: (_) async {},
        schedulePeriodic: (_, _) => throw StateError('nothing to watch'),
      );
      final payload = Uint8List.fromList('the same bytes'.codeUnits);
      final state = await courier.send(payload, kind: 'typed');
      expect(state, LetterState.arrived);
      final records = courier.ledger.records.value;
      expect(records, hasLength(1));
      expect(records.single.bytes, same(payload));
      expect(records.single.kind, 'typed');
      expect(records.single.sentAt, fixedNow);
      expect(records.single.laneId, ResilientLaneIds.txtQuery);
      expect(records.single.sessionId, 'L5AJDQ');
      expect(lanes.deliveries, 1);

      // A refused carry writes nothing.
      lanes.outcome = DeliveryOutcome.rejected;
      expect(
        await courier.send(Uint8List.fromList([1]), kind: 'typed'),
        LetterState.notDelivered,
      );
      expect(courier.ledger.records.value, hasLength(1));
      await courier.dispose();
    },
  );
}

/// The door up and nothing else: every deliver answers [outcome].
class OneLaneUp implements LetterLanes {
  DeliveryOutcome outcome = DeliveryOutcome.sentLive;
  int deliveries = 0;

  @override
  Future<void> refresh() async {}

  @override
  ConnectivitySnapshot get snapshot => const ConnectivitySnapshot(
    mode: FabricMode.degraded,
    lanes: [
      LaneStatus(id: ResilientLaneIds.txtQuery, eligible: true, score: 0.6),
      LaneStatus(
        id: ResilientLaneIds.webSocketRelay,
        eligible: true,
        score: -1,
      ),
    ],
    bestLaneId: ResilientLaneIds.txtQuery,
    pendingBundles: 0,
    atMs: 0,
  );

  @override
  Future<DeliveryOutcome> deliver(
    Uint8List payload, {
    required String bundleId,
  }) async {
    deliveries++;
    return outcome;
  }

  @override
  void reclaim(String bundleId) {}

  @override
  bool get hasDoor => true;

  @override
  String? get doorSessionId => 'L5AJDQ';

  @override
  Future<void> dispose() async {}
}
