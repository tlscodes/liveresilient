/// The always-on human-language status box: the assistant's plain-language
/// account of what the connection is doing right now, plus what the director
/// already did about it.
///
/// Unlike [ForesightCard] (which appears only when the director is worried),
/// this stays visible in every state so the user always has a readable,
/// non-technical read on connectivity — the "assistant view" of the smart
/// lane.
library;

import 'package:flutter/material.dart';

import 'intelligence_director.dart';

class AssistantView extends StatelessWidget {
  const AssistantView({required this.director, super.key});

  final IntelligenceDirector director;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: director,
      builder: (context, _) {
        final a = director.advisory;
        final scheme = Theme.of(context).colorScheme;
        final (icon, tint) = switch (a.level) {
          AdvisoryLevel.calm => (Icons.check_circle_outline, scheme.primary),
          AdvisoryLevel.caution => (
            Icons.warning_amber_outlined,
            Colors.orange,
          ),
          AdvisoryLevel.critical => (Icons.error_outline, scheme.error),
        };
        // Prefer the assistant's narration; fall back to the instant
        // deterministic headline until narration arrives.
        final body = a.detail.isNotEmpty ? a.detail : a.headline;
        return Card(
          key: const Key('assistant-view'),
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: tint),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        a.headline,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(body, style: Theme.of(context).textTheme.bodyMedium),
                      if (a.actionTaken != null) ...[
                        const SizedBox(height: 6),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.autorenew, size: 14),
                            const SizedBox(width: 4),
                            Text(
                              a.actionTaken!,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
