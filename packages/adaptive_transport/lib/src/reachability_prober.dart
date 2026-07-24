/// Active endpoint reachability discovery.
///
/// The application supplies candidate endpoint [Uri]s and an injected probe
/// callback; the [ReachabilityProber] learns which candidates are currently
/// reachable, measures probe latency, and ranks candidates by the same
/// EWMA-smoothed [ChannelHealth] scoring used by path selection. Each
/// candidate is additionally guarded by a [CircuitBreaker] so persistently
/// unreachable endpoints rest instead of being re-probed forever.
///
/// The prober never invents destinations: it only ever contacts the
/// app-supplied candidate list, through the app-supplied callback.
library;

import 'dart:async';

import 'circuit_breaker.dart';
import 'transport_channel.dart';

/// Application-supplied reachability check for a single candidate endpoint.
///
/// Returns `true` when the candidate answered, `false` (or throws) when it
/// did not. The prober applies its own per-probe timeout on top.
typedef ProbeCallback = Future<bool> Function(Uri candidate);

class _CandidateState {
  final Uri uri;
  final int order;
  final ChannelHealth health;
  final CircuitBreaker breaker;

  /// Result of the most recent completed probe, if any.
  bool? lastResult;

  /// When the most recent probe result was recorded (cooldown cache key).
  DateTime? lastProbedAt;

  _CandidateState(this.uri, this.order, this.health, this.breaker);
}

/// Probes candidate endpoints and ranks them by measured reachability.
///
/// One probe round ([probeAll]) starts candidates on a staggered schedule
/// and completes as soon as the first candidate succeeds (fast winner).
/// Results feed per-candidate EWMA health scores and circuit breakers;
/// [ranked] and [rankings] expose the resulting order.
class ReachabilityProber {
  final ProbeCallback _probe;
  final Duration _stagger;
  final Duration _probeTimeout;
  final Duration _cooldown;
  final Clock _now;
  final double _alpha;

  final List<_CandidateState> _states;

  /// Every live [Timer] created by the prober; entries are removed when a
  /// timer fires or is cancelled, so [dispose] can cancel exactly the
  /// outstanding ones and tests can assert zero leaks.
  final Set<Timer> _timers = <Timer>{};

  /// Stagger timers for probes that have not started yet this round.
  final List<Timer> _pendingStarts = <Timer>[];

  final StreamController<List<Uri>> _rankingsController =
      StreamController<List<Uri>>.broadcast();

  late List<Uri> _lastRanking;

  Completer<Uri?>? _roundCompleter;
  Future<Uri?>? _roundFuture;
  int _outstanding = 0;
  bool _disposed = false;

  /// Creates a prober over a non-empty, app-supplied candidate list.
  ///
  /// [now] is an injectable clock used for RTT measurement, cooldown, and
  /// the per-candidate circuit breakers; it defaults to [DateTime.now].
  ReachabilityProber({
    required List<Uri> candidates,
    required ProbeCallback probe,
    Duration stagger = const Duration(milliseconds: 200),
    Duration probeTimeout = const Duration(seconds: 2),
    Duration cooldown = const Duration(seconds: 60),
    DateTime Function()? now,
    double alpha = 0.3,
    CircuitBreakerConfig? breakerConfig,
  }) : _probe = probe,
       _stagger = stagger,
       _probeTimeout = probeTimeout,
       _cooldown = cooldown,
       _now = now ?? DateTime.now,
       _alpha = alpha,
       _states = <_CandidateState>[] {
    if (candidates.isEmpty) {
      throw ArgumentError.value(candidates, 'candidates', 'must be non-empty');
    }
    if (probeTimeout <= Duration.zero) {
      throw ArgumentError.value(
        probeTimeout,
        'probeTimeout',
        'must be positive',
      );
    }
    if (alpha <= 0.0 || alpha > 1.0) {
      throw ArgumentError.value(alpha, 'alpha', 'must be in (0, 1]');
    }
    if (stagger.isNegative) {
      throw ArgumentError.value(stagger, 'stagger', 'must be non-negative');
    }
    if (cooldown.isNegative) {
      throw ArgumentError.value(cooldown, 'cooldown', 'must be non-negative');
    }
    for (var i = 0; i < candidates.length; i++) {
      _states.add(
        _CandidateState(
          candidates[i],
          i,
          ChannelHealth(reliabilityPrior: 1.0, bandwidth: 1.0),
          CircuitBreaker(
            config: breakerConfig ?? const CircuitBreakerConfig(),
            clock: _now,
          ),
        ),
      );
    }
    _lastRanking = _computeRanked();
  }

  /// Candidates currently admitted by their circuit breaker, sorted by
  /// descending [ChannelHealth.score]; ties keep original candidate order.
  ///
  /// Uses the breaker's pure `state` view (open = excluded) rather than
  /// `allowsRequest()`, so reading the ranking never consumes half-open
  /// probe budget.
  List<Uri> get ranked => _computeRanked();

  /// Emits the new ranked list whenever a recorded probe result changes the
  /// ranking (element-by-element comparison; unchanged rankings don't emit).
  Stream<List<Uri>> get rankings => _rankingsController.stream;

