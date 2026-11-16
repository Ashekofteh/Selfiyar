import 'dart:math';

import 'package:bahonar_nut/core/portal/polling.dart';
import 'package:test/test.dart';

void main() {
  group('hard floor is never breached', () {
    test('enforceFloor lifts anything below the floor', () {
      expect(
        PollingPolicy.enforceFloor(const Duration(seconds: 1)),
        PollingPolicy.hardFloor,
      );
      expect(
        PollingPolicy.enforceFloor(const Duration(seconds: 19)),
        PollingPolicy.hardFloor,
      );
    });

    test('enforceFloor leaves intervals above the floor untouched', () {
      const above = Duration(seconds: 45);
      expect(PollingPolicy.enforceFloor(above), above);
    });

    test('enforceFloor returns exactly the floor at the boundary', () {
      expect(PollingPolicy.enforceFloor(PollingPolicy.hardFloor),
          PollingPolicy.hardFloor);
    });

    test('no policy configuration can produce an interval under the floor', () {
      // An absurdly small base with jitter at its legal minimum (1.0). Note
      // jitterMax cannot go below 1.0 by construction, so this is the most
      // aggressive legal policy that exists.
      const aggressive = PollingPolicy(
        baseInterval: Duration(milliseconds: 10),
        jitterMin: 1.0,
        jitterMax: 1.0,
        requestBudget: 10000,
      );
      final random = Random(1);
      for (var failures = 0; failures < 20; failures++) {
        for (var i = 0; i < 200; i++) {
          final interval =
              aggressive.nextInterval(consecutiveFailures: failures, random: random);
          expect(
            interval >= PollingPolicy.hardFloor,
            isTrue,
            reason: 'failures=$failures produced $interval',
          );
        }
      }
    });
  });

  group('jitter', () {
    test('stays within the configured multiplier range', () {
      const policy = PollingPolicy(
        baseInterval: Duration(seconds: 100),
        jitterMin: 0.8,
        jitterMax: 1.2,
      );
      final random = Random(42);
      // Bounds are in milliseconds: a 100-second base jittered by 0.8–1.2
      // yields 80_000–120_000 ms.
      const minExpectedMs = 80 * 1000;
      const maxExpectedMs = 120 * 1000;

      for (var i = 0; i < 500; i++) {
        final ms =
            policy.nextInterval(consecutiveFailures: 0, random: random).inMilliseconds;
        expect(ms, greaterThanOrEqualTo(minExpectedMs));
        expect(ms, lessThanOrEqualTo(maxExpectedMs));
      }
    });

    test('actually varies across calls (does not collapse to a constant)', () {
      const policy = PollingPolicy(baseInterval: Duration(seconds: 100));
      final random = Random(7);
      final seen = <int>{};
      for (var i = 0; i < 100; i++) {
        seen.add(policy.nextInterval(consecutiveFailures: 0, random: random)
            .inMilliseconds);
      }
      // A fixed interval would give exactly one value; jitter must spread.
      expect(seen.length, greaterThan(10));
    });

    test('is reproducible given a seeded Random', () {
      const policy = PollingPolicy(baseInterval: Duration(seconds: 100));
      final a = policy.nextInterval(consecutiveFailures: 0, random: Random(99));
      final b = policy.nextInterval(consecutiveFailures: 0, random: Random(99));
      expect(a, b);
    });
  });

  group('exponential backoff', () {
    test('interval grows with consecutive failures', () {
      const policy = PollingPolicy(
        baseInterval: Duration(seconds: 60),
        jitterMin: 1.0,
        jitterMax: 1.0, // disable jitter so growth is exact
        maxBackoff: Duration(minutes: 10),
      );
      final random = Random(1);
      final f0 = policy.nextInterval(consecutiveFailures: 0, random: random);
      final f1 = policy.nextInterval(consecutiveFailures: 1, random: random);
      final f2 = policy.nextInterval(consecutiveFailures: 2, random: random);
      final f3 = policy.nextInterval(consecutiveFailures: 3, random: random);

      // No failures: base. Then 2x, 4x, 8x.
      expect(f0, const Duration(seconds: 60));
      expect(f1, const Duration(seconds: 120));
      expect(f2, const Duration(seconds: 240));
      expect(f3, const Duration(seconds: 480));
    });

    test('backoff is capped at maxBackoff', () {
      const policy = PollingPolicy(
        baseInterval: Duration(seconds: 60),
        jitterMin: 1.0,
        jitterMax: 1.0,
        maxBackoff: Duration(minutes: 5),
      );
      final random = Random(1);
      // 60 * 2^9 far exceeds the cap.
      expect(
        policy.nextInterval(consecutiveFailures: 10, random: random),
        const Duration(minutes: 5),
      );
    });
  });

  group('RequestBudget', () {
    test('counts spends up to the limit', () {
      final budget = RequestBudget(3);
      expect(budget.spend(), isTrue);
      expect(budget.spend(), isTrue);
      expect(budget.spend(), isTrue);
      expect(budget.remaining, 0);
      expect(budget.isExhausted, isTrue);
    });

    test('refuses spends past the limit and does not overcount', () {
      final budget = RequestBudget(2);
      budget.spend();
      budget.spend();
      expect(budget.spend(), isFalse);
      expect(budget.spend(), isFalse);
      expect(budget.spent, 2, reason: 'must not count refused spends');
    });

    test('reports remaining accurately throughout', () {
      final budget = RequestBudget(5);
      expect(budget.remaining, 5);
      budget.spend();
      expect(budget.remaining, 4);
    });
  });

  group('CircuitBreaker', () {
    test('opens exactly at the threshold, not before', () {
      final breaker = CircuitBreaker(3);
      expect(breaker.recordFailure(), isFalse);
      expect(breaker.isOpen, isFalse);
      expect(breaker.recordFailure(), isFalse);
      expect(breaker.isOpen, isFalse);
      expect(breaker.recordFailure(), isTrue, reason: 'third failure opens it');
      expect(breaker.isOpen, isTrue);
    });

    test('a success fully resets the failure count', () {
      final breaker = CircuitBreaker(3);
      breaker.recordFailure();
      breaker.recordFailure();
      breaker.recordSuccess();
      expect(breaker.consecutiveFailures, 0);
      expect(breaker.isOpen, isFalse);
      // Two more failures must not open it, since the count was reset.
      breaker.recordFailure();
      expect(breaker.recordFailure(), isFalse);
      expect(breaker.isOpen, isFalse);
    });

    test('a success after opening closes the breaker', () {
      final breaker = CircuitBreaker(2);
      breaker.recordFailure();
      breaker.recordFailure();
      expect(breaker.isOpen, isTrue);
      breaker.recordSuccess();
      expect(breaker.isOpen, isFalse);
    });
  });

  group('PollingStopReason completeness', () {
    test('every stop reason exists and is distinct', () {
      final reasons = PollingStopReason.values.toSet();
      expect(reasons.length, PollingStopReason.values.length);
      expect(reasons, containsAll(<PollingStopReason>[
        PollingStopReason.windowExpired,
        PollingStopReason.purchaseComplete,
        PollingStopReason.circuitOpen,
        PollingStopReason.budgetExhausted,
        PollingStopReason.preconditionFailed,
      ]));
    });
  });
}