import 'package:bahonar_nut/core/snipe.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:test/test.dart';

void main() {
  group('state machine: legal transitions', () {
    test('the happy path runs idle -> ... -> claimed without throwing', () {
      final run = SnipeRun('r1');
      run.transitionTo(SnipeState.preflight);
      run.transitionTo(SnipeState.hunting);
      run.transitionTo(SnipeState.matched);
      run.transitionTo(SnipeState.claiming);
      run.transitionTo(SnipeState.claimed);
      expect(run.state, SnipeState.claimed);
      expect(run.isTerminal, isTrue);
    });

    test('preflight can abort (unsynced clock / dead session / no funds)', () {
      final run = SnipeRun('r1')..transitionTo(SnipeState.preflight);
      run.transitionTo(SnipeState.aborted);
      expect(run.state, SnipeState.aborted);
      expect(run.isTerminal, isTrue);
    });

    test('hunting can expire when the window closes', () {
      final run = SnipeRun('r1')
        ..transitionTo(SnipeState.preflight)
        ..transitionTo(SnipeState.hunting);
      run.transitionTo(SnipeState.windowExpired);
      expect(run.state, SnipeState.windowExpired);
    });

    test('a match can be lost before claiming', () {
      final run = SnipeRun('r1')
        ..transitionTo(SnipeState.preflight)
        ..transitionTo(SnipeState.hunting)
        ..transitionTo(SnipeState.matched);
      run.transitionTo(SnipeState.lost);
      expect(run.state, SnipeState.lost);
    });

    test('after losing, the run returns to hunting', () {
      final run = SnipeRun('r1')
        ..transitionTo(SnipeState.preflight)
        ..transitionTo(SnipeState.hunting)
        ..transitionTo(SnipeState.matched)
        ..transitionTo(SnipeState.lost);
      run.transitionTo(SnipeState.hunting);
      expect(run.state, SnipeState.hunting);
      expect(run.isTerminal, isFalse);
    });

    test('an ambiguous claim resolves to lost or back to hunting', () {
      // Reconcile says not ours -> lost.
      final lost = SnipeRun('r1')
        ..transitionTo(SnipeState.preflight)
        ..transitionTo(SnipeState.hunting)
        ..transitionTo(SnipeState.matched)
        ..transitionTo(SnipeState.claiming)
        ..transitionTo(SnipeState.lost);
      expect(lost.state, SnipeState.lost);

      // Reconcile says already ours -> claimed (via lost->hunting is not needed).
      final claimed = SnipeRun('r2')
        ..transitionTo(SnipeState.preflight)
        ..transitionTo(SnipeState.hunting)
        ..transitionTo(SnipeState.matched)
        ..transitionTo(SnipeState.claiming)
        ..transitionTo(SnipeState.claimed);
      expect(claimed.state, SnipeState.claimed);
    });
  });

  group('state machine: illegal transitions throw', () {
    test('cannot skip preflight', () {
      final run = SnipeRun('r1');
      expect(
        () => run.transitionTo(SnipeState.hunting),
        throwsA(isA<IllegalTransitionError>()),
      );
    });

    test('cannot jump straight from idle to claiming', () {
      final run = SnipeRun('r1');
      expect(
        () => run.transitionTo(SnipeState.claiming),
        throwsA(isA<IllegalTransitionError>()),
      );
    });

    test('cannot go from hunting straight to claimed', () {
      final run = SnipeRun('r1')
        ..transitionTo(SnipeState.preflight)
        ..transitionTo(SnipeState.hunting);
      expect(
        () => run.transitionTo(SnipeState.claimed),
        throwsA(isA<IllegalTransitionError>()),
      );
    });

    test('cannot leave a terminal state', () {
      final run = SnipeRun('r1')
        ..transitionTo(SnipeState.preflight)
        ..transitionTo(SnipeState.hunting);
      run.transitionTo(SnipeState.windowExpired);

      for (final target in SnipeState.values) {
        expect(
          () => run.transitionTo(target),
          throwsA(isA<IllegalTransitionError>()),
          reason: 'windowExpired must not transition to $target',
        );
      }
    });

    test('the failed transition does not mutate state', () {
      final run = SnipeRun('r1');
      try {
        run.transitionTo(SnipeState.claimed);
      } on IllegalTransitionError {
        // expected
      }
      expect(run.state, SnipeState.idle, reason: 'state must be unchanged');
    });

    test('the error message names both states', () {
      final error = IllegalTransitionError(SnipeState.idle, SnipeState.claimed);
      expect(error.toString(), contains('idle'));
      expect(error.toString(), contains('claimed'));
    });
  });

  group('state machine: table sanity', () {
    test('terminal states have no outgoing transitions', () {
      for (final state in SnipeStateMachine.terminal) {
        expect(SnipeStateMachine.allowed[state], isEmpty,
            reason: '$state must have no exits');
      }
    });

    test('every state appears as a key in the transition table', () {
      for (final state in SnipeState.values) {
        expect(SnipeStateMachine.allowed.containsKey(state), isTrue,
            reason: '$state missing from table');
      }
    });

    test('every transition target is a real state', () {
      for (final entry in SnipeStateMachine.allowed.entries) {
        for (final target in entry.value) {
          expect(SnipeState.values, contains(target));
        }
      }
    });

    test('every non-terminal state is reachable from idle', () {
      // Breadth-first over the transition graph.
      final reachable = <SnipeState>{SnipeState.idle};
      final queue = <SnipeState>[SnipeState.idle];
      while (queue.isNotEmpty) {
        final current = queue.removeLast();
        for (final next in SnipeStateMachine.allowed[current] ?? const {}) {
          if (reachable.add(next)) queue.add(next);
        }
      }
      for (final state in SnipeState.values) {
        expect(reachable, contains(state),
            reason: '$state is unreachable from idle');
      }
    });
  });

  group('SnipeRule window', () {
    SnipeRule ruleWith({ClockTime? start, ClockTime? end}) => SnipeRule(
          id: 'r',
          account: 'a',
          preferences: const {},
          windowStart: start ?? const ClockTime(11, 0),
          windowEnd: end ?? const ClockTime(14, 0),
        );

    test('is inside the window at the boundaries and between', () {
      final rule = ruleWith();
      expect(rule.isWithinWindow(const ClockTime(11, 0)), isTrue);
      expect(rule.isWithinWindow(const ClockTime(12, 30)), isTrue);
      expect(rule.isWithinWindow(const ClockTime(14, 0)), isTrue);
    });

    test('is outside the window before start and after end', () {
      final rule = ruleWith();
      expect(rule.isWithinWindow(const ClockTime(10, 59)), isFalse);
      expect(rule.isWithinWindow(const ClockTime(14, 1)), isFalse);
    });

    test('an inverted window is inert rather than spanning the whole day', () {
      // Guards against a user setting end <= start and getting 24h polling.
      final rule = ruleWith(start: const ClockTime(14, 0), end: const ClockTime(11, 0));
      for (final hour in [0, 6, 11, 14, 18, 23]) {
        expect(rule.isWithinWindow(ClockTime(hour, 0)), isFalse);
      }
    });
  });

  group('SnipeRule construction', () {
    test('explicit target without a date is rejected at construction', () {
      expect(
        () => SnipeRule(
          id: 'r',
          account: 'a',
          preferences: const {},
          target: DateTarget.explicit,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('explicit target with a date is accepted', () {
      final rule = SnipeRule(
        id: 'r',
        account: 'a',
        preferences: const {},
        target: DateTarget.explicit,
        explicitDate: DateTime.utc(2026, 10, 20),
      );
      expect(rule.explicitDate, DateTime.utc(2026, 10, 20));
    });

    test('zero maxPurchasesPerWindow is rejected', () {
      expect(
        () => SnipeRule(
          id: 'r',
          account: 'a',
          preferences: const {},
          maxPurchasesPerWindow: 0,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('dryRun defaults to false', () {
      final rule = SnipeRule(id: 'r', account: 'a', preferences: const {});
      expect(rule.dryRun, isFalse);
    });

    test('autoBuy is the default action, as the user requested', () {
      final rule = SnipeRule(id: 'r', account: 'a', preferences: const {});
      expect(rule.action, MatchAction.autoBuy);
    });
  });

  group('SnipeRule.resolveTargetDate', () {
    test('today resolves to the portal civil date', () {
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 10, 0));
      final rule = SnipeRule(
        id: 'r',
        account: 'a',
        preferences: const {},
        target: DateTarget.today,
      );
      expect(rule.resolveTargetDate(clock), DateTime.utc(2026, 10, 18));
    });

    test('firstAvailableAfterCutoff defers to the clock', () {
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 18, 0));
      final rule = SnipeRule(
        id: 'r',
        account: 'a',
        preferences: const {},
        target: DateTarget.firstAvailableAfterCutoff,
      );
      // Past 20:00 portal-local, so the window rolls to the 21st.
      expect(rule.resolveTargetDate(clock), DateTime.utc(2026, 10, 21));
    });

    test('explicit strips any time component', () {
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18));
      final rule = SnipeRule(
        id: 'r',
        account: 'a',
        preferences: const {},
        target: DateTarget.explicit,
        explicitDate: DateTime.utc(2026, 10, 25, 17, 45),
      );
      expect(rule.resolveTargetDate(clock), DateTime.utc(2026, 10, 25));
    });
  });

  group('SnipeRule.isOpenAt cross-day', () {
    final rule = SnipeRule(
      id: 'r',
      account: 'a',
      preferences: const {},
      windowStart: const ClockTime(18, 20),
      windowEnd: const ClockTime(14, 0),
      windowStartDate: DateTime.utc(2026, 11, 2),
      windowDate: DateTime.utc(2026, 11, 3),
    );

    test('is closed on start day before start time', () {
      expect(
        rule.isOpenAt(const ClockTime(18, 19), DateTime.utc(2026, 11, 2)),
        isFalse,
      );
    });

    test('is open on start day at and after start time', () {
      expect(
        rule.isOpenAt(const ClockTime(18, 20), DateTime.utc(2026, 11, 2)),
        isTrue,
      );
      expect(
        rule.isOpenAt(const ClockTime(23, 59), DateTime.utc(2026, 11, 2)),
        isTrue,
      );
    });

    test('is open on collection day before and at end time', () {
      expect(
        rule.isOpenAt(const ClockTime(0, 0), DateTime.utc(2026, 11, 3)),
        isTrue,
      );
      expect(
        rule.isOpenAt(const ClockTime(10, 0), DateTime.utc(2026, 11, 3)),
        isTrue,
      );
      expect(
        rule.isOpenAt(const ClockTime(14, 0), DateTime.utc(2026, 11, 3)),
        isTrue,
      );
    });

    test('is closed on collection day after end time', () {
      expect(
        rule.isOpenAt(const ClockTime(14, 1), DateTime.utc(2026, 11, 3)),
        isFalse,
      );
    });

    test('is closed on days outside the window', () {
      expect(
        rule.isOpenAt(const ClockTime(20, 0), DateTime.utc(2026, 11, 1)),
        isFalse,
      );
      expect(
        rule.isOpenAt(const ClockTime(10, 0), DateTime.utc(2026, 11, 4)),
        isFalse,
      );
    });
  });
}