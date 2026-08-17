/// Conversations list — the messenger's home screen.
///
/// Pure-data widget: it knows nothing about controllers, streams or storage.
/// The host hands it a `List<ConversationSummary>` plus callbacks and the
/// screen derives its state from those inputs alone:
///
///  * `loading` with no data → skeleton (ONE [Shimmer] around the whole
///    skeleton; rows never animate individually, and the sweep self-disables
///    under `flutter test`). Data always wins over the skeleton.
///  * no data, not loading → empty state with a "Start a chat" call to action.
///  * data → tiles with a one-shot staggered entrance (fade + 12dp rise)
///    driven by a single screen-level [AnimationController]: per-row curves
///    are [Interval]s on that one controller, so there are no per-row tickers
///    and nothing repeats — `pumpAndSettle` always settles.
///
/// RTL is first-class: every inset/alignment is directional, the identicon
/// gradient runs topStart→bottomEnd, and skeleton lines anchor to `start`.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'message_status.dart';
import 'network_truth.dart';
import 'shimmer.dart';
import 'tokens.dart';

/// Immutable row model for one conversation in the list.
@immutable
class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.title,
    required this.lastMessage,
    required this.lastAt,
    required this.avatarSeed,
    this.unreadCount = 0,
    this.lastIsMine = false,
    this.lastStatus,
  });

  /// Stable identity (also keys the tile widget).
  final String id;

  /// Display name of the peer or group.
  final String title;

  /// Preview of the most recent message.
  final String lastMessage;

  /// When the most recent message happened.
  final DateTime lastAt;

  /// Seed for the deterministic identicon gradient.
  final int avatarSeed;

  /// Unread messages from the other side; shown as a pill when > 0.
  final int unreadCount;

  /// True when the last message is ours — the trailing slot then shows the
  /// network-truth status badge instead of an unread pill.
  final bool lastIsMine;

  /// Truth status of our last message; only meaningful when [lastIsMine].
  final MessageTruthStatus? lastStatus;
}

const List<String> _monthAbbreviations = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Compact relative-time label for a conversation row.
///
/// Pure — both instants are injected so tests are deterministic:
///  * under a minute (or a skewed clock reporting the future) → `now`
///  * under an hour → `5m`
///  * same calendar day → `2h`
///  * previous calendar day (and at least an hour old) → `Yesterday`
///  * older, same year → `Jan 5`; other years → `Jan 5, 2025`
String relativeTimeLabel(DateTime at, DateTime now) {
  final diff = now.difference(at);
  if (diff < const Duration(minutes: 1)) return 'now';
  if (diff < const Duration(hours: 1)) return '${diff.inMinutes}m';
  final atDay = DateTime(at.year, at.month, at.day);
  final nowDay = DateTime(now.year, now.month, now.day);
  final dayDiff = nowDay.difference(atDay).inDays;
  if (dayDiff == 0) return '${diff.inHours}h';
  if (dayDiff == 1) return 'Yesterday';
  final month = _monthAbbreviations[at.month - 1];
  if (at.year == now.year) return '$month ${at.day}';
  return '$month ${at.day}, ${at.year}';
}

/// The conversations home screen. See the library doc for the state contract.
class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({
    super.key,
    required this.conversations,
    this.loading = false,
    required this.onOpen,
    this.onNewChat,
    this.now,
  });

  /// Rows to display, most recent first (ordering is the host's job).
  final List<ConversationSummary> conversations;

  /// Shows the skeleton while true — but only until data exists.
  final bool loading;

  /// Called with the tapped conversation (after selection haptics).
  final void Function(ConversationSummary) onOpen;

  /// Starts a new chat (empty-state CTA and the FAB). Null hides both.
  final VoidCallback? onNewChat;

  /// Clock seam so relative-time labels are testable; defaults to
  /// [DateTime.now].
  final DateTime Function()? now;

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen>
    with SingleTickerProviderStateMixin {
  /// Entrance stagger: each row starts [_staggerStepMs] after the previous,
  /// capped so long lists do not queue forever.
  static const int _staggerStepMs = 24;
  static const int _staggerCapMs = 240;

  // Created eagerly in initState: a lazy `late` field would be touched for
  // the first time inside dispose() on screens whose entrance never played,
  // and creating a ticker during unmount is illegal.
  late final AnimationController _entrance;

  bool _entrancePlayed = false;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: Duration(
        milliseconds: _staggerCapMs + AppMotion.base.inMilliseconds,
      ),
    );
    _maybePlayEntrance();
  }

  @override
  void didUpdateWidget(covariant ConversationsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybePlayEntrance();
  }

  /// One-shot: fires the first time real tiles are about to appear and never
  /// again — later list updates render at rest.
  void _maybePlayEntrance() {
    if (_entrancePlayed || widget.conversations.isEmpty) return;
    _entrancePlayed = true;
    _entrance.forward();
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  Animation<double> _rowAnimation(int index) {
    final total = _staggerCapMs + AppMotion.base.inMilliseconds;
    final delay = math.min(index * _staggerStepMs, _staggerCapMs);
    return CurvedAnimation(
      parent: _entrance,
      curve: Interval(
        delay / total,
        (delay + AppMotion.base.inMilliseconds) / total,
        curve: AppMotion.standard,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showSkeleton = widget.loading && widget.conversations.isEmpty;
    final Widget body;
    if (showSkeleton) {
      body = const _ConversationsSkeleton();
    } else if (widget.conversations.isEmpty) {
      body = _EmptyState(onNewChat: widget.onNewChat);
    } else {
      body = _buildList(context);
    }
    final showFab =
        widget.conversations.isNotEmpty && widget.onNewChat != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Chats')),
      body: body,
      floatingActionButton: showFab
          ? FloatingActionButton(
              onPressed: () {
                AppHaptics.selection();
                widget.onNewChat!();
              },
              tooltip: 'New chat',
              child: const Icon(Icons.edit_outlined),
            )
          : null,
    );
  }

  Widget _buildList(BuildContext context) {
    final now = (widget.now ?? DateTime.now)();
    final items = widget.conversations;
    return ListView.separated(
      padding: const EdgeInsetsDirectional.only(
        top: AppSpacing.s4,
        // Clearance so the FAB never covers the last tile's trailing badge.
        bottom: AppSpacing.s48 + AppSpacing.s32,
      ),
      itemCount: items.length,
      separatorBuilder: (context, index) => const Divider(
        // Hairline (color/thickness from DividerTheme = tokens.outlineSoft),
        // indented past the avatar; Divider's indent is directional.
        indent: AppSpacing.s16 + AppSpacing.s48 + AppSpacing.s12,
      ),
      itemBuilder: (context, index) {
        final summary = items[index];
        return _EntranceReveal(
          animation: _rowAnimation(index),
          child: _ConversationTile(
            key: ValueKey('conversation-tile-${summary.id}'),
            summary: summary,
            now: now,
            onOpen: () => widget.onOpen(summary),
          ),
        );
      },
    );
  }
}

/// Fade + 12dp rise driven by the screen's single entrance controller.
/// Renders the child untouched once the animation has completed.
class _EntranceReveal extends StatelessWidget {
  const _EntranceReveal({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final t = animation.value;
        if (t >= 1) return child!;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            // Vertical rise only — reads identically in LTR and RTL.
            offset: Offset(0, (1 - t) * AppSpacing.s12),
            child: child,
          ),
        );
      },
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    super.key,
    required this.summary,
    required this.now,
    required this.onOpen,
  });

  final ConversationSummary summary;
  final DateTime now;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final hasUnread = !summary.lastIsMine && summary.unreadCount > 0;
    return Semantics(
      button: true,
      label: 'Conversation with ${summary.title}',
      child: InkWell(
        onTap: () {
          AppHaptics.selection();
          onOpen();
        },
        child: Padding(
          // 48dp avatar + 2×12dp vertical padding = 72dp row ≥ 64dp target.
          padding: const EdgeInsetsDirectional.symmetric(
            horizontal: AppSpacing.s16,
            vertical: AppSpacing.s12,
          ),
          child: Row(
            children: [
              ExcludeSemantics(
                child: _IdenticonAvatar(
                  seed: summary.avatarSeed,
                  title: summary.title,
                ),
              ),
              const SizedBox(width: AppSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      summary.title,
                      style: text.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppSpacing.s2),
                    Text(
                      summary.lastMessage,
                      style: text.bodyMedium?.copyWith(
                        color: hasUnread
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                        fontWeight: hasUnread ? FontWeight.w500 : null,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.s12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    relativeTimeLabel(summary.lastAt, now),
                    style: text.labelSmall?.copyWith(
                      color: hasUnread
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  _trailingBadge(context),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Mutually exclusive trailing slot: our last message → truth badge;
  /// otherwise unread pill when there is anything unread; else a spacer that
  /// keeps every row's time label at the same height.
  Widget _trailingBadge(BuildContext context) {
    final status = summary.lastStatus;
    if (summary.lastIsMine && status != null) {
      return MessageStatusBadge(status: status);
    }
    if (summary.unreadCount > 0) {
      final scheme = Theme.of(context).colorScheme;
      final text = Theme.of(context).textTheme;
      final label =
          summary.unreadCount > 99 ? '99+' : '${summary.unreadCount}';
      return Semantics(
        label: '${summary.unreadCount} unread',
        excludeSemantics: true,
        child: Container(
          key: const ValueKey('unread-pill'),
          constraints: const BoxConstraints(minWidth: AppSpacing.s20),
          height: AppSpacing.s20,
          padding: const EdgeInsetsDirectional.symmetric(
            horizontal: AppSpacing.s8,
          ),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(AppRadius.r12),
          ),
          child: Text(
            label,
            style: text.labelSmall?.copyWith(color: scheme.onPrimary),
          ),
        ),
      );
    }
    return const SizedBox(height: AppSpacing.s20);
  }
}

/// Deterministic identicon: a circular gradient of two hues picked from six
/// scheme/token-derived colors by the seed hash, over the title's initials.
class _IdenticonAvatar extends StatelessWidget {
  const _IdenticonAvatar({required this.seed, required this.title});

  final int seed;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = context.tokens;
    final palette = <Color>[
      scheme.primary,
      scheme.secondary,
      scheme.tertiary,
      tokens.verified,
      tokens.gaugeFair,
      scheme.error,
    ];
    final h = seed & 0x7fffffff;
    final a = h % palette.length;
    final b =
        (a + 1 + (h ~/ palette.length) % (palette.length - 1)) %
        palette.length;
    return Container(
      width: AppSpacing.s48,
      height: AppSpacing.s48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: [palette[a], palette[b]],
        ),
      ),
      child: Text(
        _initialsOf(title),
        style: theme.textTheme.titleMedium?.copyWith(color: scheme.onPrimary),
      ),
    );
  }

  static String _initialsOf(String title) {
    final letters = <String>[];
    for (final word in title.trim().split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      letters.add(String.fromCharCode(word.runes.first));
      if (letters.length == 2) break;
    }
    if (letters.isEmpty) return '?';
    return letters.join().toUpperCase();
  }
}

/// Skeleton list: ONE [Shimmer] wraps all rows (single ticker for the whole
/// screen; flat base color under `flutter test`). Rows are static — the
/// staggered entrance belongs to real tiles only.
class _ConversationsSkeleton extends StatelessWidget {
  const _ConversationsSkeleton();

  static const int _rowCount = 8;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading conversations',
      child: Shimmer(
        child: Column(
          children: [
            for (var i = 0; i < _rowCount; i++)
              Padding(
                padding: const EdgeInsetsDirectional.symmetric(
                  horizontal: AppSpacing.s16,
                  vertical: AppSpacing.s12,
                ),
                child: Row(
                  children: [
                    const ShimmerBox(
                      width: AppSpacing.s48,
                      height: AppSpacing.s48,
                      shape: BoxShape.circle,
                    ),
                    const SizedBox(width: AppSpacing.s12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FractionallySizedBox(
                            alignment: AlignmentDirectional.centerStart,
                            // Alternating widths keep the skeleton organic
                            // while staying deterministic for goldens.
                            widthFactor: i.isEven ? 0.42 : 0.55,
                            child: const ShimmerBox(),
                          ),
                          const SizedBox(height: AppSpacing.s8),
                          FractionallySizedBox(
                            alignment: AlignmentDirectional.centerStart,
                            widthFactor: i.isEven ? 0.78 : 0.64,
                            child: const ShimmerBox(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Empty state: tonal icon circle, headline, supporting line and the
/// "Start a chat" call to action.
class _EmptyState extends StatelessWidget {
  const _EmptyState({this.onNewChat});

  final VoidCallback? onNewChat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: AppSpacing.s32,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: AppSpacing.s48 * 2,
              height: AppSpacing.s48 * 2,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.secondaryContainer,
              ),
              child: Icon(
                Icons.forum_outlined,
                size: AppSpacing.s48,
                color: scheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: AppSpacing.s24),
            Text(
              'No conversations yet',
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.s8),
            Text(
              'Start a chat and it will appear here.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (onNewChat != null) ...[
              const SizedBox(height: AppSpacing.s24),
              FilledButton.tonal(
                onPressed: () {
                  AppHaptics.selection();
                  onNewChat!();
                },
                child: const Text('Start a chat'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
