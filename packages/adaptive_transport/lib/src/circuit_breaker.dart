/// Circuit breaker for transport paths and service calls.
///
/// Standard closed / open / half-open state machine:
///
/// - **closed**: requests flow normally; consecutive failures are counted.
/// - **open**: after [CircuitBreakerConfig.failureThreshold] consecutive
///   failures the breaker trips and rejects requests for
///   [CircuitBreakerConfig.openDuration].
/// - **half-open**: after the cool-down, a limited number of trial requests
///   ([CircuitBreakerConfig.halfOpenMaxProbes]) are allowed through.
///   [CircuitBreakerConfig.halfOpenSuccessesToClose] consecutive successes
///   close the breaker; any failure re-opens it with exponential back-off up
///   to [CircuitBreakerConfig.maxOpenDuration].
///
/// New in v2 (no v1 equivalent): the v1 router halved availability on
/// failure but kept hammering dead paths; the breaker gives dead paths an
/// explicit rest period and a controlled re-entry.
library;

enum CircuitState { closed, open, halfOpen }

class CircuitBreakerConfig {
  /// Consecutive failures in the closed state that trip the breaker.
  final int failureThreshold;

  /// Initial cool-down before the first half-open probe window.
  final Duration openDuration;

  /// Upper bound for the exponentially backed-off cool-down.
  final Duration maxOpenDuration;

  /// Maximum trial requests admitted while half-open.
  final int halfOpenMaxProbes;

  /// Consecutive half-open successes required to close the breaker.
  final int halfOpenSuccessesToClose;

  const CircuitBreakerConfig({
    this.failureThreshold = 5,
    this.openDuration = const Duration(seconds: 10),
    this.maxOpenDuration = const Duration(minutes: 5),
    this.halfOpenMaxProbes = 2,
    this.halfOpenSuccessesToClose = 2,
  });

  void _validate() {
    if (failureThreshold < 1) {
      throw RangeError.range(failureThreshold, 1, null, 'failureThreshold');
    }
    if (halfOpenMaxProbes < 1) {
      throw RangeError.range(halfOpenMaxProbes, 1, null, 'halfOpenMaxProbes');
    }
    if (halfOpenSuccessesToClose < 1) {
      throw RangeError.range(
        halfOpenSuccessesToClose,
        1,
        null,
        'halfOpenSuccessesToClose',
      );
    }
    if (openDuration.isNegative || openDuration == Duration.zero) {
      throw ArgumentError.value(openDuration, 'openDuration');
    }
    if (maxOpenDuration < openDuration) {
      throw ArgumentError.value(
        maxOpenDuration,
        'maxOpenDuration',
        'must be >= openDuration',
      );
    }
  }
}

/// Injectable clock for deterministic tests.
typedef Clock = DateTime Function();

class CircuitBreaker {
  final CircuitBreakerConfig config;
  final Clock _clock;

  CircuitState _state = CircuitState.closed;
  int _consecutiveFailures = 0;
  int _halfOpenSuccesses = 0;
  int _halfOpenProbesIssued = 0;
  int _openCycles = 0;
  DateTime? _openedAt;

  CircuitBreaker({
    this.config = const CircuitBreakerConfig(),
    Clock? clock,
  }) : _clock = clock ?? DateTime.now {
    config._validate();
  }

  CircuitState get state {
    _maybeTransitionToHalfOpen();
    return _state;
  }

  /// Current cool-down for the open state, with exponential back-off per
  /// consecutive open cycle, capped at [CircuitBreakerConfig.maxOpenDuration].
  Duration get currentOpenDuration {
    final cycles = _openCycles < 1 ? 1 : _openCycles;
    var duration = config.openDuration;
    for (var i = 1; i < cycles; i++) {
      duration *= 2;
      if (duration >= config.maxOpenDuration) {
        return config.maxOpenDuration;
      }
    }
    return duration > config.maxOpenDuration
        ? config.maxOpenDuration
        : duration;
  }

  /// Whether a request may pass through right now.
  ///
  /// In the half-open state this consumes one of the limited probe slots, so
  /// callers must pair every `true` with a later [recordSuccess] or
  /// [recordFailure].
  bool allowsRequest() {
    _maybeTransitionToHalfOpen();
    switch (_state) {
      case CircuitState.closed:
        return true;
      case CircuitState.open:
        return false;
      case CircuitState.halfOpen:
        if (_halfOpenProbesIssued >= config.halfOpenMaxProbes) {
          return false;
        }
        _halfOpenProbesIssued++;
        return true;
    }
  }

  void recordSuccess() {
    _maybeTransitionToHalfOpen();
    switch (_state) {
      case CircuitState.closed:
        _consecutiveFailures = 0;
      case CircuitState.halfOpen:
        _halfOpenSuccesses++;
        if (_halfOpenSuccesses >= config.halfOpenSuccessesToClose) {
          _reset();
        }
      case CircuitState.open:
        // A success while open (e.g. an in-flight request that started
        // before the trip) is a strong recovery signal: move to half-open
        // and count it.
        _enterHalfOpen();
        _halfOpenSuccesses = 1;
        if (_halfOpenSuccesses >= config.halfOpenSuccessesToClose) {
          _reset();
        }
    }
  }

  void recordFailure() {
    _maybeTransitionToHalfOpen();
    switch (_state) {
      case CircuitState.closed:
        _consecutiveFailures++;
        if (_consecutiveFailures >= config.failureThreshold) {
          _trip();
        }
      case CircuitState.halfOpen:
        _trip();
      case CircuitState.open:
        break; // Already open; nothing to do.
    }
  }

  /// Forces the breaker back to closed (e.g. after an operator action or a
  /// full reconfiguration of the underlying path).
  void resetToClosed() => _reset();

  void _trip() {
    _state = CircuitState.open;
    _openedAt = _clock();
    _openCycles++;
    _consecutiveFailures = 0;
    _halfOpenSuccesses = 0;
    _halfOpenProbesIssued = 0;
  }

  void _enterHalfOpen() {
    _state = CircuitState.halfOpen;
    _halfOpenSuccesses = 0;
    _halfOpenProbesIssued = 0;
  }

  void _reset() {
    _state = CircuitState.closed;
    _consecutiveFailures = 0;
    _halfOpenSuccesses = 0;
    _halfOpenProbesIssued = 0;
    _openCycles = 0;
    _openedAt = null;
  }

  void _maybeTransitionToHalfOpen() {
    if (_state != CircuitState.open) return;
    final openedAt = _openedAt;
    if (openedAt == null) return;
    if (_clock().difference(openedAt) >= currentOpenDuration) {
      _enterHalfOpen();
    }
  }
}
