import 'dart:math';

import 'validation.dart';

/// The circumstances a [ReconnectPolicy] evaluates to decide whether (and
/// when) `CallController` should retry after a failure.
final class ReconnectContext {
  /// Creates a context. Throws [ArgumentError] if [attempt] is less than 1
  /// or [elapsed] is negative.
  ReconnectContext({
    required this.attempt,
    required this.elapsed,
    required this.cause,
  }) {
    if (attempt < 1) {
      throw ArgumentError.value(attempt, 'attempt');
    }
    if (elapsed.isNegative) {
      throw ArgumentError.value(elapsed, 'elapsed');
    }
  }

  /// The 1-based number of this recovery attempt (1 for the first retry
  /// after the initial failure, 2 for the retry after that, ...).
  final int attempt;

  /// How much time has passed since recovery began for the current failure
  /// episode (reset once a recovery succeeds).
  final Duration elapsed;

  /// The error that triggered this recovery episode, or — on the 2nd and
  /// later attempts — the error from the most recent failed attempt.
  final Object cause;
}

/// What a [ReconnectPolicy] decided in response to a [ReconnectContext]:
/// either retry after [delay], or give up (optionally with [reason]).
final class ReconnectDecision {
  /// Retry after waiting [delay]. Throws [ArgumentError] if [delay] is
  /// negative.
  ReconnectDecision.retry(this.delay) : shouldRetry = true, reason = null {
    if (delay.isNegative) {
      throw ArgumentError.value(delay, 'delay');
    }
  }

  /// Stop retrying. `CallController` ends the call with
  /// `CallEndReason.reconnectExhausted`, using [reason] (if given) as the
  /// resulting exception's message.
  ///
  /// Throws [ArgumentError] if [reason] is longer than 256 characters or
  /// contains a control character ([containsControlCharacters]).
  ReconnectDecision.giveUp([this.reason])
    : shouldRetry = false,
      delay = Duration.zero {
    final value = reason;
    if (value != null &&
        (value.length > 256 || containsControlCharacters(value))) {
      throw ArgumentError.value(value, 'reason');
    }
  }

  /// Whether to attempt another reconnect. When `false`, [delay] is always
  /// [Duration.zero] (unused) and [reason] may explain why.
  final bool shouldRetry;

  /// How long to wait before the next attempt. Only meaningful when
  /// [shouldRetry] is `true`.
  final Duration delay;

  /// An optional human-readable explanation for giving up. Only meaningful
  /// when [shouldRetry] is `false`.
  final String? reason;
}

/// Decides whether/when `CallController` retries after a transport,
/// signaling, or media failure.
///
/// [evaluate] is called once per failure needing a decision: once when
/// recovery begins ([ReconnectContext.attempt] `1`), and again after each
/// subsequent failed attempt. Implementations may be stateless (pure
/// function of [ReconnectContext]) or stateful — `CallController` always
/// supplies a fresh, self-consistent [ReconnectContext] each time, so
/// either style works.
///
/// If [evaluate] throws, `CallController` treats that as an immediate
/// give-up (`CallControllerException` code `invalid_reconnect_policy`) —
/// a broken policy never wedges the call in a retry loop.
abstract interface class ReconnectPolicy {
  /// Returns the [ReconnectDecision] for the current [context].
  ReconnectDecision evaluate(ReconnectContext context);
}

