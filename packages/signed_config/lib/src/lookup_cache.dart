/// A serve-stale, refresh-in-background cache around a name-lookup function.
///
/// Wraps one function of the extension-point type
/// `Future<String?> Function(String key)` and is itself callable with that
/// signature, so an instance can be substituted anywhere the bare function is
/// accepted: pass the instance directly, or pass the `call` tear-off
/// (`cache.call`).
library;

/// One cached answer, together with when it was fetched and under which
/// validity epoch it was stored.
class _LookupEntry {
  _LookupEntry(this.value, this.fetchedAt, this.epoch);

  final String value;
  final DateTime fetchedAt;
  final Object? epoch;
}

/// A cache around a lookup function (`Future<String?> Function(String key)`)
/// that is itself such a function.
///
/// FRESHNESS RULE — read this before "fixing" anything here.
///
/// The freshness lifetime ([freshFor]) decides only WHEN TO ASK AGAIN. It
/// never decides whether an answer may be served:
///
///   * a fresh entry is served immediately;
///   * a stale entry is ALSO served immediately, and a refresh is started in
///     the background at the same time. If that refresh is slow or fails,
///     the caller already has the stale answer;
///   * an entry leaves service only on a POSITIVE signal: a successful
///     refresh replaces it, the caller reports via [reportFailure] that the
///     answer did not work, or [advanceEpoch] invalidates it.
///
/// Do not convert the stale-serving into an expiry check. The opposite shape
/// (a time check standing between a caller and a usable answer) was already
/// measured as a defect in another component of this project: it rejected
/// authentic material because a clock disagreed. Expiry must never stand
/// between the caller and a usable answer.
///
/// MEMORY BOUND — the cache holds at most [maxEntries] entries. When an
/// insert would exceed the cap, the least recently used entry is evicted
/// (every successful lookup marks its entry as most recently used).
///
/// UPSTREAM CONTRACT — the wrapped function returning `null` means "I have
/// no answer, fall back to the platform's own mechanism". That is a normal
/// outcome, not an error, and is never cached. An upstream that throws is
/// treated the same way: the error is swallowed, the caller gets `null` (or
/// the stale answer it was already served), and any cached entry stays in
/// service. No upstream failure ever throws into a caller of this cache.
class LookupCache {
  /// [upstream] is the wrapped lookup function.
  ///
  /// [freshFor] is how long an answer counts as fresh; after that it is
  /// still served, but each serve also starts a background refresh.
  ///
  /// [maxEntries] bounds memory; least recently used entries are evicted
  /// past the cap.
  ///
  /// [clock] is injectable so a test can drive time without waiting; it
  /// defaults to the real clock.
  LookupCache(
    this._upstream, {
    this.freshFor = const Duration(minutes: 10),
    this.maxEntries = 256,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Future<String?> Function(String key) _upstream;

  /// How long an answer counts as fresh. Controls only when a background
  /// refresh is started, never whether an answer is served — see the class
  /// comment.
  final Duration freshFor;

  /// Maximum number of entries held; past this the least recently used
  /// entry is evicted.
  final int maxEntries;

  final DateTime Function() _clock;

  /// Insertion-ordered map used as the LRU structure: a Dart map literal is
  /// insertion-ordered, so the first key is always the least recently used
  /// (entries are re-inserted on every serve).
  final Map<String, _LookupEntry> _entries = {};

  /// At most one refresh in flight per key. A lookup that misses while a
  /// refresh for the same key is already running joins that future instead
  /// of starting a second upstream request.
  final Map<String, Future<String?>> _inFlight = {};

  /// The current validity epoch, set by [advanceEpoch]. Entries record the
  /// epoch under which they were stored.
  Object? _epoch;

  int _freshHits = 0;
  int _staleHits = 0;
  int _misses = 0;

  /// Lookups answered from an entry still inside [freshFor].
  int get freshHits => _freshHits;

  /// Lookups answered from an entry past [freshFor] (served anyway, with a
  /// background refresh started — see the class comment).
  int get staleHits => _staleHits;

  /// Lookups with no cached entry at all, answered by going upstream (or by
  /// joining a refresh already in flight for the key).
  int get misses => _misses;

  /// Looks up [key], matching the extension-point signature.
  ///
  /// Cached entry present: it is served immediately, fresh or stale — a
  /// stale serve additionally starts a background refresh. No entry: goes
  /// upstream (joining any refresh already in flight for [key]) and returns
  /// its answer, or `null` when upstream has none or fails.
  Future<String?> call(String key) async {
    final entry = _entries.remove(key);
    if (entry != null) {
      _entries[key] = entry; // Re-insert: mark as most recently used.
      if (_clock().difference(entry.fetchedAt) < freshFor) {
        _freshHits++;
      } else {
        _staleHits++;
        // Ask again in the background; the caller is not made to wait, and
        // _refresh never completes with an error (see _refresh), so this
        // unawaited future is safe.
        _refresh(key);
      }
      return entry.value;
    }
    _misses++;
    return _refresh(key);
  }

  /// The caller reports that the answer served for [key] did not work.
  ///
  /// This is one of the three positive signals that remove an entry from
  /// service (the others: a successful refresh replacing it, and
  /// [advanceEpoch]). The next lookup for [key] will go upstream.
  void reportFailure(String key) {
    _entries.remove(key);
  }

  /// External validity signal: everything not stored under [epoch] is no
  /// longer valid.
  ///
  /// Drops every entry that does not carry [epoch] and makes [epoch] the
  /// one that new entries are stored under. Calling it again with the same
  /// identifier is a no-op for entries already carrying it.
  void advanceEpoch(Object epoch) {
    _epoch = epoch;
    _entries.removeWhere((_, entry) => entry.epoch != epoch);
  }

  /// Starts (or joins) the single in-flight refresh for [key].
  ///
  /// The returned future NEVER completes with an error: an upstream throw is
  /// swallowed and yields `null`, so neither a caller awaiting a miss nor
  /// the fire-and-forget stale path can be thrown into. The in-flight marker
  /// is cleared in a `finally`, so no failure can leave the key permanently
  /// marked as refreshing.
  Future<String?> _refresh(String key) {
    final running = _inFlight[key];
    if (running != null) {
      return running;
    }
    final epochAtStart = _epoch;
    final future = () async {
      try {
        final value = await _upstream(key);
        if (value != null) {
          _store(key, value, epochAtStart);
        }
        // value == null is "no answer" — normal, not cached, and it does
        // NOT remove an existing stale entry: only a positive signal does.
        return value;
      } catch (_) {
        // Upstream failure: the stale entry (if any) stays in service and
        // the caller falls back via null. Never rethrown.
        return null;
      } finally {
        _inFlight.remove(key);
      }
    }();
    _inFlight[key] = future;
    return future;
  }

  /// Stores a successful answer, evicting the least recently used entry
  /// when the cap is exceeded.
  ///
  /// [epochAtStart] is the epoch the refresh began under; if [advanceEpoch]
  /// ran while the request was in flight, the answer was fetched under an
  /// invalidated view and is not stored (it was still returned to whoever
  /// awaited the refresh).
  void _store(String key, String value, Object? epochAtStart) {
    if (epochAtStart != _epoch) {
      return;
    }
    _entries.remove(key);
    _entries[key] = _LookupEntry(value, _clock(), _epoch);
    if (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first); // Least recently used.
    }
  }
}
