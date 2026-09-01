/// Widget + golden coverage for the conversations list screen.
///
/// Determinism notes:
///  * `now` is injected everywhere — no wall clock in any assertion.
///  * Fixtures never use [MessageTruthStatus.sending]: its badge is an
///    indeterminate progress ring, which would keep `pumpAndSettle` spinning.
///  * The entrance animation is one-shot, so `pumpAndSettle` completes and
///    goldens capture the settled layout.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/ui/conversations_screen.dart';
import 'package:reference_app/src/ui/message_status.dart';
import 'package:reference_app/src/ui/network_truth.dart';
import 'package:reference_app/src/ui/shimmer.dart';
import 'package:reference_app/src/ui/tokens.dart';

final DateTime fixedNow = DateTime(2026, 1, 15, 12, 0);

List<ConversationSummary> demoConversations() => [
  ConversationSummary(
    id: 'c1',
    title: 'Maryam Ahmadi',
    lastMessage: 'Voice note is on its way — tell me what you think.',
    lastAt: fixedNow.subtract(const Duration(seconds: 20)),
    avatarSeed: 11,
    unreadCount: 3,
  ),
  ConversationSummary(
    id: 'c2',
    title: 'Design Crew',
    lastMessage: 'You: shipped the new tokens',
    lastAt: fixedNow.subtract(const Duration(minutes: 5)),
    avatarSeed: 22,
    lastIsMine: true,
    lastStatus: MessageTruthStatus.delivered,
  ),
  ConversationSummary(
    id: 'c3',
    title: 'Arash',
    lastMessage: 'You: photo',
    lastAt: fixedNow.subtract(const Duration(hours: 2)),
    avatarSeed: 33,
    lastIsMine: true,
    lastStatus: MessageTruthStatus.verified,
  ),
  ConversationSummary(
    id: 'c4',
    title: 'Support',
    lastMessage: 'Your ticket was updated — see the notes.',
    lastAt: DateTime(2026, 1, 14, 18, 30),
    avatarSeed: 44,
    unreadCount: 120,
  ),
  ConversationSummary(
    id: 'c5',
    title: 'Neda',
    lastMessage: 'You: see you there',
    lastAt: DateTime(2026, 1, 5, 9, 0),
    avatarSeed: 55,
    lastIsMine: true,
    lastStatus: MessageTruthStatus.failed,
  ),
  ConversationSummary(
    id: 'c6',
    title: 'Book Club',
    lastMessage: 'Next chapter discussion on Sunday',
    lastAt: DateTime(2025, 12, 30, 20, 0),
    avatarSeed: 66,
  ),
  ConversationSummary(
    id: 'c7',
    title: 'Kian Zand',
    lastMessage: 'You: sounds good',
    lastAt: fixedNow.subtract(const Duration(minutes: 45)),
    avatarSeed: 77,
    lastIsMine: true,
    lastStatus: MessageTruthStatus.sent,
  ),
];

Future<void> pumpScreen(
  WidgetTester tester, {
  required Widget home,
  Brightness brightness = Brightness.light,
  bool rtl = false,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppThemeData(brightness),
      home: rtl
          ? Directionality(textDirection: TextDirection.rtl, child: home)
          : home,
    ),
  );
}

/// Finds every conversation tile via its `conversation-tile-<id>` key.
Finder tileFinder() => find.byWidgetPredicate((widget) {
  final key = widget.key;
  return key is ValueKey<String> && key.value.startsWith('conversation-tile-');
});

Finder unreadPillIn(Finder tile) =>
    find.descendant(of: tile, matching: find.byKey(const Key('unread-pill')));

