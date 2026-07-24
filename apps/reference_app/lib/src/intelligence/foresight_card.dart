/// UI for the director's judgment: one reactive card that shows the
/// deterministic headline instantly, the assistant's narration as it
/// streams in, and the action the system already took.
library;

import 'package:flutter/material.dart';

import 'intelligence_director.dart';

/// Renders [IntelligenceDirector.advisory]; hidden while calm.
class ForesightCard extends StatelessWidget {
  const ForesightCard({super.key, required this.director});

  final IntelligenceDirector director;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: director,
      builder: (context, _) {
        final advisory = director.advisory;
        if (advisory.level == AdvisoryLevel.calm) {
          return const SizedBox.shrink();
        }
        final scheme = Theme.of(context).colorScheme;
        final (bg, fg, icon) = switch (advisory.level) {
          AdvisoryLevel.caution => (
            scheme.tertiaryContainer,
            scheme.onTertiaryContainer,
            Icons.trending_down,
          ),
          _ => (
            scheme.errorContainer,
            scheme.onErrorContainer,
            Icons.cloud_off,
          ),
        };
        return Card(
          key: const Key('foresight-card'),
          color: bg,
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: fg),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        advisory.headline,
                        style: TextStyle(
                          color: fg,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (advisory.detail.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            advisory.detail,
                            style: TextStyle(color: fg),
                          ),
                        ),
                      if (advisory.actionTaken != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Action: ${advisory.actionTaken}',
                            style: TextStyle(
                              color: fg,
                              fontSize: 12,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
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
