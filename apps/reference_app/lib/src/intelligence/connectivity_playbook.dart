/// The expert playbook: distilled connectivity engineering knowledge,
/// versioned in code so it can never be forgotten, matched one insight
/// at a time so a small on-device model is never overloaded (the model
/// bake-off showed rulebook prompts degrade tiny models — single
/// situation-matched facts do not).
///
/// Sources of the knowledge: real-time media engineering practice
/// (latency/loss budgets), delay-tolerant networking practice (queue
/// discipline), and this project's own measured findings (gauntlet and
/// evolution-bench results, 2026-07-24).
library;

import 'package:connection_orchestrator/connection_orchestrator.dart';

/// One matched piece of expert knowledge for the current situation.
class PlaybookInsight {
  const PlaybookInsight({
    required this.id,
    required this.guidance,
    this.actionHint,
  });

  /// Stable identifier (telemetry, tests, dedup).
  final String id;

  /// One plain-language sentence of expert knowledge for the user/UI.
  final String guidance;

  /// Optional machine-usable hint for the director's next decision.
  final String? actionHint;
}

/// Deterministic knowledge base. [match] returns the single most
/// relevant insight for a snapshot — never a rulebook dump.
class ConnectivityPlaybook {
  const ConnectivityPlaybook();

  /// Bump when knowledge is added so persisted narrations can cite it.
  static const int version = 1;

  /// Voice conversation breaks above this one-way budget; small loss is
  /// concealable, latency is not (media engineering practice).
  static const int voiceRttBudgetMs = 150;
  static const double concealableLossPct = 3.0;

  /// Measured on this project's evolution bench (2026-07-24): live
  /// health should outweigh long-term memory when both disagree.
  static const double liveHealthOverMemoryWeight = 0.8;

  PlaybookInsight match(ConnectivitySnapshot snapshot, TrendVerdict trend) {
    final lanes = snapshot.lanes;
    final best = snapshot.bestLaneId;
    final upCount = lanes.where((l) => l.eligible && l.score > 0.2).length;

    if (snapshot.mode == FabricMode.offline) {
      return const PlaybookInsight(
        id: 'offline-no-lanes',
        guidance:
            'No transport is configured; messages are kept safe on this '
            'device and nothing is lost.',
      );
    }
    if (snapshot.mode == FabricMode.storeAndForward) {
      return PlaybookInsight(
        id: 'dtn-queue-discipline',
        guidance:
            '${snapshot.pendingBundles} message(s) are stored durably and '
            'will send automatically the moment any path returns — urgent '
            'ones first.',
        actionHint: 'probe-all-lanes-on-any-signal',
      );
    }
    if (trend == TrendVerdict.failingSoon) {
      return const PlaybookInsight(
        id: 'preemptive-duplication',
        guidance:
            'The active path is projected to fail shortly; important '
            'traffic is already being duplicated onto the backup path so '
            'a mid-transfer failure costs nothing.',
        actionHint: 'dual-send-window-open',
      );
    }
    if (trend == TrendVerdict.slipping) {
      return const PlaybookInsight(
        id: 'trend-beats-present',
        guidance:
            'Signal quality is trending down even though it still works — '
            'acting on the trend now beats reacting to the failure later.',
        actionHint: 'pre-warm-backup',
      );
    }
    if (snapshot.mode == FabricMode.degraded && upCount <= 1) {
      return const PlaybookInsight(
        id: 'single-path-fragility',
        guidance:
            'Only one usable path remains; anything important should go '
            'out now rather than wait.',
        actionHint: 'flush-queue-immediately',
      );
    }
    if (snapshot.mode == FabricMode.degraded) {
      return const PlaybookInsight(
        id: 'latency-over-loss-for-voice',
        guidance:
            'For live voice, a fast path with a little packet loss beats '
            'a slow clean one — delay above ~150ms breaks conversation, '
            'small loss is concealable.',
      );
    }
    if (best != null && upCount >= 2) {
      return const PlaybookInsight(
        id: 'redundancy-standing-by',
        guidance:
            'A healthy backup path is standing by; switchover would be '
            'seamless if the current one weakens.',
      );
    }
    return const PlaybookInsight(
      id: 'calm-baseline',
      guidance: 'Connection is healthy and being watched ahead of time.',
    );
  }
}