void main() {
  group('relativeTimeLabel', () {
    test('covers now / minutes / hours / yesterday / dates', () {
      final now = DateTime(2026, 1, 15, 12, 0);
      expect(relativeTimeLabel(now, now), 'now');
      expect(
        relativeTimeLabel(now.subtract(const Duration(seconds: 59)), now),
        'now',
      );
      expect(
        relativeTimeLabel(now.subtract(const Duration(minutes: 5)), now),
        '5m',
      );
      expect(
        relativeTimeLabel(now.subtract(const Duration(minutes: 59)), now),
        '59m',
      );
      expect(
        relativeTimeLabel(now.subtract(const Duration(hours: 2)), now),
        '2h',
      );
      expect(
        relativeTimeLabel(DateTime(2026, 1, 14, 23, 59), now),
        'Yesterday',
      );
      expect(relativeTimeLabel(DateTime(2026, 1, 14), now), 'Yesterday');
      expect(relativeTimeLabel(DateTime(2026, 1, 5, 9, 0), now), 'Jan 5');
      expect(
        relativeTimeLabel(DateTime(2025, 12, 30, 20, 0), now),
        'Dec 30, 2025',
      );
      // Clock skew reporting the future must not produce negative labels.
      expect(
        relativeTimeLabel(now.add(const Duration(minutes: 3)), now),
        'now',
      );
    });
  });

  group('ConversationsScreen states', () {
    testWidgets('loading shows one Shimmer skeleton and zero tiles', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        home: ConversationsScreen(
          conversations: const [],
          loading: true,
          onOpen: (_) {},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Shimmer), findsOneWidget);
      // 8 rows × (1 avatar circle + 2 lines).
      expect(find.byType(ShimmerBox), findsNWidgets(24));
      expect(tileFinder(), findsNothing);
    });

    testWidgets('data wins over loading — skeleton never covers real tiles', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        home: ConversationsScreen(
          conversations: demoConversations(),
          loading: true,
          onOpen: (_) {},
          now: () => fixedNow,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Shimmer), findsNothing);
      expect(tileFinder(), findsNWidgets(7));
    });

    testWidgets('empty state shows CTA and calls onNewChat', (tester) async {
      var newChatCalls = 0;
      await pumpScreen(
        tester,
        home: ConversationsScreen(
          conversations: const [],
          onOpen: (_) {},
          onNewChat: () => newChatCalls++,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No conversations yet'), findsOneWidget);
      expect(find.byType(Shimmer), findsNothing);
      await tester.tap(find.text('Start a chat'));
      await tester.pump();
      expect(newChatCalls, 1);
    });

    testWidgets('renders N tiles and tap reports the right summary', (
      tester,
    ) async {
      ConversationSummary? opened;
      final items = demoConversations();
      await pumpScreen(
        tester,
        home: ConversationsScreen(
          conversations: items,
          onOpen: (c) => opened = c,
          now: () => fixedNow,
        ),
      );
      await tester.pumpAndSettle();
      expect(tileFinder(), findsNWidgets(items.length));
      await tester.tap(find.byKey(const ValueKey('conversation-tile-c3')));
      await tester.pump();
      expect(opened, isNotNull);
      expect(opened!.id, 'c3');
      expect(opened!.title, 'Arash');
    });

    testWidgets('unread pill and status badge are mutually exclusive', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        home: ConversationsScreen(
          conversations: demoConversations(),
          onOpen: (_) {},
          now: () => fixedNow,
        ),
      );
      await tester.pumpAndSettle();

      // Their message + unread → pill, no status badge.
      final unreadTile = find.byKey(const ValueKey('conversation-tile-c1'));
      expect(unreadPillIn(unreadTile), findsOneWidget);
      expect(
        find.descendant(
          of: unreadTile,
          matching: find.byType(MessageStatusBadge),
        ),
        findsNothing,
      );
      expect(
        find.descendant(of: unreadTile, matching: find.text('3')),
        findsOneWidget,
      );

      // Our message + status → badge, no pill.
      final mineTile = find.byKey(const ValueKey('conversation-tile-c2'));
      expect(
        find.descendant(
          of: mineTile,
          matching: find.byType(MessageStatusBadge),
        ),
        findsOneWidget,
      );
      expect(unreadPillIn(mineTile), findsNothing);

      // Counts above 99 clamp to a readable pill.
      final bigTile = find.byKey(const ValueKey('conversation-tile-c4'));
      expect(
        find.descendant(of: bigTile, matching: find.text('99+')),
        findsOneWidget,
      );
    });

    testWidgets('relative time labels render from the injected now()', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        home: ConversationsScreen(
          conversations: demoConversations(),
          onOpen: (_) {},
          now: () => fixedNow,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('now'), findsOneWidget);
      expect(find.text('5m'), findsOneWidget);
      expect(find.text('2h'), findsOneWidget);
      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Jan 5'), findsOneWidget);
      expect(find.text('Dec 30, 2025'), findsOneWidget);
    });
  });

  group('goldens', () {
    Widget dataScreen() => ConversationsScreen(
      conversations: demoConversations(),
      onOpen: (_) {},
      onNewChat: () {},
      now: () => fixedNow,
    );

    Widget skeletonScreen() => ConversationsScreen(
      conversations: const [],
      loading: true,
      onOpen: (_) {},
    );

    testWidgets('data light', (tester) async {
      await pumpScreen(tester, home: dataScreen());
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(ConversationsScreen),
        matchesGoldenFile('goldens/conversations_data_light.png'),
      );
    });

    testWidgets('data dark', (tester) async {
      await pumpScreen(tester, home: dataScreen(), brightness: Brightness.dark);
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(ConversationsScreen),
        matchesGoldenFile('goldens/conversations_data_dark.png'),
      );
    });

    testWidgets('data rtl', (tester) async {
      await pumpScreen(tester, home: dataScreen(), rtl: true);
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(ConversationsScreen),
        matchesGoldenFile('goldens/conversations_data_rtl.png'),
      );
    });

    testWidgets('skeleton light', (tester) async {
      await pumpScreen(tester, home: skeletonScreen());
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(ConversationsScreen),
        matchesGoldenFile('goldens/conversations_skeleton_light.png'),
      );
    });

    testWidgets('skeleton dark', (tester) async {
      await pumpScreen(
        tester,
        home: skeletonScreen(),
        brightness: Brightness.dark,
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(ConversationsScreen),
        matchesGoldenFile('goldens/conversations_skeleton_dark.png'),
      );
    });

    testWidgets('skeleton rtl', (tester) async {
      await pumpScreen(tester, home: skeletonScreen(), rtl: true);
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(ConversationsScreen),
        matchesGoldenFile('goldens/conversations_skeleton_rtl.png'),
      );
    });
  });
}