/// A [ReconnectPolicy] implementing exponential backoff with full jitter,
/// capped in both delay and total elapsed time.
///
/// Algorithm — "full jitter over a doubling cap" (per the well-known
/// exponential-backoff-with-jitter pattern): for [ReconnectContext.attempt]
/// `n`, the delay's upper bound doubles with each attempt starting from
/// [baseDelay] (`baseDelay, baseDelay*2, baseDelay*4, ...`), saturating at
/// [maxDelay] once the doubling would exceed it, and the actual delay
/// returned is drawn UNIFORMLY at random from `[0, cap]` — not `cap`
/// itself. This is "full jitter": the entire range is randomized (as
/// opposed to "equal jitter", which would only randomize a half-range
/// around a midpoint), which spreads out multiple clients' retries more
/// effectively and avoids every client retrying in lockstep after a
/// shared outage.
///
/// Gives up ([ReconnectDecision.giveUp]) as soon as either budget is
/// exhausted: [ReconnectContext.attempt] exceeds [maxAttempts], OR
/// [ReconnectContext.elapsed] has reached [maxElapsed] — whichever comes
/// first.
final class ExponentialBackoffReconnectPolicy implements ReconnectPolicy {
  /// Creates a policy. Throws [ArgumentError] if [maxAttempts] is less
  /// than 1; [baseDelay] is negative; [maxDelay] is negative or less than
  /// [baseDelay]; or [maxElapsed] is not positive.
  ExponentialBackoffReconnectPolicy({
    this.maxAttempts = 8,
    this.baseDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 20),
    this.maxElapsed = const Duration(minutes: 2),
    this.provenance,
    Random? random,
  }) : _random = random ?? Random() {
    if (maxAttempts < 1) {
      throw ArgumentError.value(maxAttempts, 'maxAttempts');
    }
    if (baseDelay.isNegative) {
      throw ArgumentError.value(baseDelay, 'baseDelay');
    }
    if (maxDelay.isNegative || maxDelay < baseDelay) {
      throw ArgumentError.value(maxDelay, 'maxDelay');
    }
    if (maxElapsed <= Duration.zero) {
      throw ArgumentError.value(maxElapsed, 'maxElapsed');
    }
  }

  /// The most attempts this policy allows before giving up.
  final int maxAttempts;

  /// The delay cap for the very first attempt (`n = 1`), before any
  /// doubling.
  final Duration baseDelay;

  /// The upper bound the doubling delay cap saturates at, no matter how
  /// many attempts have elapsed.
  final Duration maxDelay;

  /// The total elapsed-time budget for one recovery episode; once
  /// [ReconnectContext.elapsed] reaches this, the policy gives up
  /// regardless of [maxAttempts].
  final Duration maxElapsed;

  /// Where this policy's numbers came from (e.g. the derived budget's
  /// conditions and attempt cost), stamped into the give-up reason so the
  /// terminal error carries its own evidence. Filled by
  /// `AdaptiveConnectionBudget.toReconnectPolicy`; null adds nothing.
  final String? provenance;

  final Random _random;

  @override
  ReconnectDecision evaluate(ReconnectContext context) {
    if (context.attempt > maxAttempts || context.elapsed >= maxElapsed) {
      // A give-up that names no numbers sends the next debugging session
      // into the logs to reconstruct what this line already knew: which cap
      // bound, how far the episode got, and what budget it was judged
      // against (measured 2026-08-06: every hostile-profile row ended in a
      // bare "Reconnect budget exhausted").
      final bound = context.attempt > maxAttempts
          ? 'attempts ${context.attempt} > max $maxAttempts'
          : 'elapsed ${context.elapsed.inSeconds}s >= '
                'max ${maxElapsed.inSeconds}s';
      var reason =
          'Reconnect budget exhausted ($bound; '
          'attempt ${context.attempt}/$maxAttempts, '
          'elapsed ${context.elapsed.inSeconds}s/${maxElapsed.inSeconds}s'
          '${provenance == null ? '' : '; $provenance'})';
      if (reason.length > 256) {
        reason = '${reason.substring(0, 253)}...';
      }
      return ReconnectDecision.giveUp(reason);
    }

    var capMilliseconds = baseDelay.inMilliseconds;
    for (var i = 1; i < context.attempt; i++) {
      if (capMilliseconds >= maxDelay.inMilliseconds) {
        capMilliseconds = maxDelay.inMilliseconds;
        break;
      }
      capMilliseconds = min(maxDelay.inMilliseconds, capMilliseconds * 2);
    }

    if (capMilliseconds <= 0) {
      return ReconnectDecision.retry(Duration.zero);
    }

    return ReconnectDecision.retry(
      Duration(milliseconds: _random.nextInt(capMilliseconds + 1)),
    );
  }
}
