import 'dart:math';

import 'package:call_core/call_core.dart';
import 'package:test/test.dart';

void main() {
  group('ReconnectContext construction', () {
    test('rejects attempt < 1', () {
      expect(
        () => ReconnectContext(attempt: 0, elapsed: Duration.zero, cause: 'x'),
        throwsArgumentError,
      );
    });

    test('rejects negative elapsed', () {
      expect(
        () => ReconnectContext(
          attempt: 1,
          elapsed: const Duration(seconds: -1),
          cause: 'x',
        ),
        throwsArgumentError,
      );
    });
  });

  group('ReconnectDecision', () {
    test('retry rejects a negative delay', () {
      expect(
        () => ReconnectDecision.retry(const Duration(milliseconds: -1)),
        throwsArgumentError,
      );
    });

    test('giveUp accepts a reason at the 256-char boundary', () {
      final reason = 'a' * 256;
      final decision = ReconnectDecision.giveUp(reason);
      expect(decision.shouldRetry, isFalse);
      expect(decision.reason, reason);
    });

    test('giveUp rejects a 257-char reason', () {
      final reason = 'a' * 257;
      expect(() => ReconnectDecision.giveUp(reason), throwsArgumentError);
    });

    test('giveUp rejects a reason containing a control character', () {
      expect(
        () => ReconnectDecision.giveUp('bad\nreason'),
        throwsArgumentError,
      );
    });

    test('giveUp with no reason is allowed', () {
      final decision = ReconnectDecision.giveUp();
      expect(decision.shouldRetry, isFalse);
      expect(decision.reason, isNull);
      expect(decision.delay, Duration.zero);
    });
  });

  group('ExponentialBackoffReconnectPolicy constructor validation', () {
    test('rejects maxDelay < baseDelay', () {
      expect(
        () => ExponentialBackoffReconnectPolicy(
          baseDelay: const Duration(milliseconds: 1000),
          maxDelay: const Duration(milliseconds: 500),
        ),
        throwsArgumentError,
      );
    });

    test('rejects maxAttempts < 1', () {
      expect(
        () => ExponentialBackoffReconnectPolicy(maxAttempts: 0),
        throwsArgumentError,
      );
    });

    test('rejects a negative baseDelay', () {
      expect(
        () => ExponentialBackoffReconnectPolicy(
          baseDelay: const Duration(milliseconds: -1),
        ),
        throwsArgumentError,
      );
    });

    test('rejects a non-positive maxElapsed', () {
      expect(
        () => ExponentialBackoffReconnectPolicy(maxElapsed: Duration.zero),
        throwsArgumentError,
      );
    });
  });

  group('ExponentialBackoffReconnectPolicy.evaluate give-up', () {
    final policy = ExponentialBackoffReconnectPolicy(random: Random(1));

    test('gives up when attempt exceeds maxAttempts (8)', () {
      final decision = policy.evaluate(
        ReconnectContext(attempt: 9, elapsed: Duration.zero, cause: 'x'),
      );
      expect(decision.shouldRetry, isFalse);
    });

    test('gives up when elapsed >= maxElapsed (2 min)', () {
      final decision = policy.evaluate(
        ReconnectContext(
          attempt: 1,
          elapsed: const Duration(minutes: 2),
          cause: 'x',
        ),
      );
      expect(decision.shouldRetry, isFalse);
    });

    test('gives up when elapsed exceeds maxElapsed', () {
      final decision = policy.evaluate(
        ReconnectContext(
          attempt: 1,
          elapsed: const Duration(minutes: 5),
          cause: 'x',
        ),
      );
      expect(decision.shouldRetry, isFalse);
    });

    test('still retries at exactly maxAttempts with elapsed under budget', () {
      final decision = policy.evaluate(
        ReconnectContext(
          attempt: 8,
          elapsed: const Duration(seconds: 1),
          cause: 'x',
        ),
      );
      expect(decision.shouldRetry, isTrue);
    });
  });

  group('ExponentialBackoffReconnectPolicy.evaluate retry delay bounds', () {
    // Full-jitter cap per attempt: baseDelay * 2^(attempt-1), clamped to
    // maxDelay. baseDelay=500ms, maxDelay=20s.
    const expectedCapMs = <int, int>{
      1: 500,
      2: 1000,
      3: 2000,
      4: 4000,
      5: 8000,
      6: 16000,
      7: 20000,
      8: 20000,
    };

    final policy = ExponentialBackoffReconnectPolicy(random: Random(42));

    for (final attempt in expectedCapMs.keys) {
      final capMs = expectedCapMs[attempt]!;

      test('attempt $attempt: 200 draws stay within [0, ${capMs}ms]', () {
        for (var draw = 0; draw < 200; draw++) {
          final decision = policy.evaluate(
            ReconnectContext(
              attempt: attempt,
              elapsed: Duration.zero,
              cause: 'x',
            ),
          );
          expect(decision.shouldRetry, isTrue);
          expect(decision.delay.inMilliseconds, greaterThanOrEqualTo(0));
          expect(decision.delay.inMilliseconds, lessThanOrEqualTo(capMs));
          expect(
            decision.delay.inMilliseconds,
            lessThanOrEqualTo(20000),
            reason: 'cap must never exceed maxDelay',
          );
        }
      });
    }
  });
}
