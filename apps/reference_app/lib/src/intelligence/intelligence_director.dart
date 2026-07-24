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
  StreamSubscription<ConnectivitySnapshot>? _sub;
  DateTime? _lastRefreshAction;
  int _narrationSeq = 0;
  bool _disposed = false;

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

    // ACT, not just report: a sliding or broken state kicks a refresh
    // (probe + drain + re-rank), rate-limited by the cooldown.
    String? action;
    final shouldHeal =
        level != AdvisoryLevel.calm && snapshot.mode != FabricMode.offline;
    if (shouldHeal && _cooldownElapsed()) {
      _lastRefreshAction = _now();
      action = 'refreshing paths';
      unawaited(_fabric.refresh().catchError((Object _) => 0));
    }

    _advisory = DirectorAdvisory(
      level: level,
      headline: headline,
      detail: _advisory.headline == headline ? _advisory.detail : '',
      actionTaken: action ?? _advisory.actionTaken,
    );
    notifyListeners();
    unawaited(_narrate(snapshot));
  }

  bool _cooldownElapsed() {
    final last = _lastRefreshAction;
    return last == null || _now().difference(last) >= refreshCooldown;
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
