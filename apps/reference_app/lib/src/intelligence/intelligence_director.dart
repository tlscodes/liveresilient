/// The team leader: a live, reacting decision layer above the whole
/// intelligence circuit.
///
/// It watches the fabric's snapshot stream and the trend sentinel,
/// classifies the situation, ACTS on it (kicks a fabric refresh when the
/// path is sliding — self-healing before failure), and asks the
/// assistant to narrate the state in human language. The UI observes one
/// [DirectorAdvisory]; the director owns all the judgment.
library;

import 'dart:async';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:flutter/foundation.dart';

import 'connectivity_playbook.dart';
import 'intelligence_hub.dart';

/// Severity of the current situation as the director judges it.
enum AdvisoryLevel { calm, caution, critical }

/// One immutable judgment for the UI.
class DirectorAdvisory {
  const DirectorAdvisory({
    required this.level,
    required this.headline,
    this.detail = '',
    this.actionTaken,
  });

  final AdvisoryLevel level;

  /// Short deterministic status line (always available instantly).
  final String headline;

  /// Assistant-narrated explanation (arrives asynchronously).
  final String detail;

  /// What the director already did about it, if anything ("refreshing
  /// paths"), so the user sees the system acting, not just warning.
  final String? actionTaken;

  DirectorAdvisory withDetail(String d) => DirectorAdvisory(
    level: level,
    headline: headline,
    detail: d,
    actionTaken: actionTaken,
  );
}

/// The repair strategies the director can choose between.
enum DirectorStrategy {
  /// Reactive: the connection already weakened — probe, drain, re-rank.
  refreshPaths,

  /// Pre-emptive: the trend predicts a slide while the mode is still
  /// healthy — warm the fallback ranking before anything breaks.
  preWarmFallback,

  /// Deliberate restraint: recent actions did not help, so the director
  /// widens its cooldown instead of hammering a path that is down.
  holdAndObserve,
}

/// How a taken decision turned out, judged on the following snapshot.
enum DecisionOutcome { pending, improved, noEffect }

/// One entry in the director's decision journal: what it did, why, and
/// whether it worked — the trace the UI renders as "what I did and why".
class DirectorDecision {
  DirectorDecision({
    required this.at,
    required this.strategy,
    required this.reason,
    this.outcome = DecisionOutcome.pending,
  });

  final DateTime at;
  final DirectorStrategy strategy;
  final String reason;
  DecisionOutcome outcome;

  String get label => switch (strategy) {
    DirectorStrategy.refreshPaths => 'refreshing paths',
    DirectorStrategy.preWarmFallback => 'pre-warming fallback',
    DirectorStrategy.holdAndObserve => 'holding steady',
  };
}

/// Live decision layer. [ChangeNotifier] so plain `ListenableBuilder`
/// widgets react with zero extra dependencies.
class IntelligenceDirector extends ChangeNotifier {
  IntelligenceDirector({
    required ConnectionFabric fabric,
    required this._hub,
    this.refreshCooldown = const Duration(seconds: 10),
    DateTime Function()? now,
  }) : _fabric = fabric,
       _now = now ?? DateTime.now {
    _sub = fabric.snapshots.listen(_onSnapshot);
    _onSnapshot(fabric.snapshot);
  }

  final ConnectionFabric _fabric;
  final IntelligenceHub _hub;

  /// Minimum spacing between self-healing refresh actions, so a flapping
  /// path cannot make the director thrash.
  final Duration refreshCooldown;

  final DateTime Function() _now;
  static const _playbook = ConnectivityPlaybook();
  StreamSubscription<ConnectivitySnapshot>? _sub;
  DateTime? _lastRefreshAction;
  int _narrationSeq = 0;
  bool _disposed = false;

  /// Consecutive actions that produced no improvement; drives the
  /// exponential cooldown backoff (capped) so a dead path is not hammered.
  int _ineffectiveStreak = 0;
  static const int _maxBackoffShift = 3; // cooldown × 8 at worst

  final List<DirectorDecision> _decisions = [];
  static const int _journalCap = 20;

  /// Newest-first journal of decisions with reasons and judged outcomes.
  List<DirectorDecision> get decisions => List.unmodifiable(_decisions);

  DirectorAdvisory _advisory = const DirectorAdvisory(
    level: AdvisoryLevel.calm,
    headline: 'Starting up',
  );

  /// The single value the UI renders.
  DirectorAdvisory get advisory => _advisory;

