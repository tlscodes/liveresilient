import 'dart:math' as math;

/// The only reconnect operation produced by this policy.
///
/// An ICE restart must be performed through the WebRTC peer connection, such
/// as `RTCPeerConnection.restartIce()` or an offer created with ICE restart
/// enabled.
enum ReconnectTrigger {
  iceRestart,
}

/// Invokes the application's standards-based WebRTC ICE restart operation.
typedef IceRestartCallback = Future<void> Function();

/// An immutable reconnect attempt issued by [ReconnectPolicy].
final class ReconnectAttempt {
  const ReconnectAttempt._({
    required this.number,
    required this.delay,
    required this.isFinalAttempt,
  });

  /// One-based attempt number.
  final int number;

  /// Delay to observe before performing [trigger].
  final Duration delay;

  /// Whether issuing another attempt would exhaust the policy.
  final bool isFinalAttempt;

  /// The standards-based operation required for this attempt.
  ReconnectTrigger get trigger => ReconnectTrigger.iceRestart;

  /// Invokes [restartIce].
  ///
  /// Delay scheduling and cancellation remain the caller's responsibility.
  Future<void> triggerIceRestart(IceRestartCallback restartIce) {
    return restartIce();
  }

  @override
  String toString() {
    return 'ReconnectAttempt('
        'number: $number, '
        'delay: $delay, '
        'trigger: $trigger, '
        'isFinalAttempt: $isFinalAttempt'
        ')';
  }
}

/// Stateful, bounded exponential-backoff policy for WebRTC ICE restarts.
///
/// Each call to [nextAttempt] consumes one attempt. Call [reset] only after
/// connectivity has been restored or a new call session has begun.
///
/// Before jitter, the delay for attempt `n` is:
///
/// `min(maxDelay, initialDelay * backoffMultiplier^(n - 1))`
///
/// Jitter is sampled uniformly from the bounded interval centered on that
/// delay with radius `delay * jitterFactor`. The upper endpoint is always
/// capped at [maxDelay].
final class ReconnectPolicy {
  factory ReconnectPolicy({
    int maxAttempts = 6,
    Duration initialDelay = const Duration(milliseconds: 500),
    Duration maxDelay = const Duration(seconds: 30),
    double backoffMultiplier = 2.0,
    double jitterFactor = 0.2,
    math.Random? random,
  }) {
    if (maxAttempts < 0) {
      throw RangeError.range(maxAttempts, 0, null, 'maxAttempts');
    }
    if (initialDelay <= Duration.zero) {
      throw ArgumentError.value(
        initialDelay,
        'initialDelay',
        'Must be greater than zero.',
      );
    }
    if (maxDelay < initialDelay) {
      throw ArgumentError.value(
        maxDelay,
        'maxDelay',
        'Must be greater than or equal to initialDelay.',
      );
    }
    if (!backoffMultiplier.isFinite || backoffMultiplier <= 1.0) {
      throw ArgumentError.value(
        backoffMultiplier,
        'backoffMultiplier',
        'Must be finite and greater than 1.0.',
      );
    }
    if (!jitterFactor.isFinite ||
        jitterFactor < 0.0 ||
        jitterFactor > 1.0) {
      throw ArgumentError.value(
        jitterFactor,
        'jitterFactor',
        'Must be finite and in the inclusive range 0.0 to 1.0.',
      );
    }

    return ReconnectPolicy._(
      maxAttempts: maxAttempts,
      initialDelay: initialDelay,
      maxDelay: maxDelay,
      backoffMultiplier: backoffMultiplier,
      jitterFactor: jitterFactor,
      random: random ?? math.Random(),
    );
  }

  ReconnectPolicy._({
    required this.maxAttempts,
    required this.initialDelay,
    required this.maxDelay,
    required this.backoffMultiplier,
    required this.jitterFactor,
    required math.Random random,
  }) : _random = random;

  /// Maximum number of reconnect attempts, excluding the initial connection.
  final int maxAttempts;

  /// Unjittered delay for the first reconnect attempt.
  final Duration initialDelay;

  /// Absolute upper bound for every issued delay.
  final Duration maxDelay;

  /// Exponential growth factor applied between attempts.
  final double backoffMultiplier;

  /// Fractional jitter radius in the inclusive range 0.0 to 1.0.
  final double jitterFactor;

  final math.Random _random;

  int _attemptsIssued = 0;

  /// Number of attempts already consumed.
  int get attemptsIssued => _attemptsIssued;

  /// Number of attempts that may still be consumed.
  int get attemptsRemaining => maxAttempts - _attemptsIssued;

  /// Whether no further attempt can be issued.
  bool get isExhausted => _attemptsIssued >= maxAttempts;

  /// Consumes and returns the next reconnect attempt.
  ///
  /// Returns `null` without changing state when the policy is exhausted.
  ReconnectAttempt? nextAttempt() {
    if (isExhausted) {
      return null;
    }

    final attemptNumber = _attemptsIssued + 1;
    final delay = _delayForAttempt(attemptNumber);
    _attemptsIssued = attemptNumber;

    return ReconnectAttempt._(
      number: attemptNumber,
      delay: delay,
      isFinalAttempt: _attemptsIssued == maxAttempts,
    );
  }

  /// Restores the policy to its initial attempt state.
  void reset() {
    _attemptsIssued = 0;
  }

  Duration _delayForAttempt(int attemptNumber) {
    final initialMicros = initialDelay.inMicroseconds;
    final maximumMicros = maxDelay.inMicroseconds;
    final exponent = attemptNumber - 1;

    final growth = math.pow(backoffMultiplier, exponent).toDouble();
    final scaledMicros = initialMicros.toDouble() * growth;

    final int baseMicros;
    if (!scaledMicros.isFinite || scaledMicros >= maximumMicros) {
      baseMicros = maximumMicros;
    } else {
      baseMicros = scaledMicros.round().clamp(
        initialMicros,
        maximumMicros,
      );
    }

    if (jitterFactor == 0.0) {
      return Duration(microseconds: baseMicros);
    }

    final unitSample = _random.nextDouble();
    if (!unitSample.isFinite ||
        unitSample < 0.0 ||
        unitSample >= 1.0) {
      throw StateError(
        'Random.nextDouble() returned $unitSample; expected a finite value '
        'in the range [0.0, 1.0).',
      );
    }

    final spreadMicros = baseMicros * jitterFactor;
    final lowerMicros = math.max(0.0, baseMicros - spreadMicros);
    final upperMicros = math.min(
      maximumMicros.toDouble(),
      baseMicros + spreadMicros,
    );
    final sampledMicros =
        lowerMicros + ((upperMicros - lowerMicros) * unitSample);
    final boundedMicros = sampledMicros.round().clamp(0, maximumMicros);

    return Duration(microseconds: boundedMicros);
  }
}

// GAPS:
