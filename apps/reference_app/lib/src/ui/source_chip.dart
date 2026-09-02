/// A label saying where a displayed reading came from.
///
/// The rule in `network_truth.dart` is that UI state derives from a real
/// network signal and is never invented. Where a screen shows a figure that
/// does *not* come from a real signal — a demo profile, a synthetic waveform —
/// this chip sits beside it and says so. The diagnostics panel has done this
/// since it was written ("demo data never masquerades as radio"); the call
/// screen did not, which meant a person on a genuinely bad link could read a
/// scripted recovery as their own.
///
/// It is deliberately dull: no colour coding, no icon. A source label is not a
/// warning, it is a fact about the number next to it, and it stays on screen
/// when the source becomes real.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

class SourceChip extends StatelessWidget {
  const SourceChip({super.key, required this.label});

  /// Where the neighbouring figures come from — `demoQualitySourceLabel`
  /// while they are synthetic, and the live source once they are not.
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: 'Readings source: $label',
      child: Container(
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: AppSpacing.s8,
          vertical: AppSpacing.s2,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadius.r8),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