  /// Runs one probe round and completes with the first candidate that
  /// answers, or `null` if every started probe fails or times out.
  ///
  /// Candidates whose cached result is younger than the cooldown are not
  /// re-probed; their cached result stands. The remaining candidates start
  /// staggered; the first success wins the round, cancels not-yet-started
  /// probes, and completes the returned future immediately. Probes already
  /// in flight still record their result when they land, without delaying
  /// completion.
  ///
  /// Calling [probeAll] while a round is still settling returns the same
  /// in-flight future instead of starting a new round.
  Future<Uri?> probeAll() {
    if (_disposed) {
      throw StateError('ReachabilityProber has been disposed');
    }
    final existing = _roundFuture;
    if (existing != null) return existing;

    final completer = Completer<Uri?>();
    _roundCompleter = completer;
    _roundFuture = completer.future;

    final now = _now();
    final due = _states
        .where(
          (s) =>
              s.lastProbedAt == null ||
              now.difference(s.lastProbedAt!) >= _cooldown,
        )
        .toList();

    if (due.isEmpty) {
      // Everything is inside the cooldown window: the cached results stand.
      // Complete with the best-ranked candidate whose cached probe
      // succeeded, or null when none did.
      Uri? cachedWinner;
      for (final uri in _computeRanked()) {
        final s = _states.firstWhere((s) => s.uri == uri);
        if (s.lastResult == true) {
          cachedWinner = uri;
          break;
        }
      }
      completer.complete(cachedWinner);
      _roundCompleter = null;
      _roundFuture = null;
      return completer.future;
    }

    for (var i = 0; i < due.length; i++) {
      final state = due[i];
      _outstanding++;
      late Timer starter;
      starter = Timer(_stagger * i, () {
        _timers.remove(starter);
        _pendingStarts.remove(starter);
        _launchProbe(state);
      });
      _timers.add(starter);
      _pendingStarts.add(starter);
    }
    return completer.future;
  }

  /// Invalidates the cooldown cache for every candidate so the next
  /// [probeAll] re-probes all of them. Does not itself probe.
  void onNetworkChanged() {
    for (final s in _states) {
      s.lastProbedAt = null;
    }
  }

  /// Cancels all outstanding timers and closes [rankings]. An in-flight
  /// round completes with `null`; late probe completions are ignored.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final t in List<Timer>.of(_timers)) {
      t.cancel();
    }
    _timers.clear();
    _pendingStarts.clear();
    final completer = _roundCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(null);
    }
    _roundCompleter = null;
    _roundFuture = null;
    _outstanding = 0;
    _rankingsController.close();
  }

  void _launchProbe(_CandidateState state) {
    if (_disposed) {
      _outstanding--;
      _maybeSettle();
      return;
    }
    final start = _now();
    var settled = false;

    late Timer timeout;
    timeout = Timer(_probeTimeout, () {
      _timers.remove(timeout);
      if (settled) return;
      settled = true;
      if (!_disposed) _record(state, success: false, start: start);
      _outstanding--;
      _maybeSettle();
    });
    _timers.add(timeout);

    unawaited(
      _probe(state.uri).then(
        (ok) {
          if (settled) return;
          settled = true;
          timeout.cancel();
          _timers.remove(timeout);
          if (!_disposed) {
            _record(state, success: ok, start: start);
            if (ok) _declareWinner(state.uri);
          }
          _outstanding--;
          _maybeSettle();
        },
        onError: (Object _) {
          if (settled) return;
          settled = true;
          timeout.cancel();
          _timers.remove(timeout);
          if (!_disposed) _record(state, success: false, start: start);
          _outstanding--;
          _maybeSettle();
        },
      ),
    );
  }

  void _record(
    _CandidateState state, {
    required bool success,
    required DateTime start,
  }) {
    final now = _now();
    if (success) {
      final rttMs = now.difference(start).inMilliseconds;
      state.health.observe(
        SendResult(SendStatus.ok, rttMs: rttMs),
        alpha: _alpha,
      );
      state.breaker.recordSuccess();
    } else {
      state.health.observe(
        const SendResult(SendStatus.transient),
        alpha: _alpha,
      );
      state.breaker.recordFailure();
    }
    state.lastResult = success;
    state.lastProbedAt = now;
    _emitIfRankingChanged();
  }

  void _declareWinner(Uri winner) {
    final completer = _roundCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(winner);
    }
    // Candidates whose stagger timer has not fired yet are not probed this
    // round; they keep their previous state.
    for (final t in List<Timer>.of(_pendingStarts)) {
      t.cancel();
      _timers.remove(t);
      _outstanding--;
    }
    _pendingStarts.clear();
  }

  void _maybeSettle() {
    if (_outstanding > 0) return;
    final completer = _roundCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(null); // Every started probe failed or timed out.
    }
    _roundCompleter = null;
    _roundFuture = null;
  }

  List<Uri> _computeRanked() {
    final admitted = _states
        .where((s) => s.breaker.state != CircuitState.open)
        .toList();
    admitted.sort((a, b) {
      final byScore = b.health.score().compareTo(a.health.score());
      if (byScore != 0) return byScore;
      return a.order.compareTo(b.order);
    });
    return admitted.map((s) => s.uri).toList();
  }

  void _emitIfRankingChanged() {
    final current = _computeRanked();
    var changed = current.length != _lastRanking.length;
    if (!changed) {
      for (var i = 0; i < current.length; i++) {
        if (current[i] != _lastRanking[i]) {
          changed = true;
          break;
        }
      }
    }
    if (changed) {
      _lastRanking = current;
      if (!_rankingsController.isClosed) {
        _rankingsController.add(List<Uri>.unmodifiable(current));
      }
    }
  }
}
