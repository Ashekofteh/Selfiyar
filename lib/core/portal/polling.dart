/// Polling policy: how often to ask the portal for basket inventory.
///
/// The binding constraint on mobile is *radio wake-ups*, not CPU: every request
/// wakes the cellular or WiFi radio for seconds, so the optimisation target is
/// fewer round-trips rather than smaller payloads.
///
/// Three rules keep aggressive polling from becoming abuse:
///   1. Every interval is jittered, so many clients do not synchronise.
///   2. A hard floor that no configuration can go below.
///   3. A per-account request budget that ends the run when exhausted.
library;

import 'dart:math';

/// Why a poll attempt was skipped or a run stopped.
enum PollingStopReason {
  /// The rule's time window closed.
  windowExpired,

  /// A purchase succeeded; nothing more to do.
  purchaseComplete,

  /// Consecutive failures tripped the circuit breaker.
  circuitOpen,

  /// The per-account request budget ran out.
  budgetExhausted,

  /// Something the user must fix (auth, balance, unsynced clock).
  preconditionFailed,
}

/// Tunable polling behaviour for one rule.
class PollingPolicy {
  const PollingPolicy({
    this.baseInterval = const Duration(seconds: 45),
    this.jitterMin = 0.8,
    this.jitterMax = 1.2,
    this.failureThreshold = 5,
    this.requestBudget = 400,
    this.maxBackoff = const Duration(minutes: 5),
  })  : assert(jitterMin > 0 && jitterMin <= 1.0, 'jitterMin must be (0, 1]'),
        assert(jitterMax >= 1.0, 'jitterMax must be >= 1'),
        assert(jitterMin <= jitterMax, 'jitterMin must not exceed jitterMax'),
        assert(failureThreshold > 0, 'failureThreshold must be positive'),
        assert(requestBudget > 0, 'requestBudget must be positive');

  /// Nominal interval before jitter and backoff.
  final Duration baseInterval;

  /// Jitter multiplier bounds, applied as `base * [jitterMin, jitterMax]`.
  final double jitterMin;
  final double jitterMax;

  /// Consecutive failures before the circuit opens.
  final int failureThreshold;

  /// Requests allowed per account per rule window. Hard budget.
  final int requestBudget;

  /// Ceiling for exponential backoff.
  final Duration maxBackoff;

  /// Absolute floor. No policy, profile, or user setting may go below this.
  ///
  /// This is the single most important number in the file. The portal is shared
  /// infrastructure and the user's account is the thing at risk; the app refuses
  /// to be configured into behaviour that reads as an attack.
  static const Duration hardFloor = Duration(seconds: 20);

  /// Clamp any proposed interval to the floor.
  static Duration enforceFloor(Duration interval) =>
      interval < hardFloor ? hardFloor : interval;

  /// Jittered interval for a given consecutive-failure count.
  ///
  /// Deterministic in [random] so tests are reproducible.
  Duration nextInterval({
    required int consecutiveFailures,
    required Random random,
  }) {
    // Exponential backoff: base * 2^failures, capped. One failure doubles the
    // interval, two quadruples it, and so on. Backing off on the very first
    // failure is deliberate — when something is wrong, asking less often is the
    // protective choice for both the portal and the account.
    var interval = baseInterval;
    if (consecutiveFailures > 0) {
      final multiplier = 1 << consecutiveFailures;
      final backedOff = baseInterval * multiplier;
      interval = backedOff > maxBackoff ? maxBackoff : backedOff;
    }

    // Jitter: a fixed interval from many phones synchronises into a
    // self-inflicted denial of service against the portal and the battery.
    final span = jitterMax - jitterMin;
    final factor = jitterMin + random.nextDouble() * span;
    final jittered = Duration(
      microseconds: (interval.inMicroseconds * factor).round(),
    );

    return enforceFloor(jittered);
  }
}

/// Tracks how many requests a single account has spent in the current window.
class RequestBudget {
  RequestBudget(this.limit) : assert(limit > 0, 'limit must be positive');

  final int limit;
  int _spent = 0;

  int get spent => _spent;
  int get remaining => limit - _spent;
  bool get isExhausted => _spent >= limit;

  /// Records a request. Returns false once the budget is exhausted, so callers
  /// can stop rather than keep counting past the limit.
  bool spend() {
    if (isExhausted) return false;
    _spent++;
    return true;
  }
}

/// Trips after [threshold] consecutive failures and stays open until reset.
///
/// Prevents a failing portal — or a misconfigured rule hammering a dead endpoint
/// — from turning into an unbounded retry loop.
class CircuitBreaker {
  CircuitBreaker(this.threshold)
      : assert(threshold > 0, 'threshold must be positive');

  final int threshold;
  int _consecutiveFailures = 0;

  int get consecutiveFailures => _consecutiveFailures;
  bool get isOpen => _consecutiveFailures >= threshold;

  /// Records a success. Closes the breaker.
  void recordSuccess() => _consecutiveFailures = 0;

  /// Records a failure. Returns true if this failure opened the breaker.
  bool recordFailure() {
    _consecutiveFailures++;
    return isOpen;
  }

  void reset() => _consecutiveFailures = 0;
}