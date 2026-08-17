/// Settings screen: grouped section cards (Appearance / Network / About)
/// with the live [DiagnosticsPanel] as the Network section.
///
/// Shape rules:
///  * The screen itself is stateless; the diagnostics stream is consumed
///    inside [DiagnosticsPanel], so a quality reading never rebuilds this
///    screen — only the panel leaf.
///  * All insets are directional (RTL-first); styles come from the ambient
///    [TextTheme] and colors from [ColorScheme] / `context.tokens` only.
library;

import 'package:flutter/material.dart';

import 'diagnostics_panel.dart';
import 'network_truth.dart';
import 'tokens.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.themeMode,
    required this.onThemeMode,
    this.readings,
    this.diagnosticsSeed,
    this.diagnosticsSource = 'loopback demo',
    this.appVersion = 'dev',
    this.privacyLine = 'E2E media · no telemetry without opt-in',
  });

  /// Currently selected theme mode (owned by the app shell).
  final ThemeMode themeMode;

  /// Called with the newly chosen mode when the user changes the segment.
  final ValueChanged<ThemeMode> onThemeMode;

  /// Live quality readings forwarded to the diagnostics panel.
  final Stream<CallQualityReading>? readings;

  /// Initial diagnostics history (deterministic in tests/goldens).
  final QualityHistory? diagnosticsSeed;

  /// Real origin of the diagnostics readings (honesty contract).
  final String diagnosticsSource;

  final String appVersion;
  final String privacyLine;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsetsDirectional.fromSTEB(
          AppSpacing.s16,
          AppSpacing.s8,
          AppSpacing.s16,
          AppSpacing.s32,
        ),
        children: [
          const _SectionHeader('Appearance'),
          _SectionCard(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Semantics(
                container: true,
                label: 'Theme mode',
                child: SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('System'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      label: Text('Light'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text('Dark'),
                    ),
                  ],
                  selected: {themeMode},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) {
                    AppHaptics.selection();
                    onThemeMode(selection.first);
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s24),
          const _SectionHeader('Network'),
          DiagnosticsPanel(
            readings: readings,
            seed: diagnosticsSeed,
            sourceLabel: diagnosticsSource,
          ),
          const SizedBox(height: AppSpacing.s24),
          const _SectionHeader('About'),
          _SectionCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _AboutRow(
                  icon: Icons.info_outline,
                  label: 'Version',
                  trailing: appVersion,
                ),
                const _Hairline(),
                _AboutRow(
                  icon: Icons.verified_user,
                  iconColor: tokens.verified,
                  label: privacyLine,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// labelSmall section title above each card.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: AppSpacing.s4,
        bottom: AppSpacing.s8,
      ),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// r16 card with s16 directional padding — one per settings group.
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsetsDirectional.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.r16),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(AppSpacing.s16),
        child: child,
      ),
    );
  }
}

/// Icon + label (+ optional trailing value) row for the About card.
class _AboutRow extends StatelessWidget {
  const _AboutRow({
    required this.icon,
    required this.label,
    this.trailing,
    this.iconColor,
  });

  final IconData icon;
  final String label;
  final String? trailing;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(
          icon,
          size: 20,
          color: iconColor ?? theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: AppSpacing.s12),
        Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
        if (trailing != null)
          Text(
            trailing!,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// outlineSoft hairline between About rows.
class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 0.5,
      margin: const EdgeInsetsDirectional.only(
        top: AppSpacing.s12,
        bottom: AppSpacing.s12,
      ),
      color: context.tokens.outlineSoft,
    );
  }
}
