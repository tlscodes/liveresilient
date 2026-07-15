import 'dart:math';

import 'validation.dart';

final class ReconnectContext {
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

  final int attempt;
  final Duration elapsed;
  final Object cause;
}

final class ReconnectDecision {
  ReconnectDecision.retry(this.delay) : shouldRetry = true, reason = null {
    if (delay.isNegative) {
      throw ArgumentError.value(delay, 'delay');
    }
  }

  ReconnectDecision.giveUp([this.reason])
    : shouldRetry = false,
      delay = Duration.zero {
    final value = reason;
    if (value != null &&
        (value.length > 256 || containsControlCharacters(value))) {
      throw ArgumentError.value(value, 'reason');
    }
  }

  final bool shouldRetry;
  final Duration delay;
  final String? reason;
}

abstract interface class ReconnectPolicy {
  ReconnectDecision evaluate(ReconnectContext context);
}

final class ExponentialBackoffReconnectPolicy implements ReconnectPolicy {
  ExponentialBackoffReconnectPolicy({
    this.maxAttempts = 8,
    this.baseDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 20),
    this.maxElapsed = const Duration(minutes: 2),
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

  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;
  final Duration maxElapsed;
  final Random _random;

  @override
  ReconnectDecision evaluate(ReconnectContext context) {
    if (context.attempt > maxAttempts || context.elapsed >= maxElapsed) {
      return ReconnectDecision.giveUp('Reconnect budget exhausted');
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
