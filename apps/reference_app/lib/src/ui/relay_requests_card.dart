/// What this install has cost the relay today, on the diagnostics screen.
///
/// Sealed letters are found by looking, and every look is a request to a
/// relay shared by every install. The count, the day's cap and the longest
/// any request stayed open are shown as they are — the same numbers the
/// service writes to its journal every thirty seconds.
///
/// Renders nothing until this install has a sealed-letter service (no
/// identity yet, or a host without one), so a screen without letters looks
/// as it did before.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../sealed/relay_requests.dart';
import '../sealed/sealed_letter_service.dart';
import 'tokens.dart';

class RelayRequestsCard extends StatelessWidget {
  const RelayRequestsCard({super.key, this.service});

  /// The service to read; the app's own when null.
  final ValueListenable<SealedLetterService?>? service;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SealedLetterService?>(
      valueListenable: service ?? sealedLetterService,
      builder: (context, running, _) {
        final budget = running?.budget;
        if (budget == null) return const SizedBox.shrink();
        return ValueListenableBuilder<RequestCount>(
          valueListenable: budget.count,
          builder: (context, count, _) => _Card(count: count),
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.count});

  final RequestCount count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final state = count.spent
        ? 'used up — nothing more is sent until 00:00 UTC'
        : count.looksSpent
        ? 'looking has stopped until 00:00 UTC; the rest is kept for writing'
        : 'looking stops at ${count.lookCap}; the rest is kept for writing';
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: AppSpacing.s12),
      child: Card(
        key: const Key('relay-requests'),
        margin: EdgeInsetsDirectional.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.r16),
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.all(AppSpacing.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.swap_vert,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.s12),
                  Expanded(
                    child: Text(
                      'Relay requests today',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  Text(
                    '${count.usedToday} of ${count.dailyCap}',
                    key: const Key('relay-requests-today'),
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s4),
              Text(
                'since this start ${count.sinceStart} · longest open '
                '${count.longestOpen.inMilliseconds} ms · not sent today '
                '${count.refusedToday}',
                key: const Key('relay-requests-detail'),
                style: quiet,
              ),
              Text(state, key: const Key('relay-requests-state'), style: quiet),
            ],
          ),
        ),
      ),
    );
  }
}