  void _onSnapshot(ConnectivitySnapshot snapshot) {
    if (_disposed) return;
    final trendVerdict = snapshot.bestLaneId == null
        ? TrendVerdict.unknown
        : _fabric.trend.verdict(snapshot.bestLaneId!);

    var level = switch (snapshot.mode) {
      FabricMode.live => AdvisoryLevel.calm,
      FabricMode.degraded => AdvisoryLevel.caution,
      FabricMode.storeAndForward ||
      FabricMode.offline => AdvisoryLevel.critical,
    };
    var headline = switch (snapshot.mode) {
      FabricMode.live => 'Connection healthy',
      FabricMode.degraded => 'Connection weakening — compensating',
      FabricMode.storeAndForward => 'Offline — messages are being saved',
      FabricMode.offline => 'No connectivity configured',
    };
    // Foresight beats the present: a live path that is sliding gets a
    // caution BEFORE anything breaks.
    if (level == AdvisoryLevel.calm &&
        (trendVerdict == TrendVerdict.slipping ||
            trendVerdict == TrendVerdict.failingSoon)) {
      level = AdvisoryLevel.caution;
      headline = 'Connection may drop soon — preparing fallback';
    }

    // Judge the previous decision by what this snapshot shows: did the
    // situation actually improve after the action? Failed attempts feed
    // the backoff so the next choice is different, not a repeat.
    _judgePendingDecision(level);

    // ACT, not just report. The strategy is chosen from the situation:
    // a predicted slide gets a pre-emptive fallback warm-up, a real
    // degradation gets a reactive refresh, and a streak of ineffective
    // attempts gets deliberate restraint (widened cooldown).
    String? action;
    final shouldHeal =
        level != AdvisoryLevel.calm && snapshot.mode != FabricMode.offline;
    if (shouldHeal) {
      if (_cooldownElapsed()) {
        final preEmptive = snapshot.mode == FabricMode.live;
        final decision = DirectorDecision(
          at: _now(),
          strategy: preEmptive
              ? DirectorStrategy.preWarmFallback
              : DirectorStrategy.refreshPaths,
          reason: preEmptive
              ? 'trend predicts a slide (${trendVerdict.name}) while the '
                    'lane is still up — re-ranking fallbacks early'
              : 'mode is ${snapshot.mode.name} — probing and re-ranking '
                    'all lanes',
        );
        _record(decision);
        _lastRefreshAction = _now();
        action = '${decision.label} — ${decision.reason}';
        unawaited(_fabric.refresh().catchError((Object _) => 0));
      } else if (_ineffectiveStreak > 0) {
        // Backed off: surface the restraint itself as the decision so the
        // user sees judgment, not silence.
        if (_decisions.isEmpty ||
            _decisions.first.strategy != DirectorStrategy.holdAndObserve) {
          final hold = DirectorDecision(
            at: _now(),
            strategy: DirectorStrategy.holdAndObserve,
            reason:
                'last $_ineffectiveStreak repair(s) did not improve the '
                'link — waiting longer before the next attempt',
            outcome: DecisionOutcome.improved,
          );
          _record(hold);
          action = '${hold.label} — ${hold.reason}';
        }
      }
    }

    // Expert playbook: the single most relevant piece of distilled
    // knowledge serves as instant detail until live narration arrives.
    final insight = _playbook.match(snapshot, trendVerdict);
    _advisory = DirectorAdvisory(
      level: level,
      headline: headline,
      detail: _advisory.headline == headline && _advisory.detail.isNotEmpty
          ? _advisory.detail
          : insight.guidance,
      actionTaken: action ?? _advisory.actionTaken,
    );
    notifyListeners();
    unawaited(_narrate(snapshot));
  }

  /// Scores the still-pending decision against the newest severity: any
  /// step toward calm counts as improvement; anything else counts against
  /// the strategy and lengthens the cooldown (exponential, capped).
  void _judgePendingDecision(AdvisoryLevel nowLevel) {
    final pending = _decisions
        .where(
          (d) =>
              d.outcome == DecisionOutcome.pending &&
              d.strategy != DirectorStrategy.holdAndObserve,
        )
        .toList();
    if (pending.isEmpty) return;
    final improved = nowLevel == AdvisoryLevel.calm;
    for (final d in pending) {
      d.outcome = improved ? DecisionOutcome.improved : DecisionOutcome.noEffect;
    }
    if (improved) {
      _ineffectiveStreak = 0;
    } else {
      _ineffectiveStreak = (_ineffectiveStreak + 1).clamp(0, 16);
    }
  }

  void _record(DirectorDecision d) {
    _decisions.insert(0, d);
    if (_decisions.length > _journalCap) _decisions.removeLast();
  }

  /// Effective cooldown grows ×2 per ineffective attempt (capped ×8) and
  /// snaps back to the base the moment an action works.
  Duration get _effectiveCooldown =>
      refreshCooldown * (1 << _ineffectiveStreak.clamp(0, _maxBackoffShift));

  bool _cooldownElapsed() {
    final last = _lastRefreshAction;
    return last == null || _now().difference(last) >= _effectiveCooldown;
  }

  Future<void> _narrate(ConnectivitySnapshot snapshot) async {
    final seq = ++_narrationSeq;
    try {
      final text = await _hub.assistant.explainConnectivity(snapshot);
      // Only the newest narration wins; stale ones are dropped.
      if (_disposed || seq != _narrationSeq) return;
      _advisory = _advisory.withDetail(text);
      notifyListeners();
    } catch (_) {
      // Narration is decoration; judgment already shipped.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sub?.cancel());
    super.dispose();
  }
}
