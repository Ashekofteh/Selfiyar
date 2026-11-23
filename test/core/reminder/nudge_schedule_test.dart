import 'package:bahonar_nut/core/reminder/nudge_schedule.dart';
import 'package:bahonar_nut/core/shared/time.dart';
import 'package:test/test.dart';

/// The nudge's schedule.
///
/// The nudge is six checks between Wednesday noon and Thursday afternoon, and
/// the deadline is Thursday 17:00. The arithmetic is the whole feature: which
/// check is next, and when the window closes.
void main() {
  // The nudge's first check day is Wednesday 2026-10-21.
  final friday = DateTime.utc(2026, 10, 23);

  group('the coming week window', () {
    test('from Monday it is the coming Saturday through Friday', () {
      final window = nextWeekWindow(DateTime.utc(2026, 10, 19, 9));
      expect(window.start, DateTime.utc(2026, 10, 24));
      expect(window.end, DateTime.utc(2026, 10, 30));
    });

    test('from Friday it is tomorrow through the following Friday', () {
      final window = nextWeekWindow(DateTime.utc(2026, 10, 23, 18));
      expect(window.start, DateTime.utc(2026, 10, 24));
      expect(window.end, DateTime.utc(2026, 10, 30));
    });

    test('on Saturday the week that begins today has started, so next week is used', () {
      final window = nextWeekWindow(DateTime.utc(2026, 10, 24));
      expect(window.start, DateTime.utc(2026, 10, 31));
      expect(window.end, DateTime.utc(2026, 11, 6));
    });

    test('a meal on either edge counts, and one outside does not', () {
      final now = DateTime.utc(2026, 10, 19, 9);

      expect(
        hasAnyNextWeekMeal(
          now: now,
          mealDates: [DateTime.utc(2026, 10, 24, 12)],
        ),
        isTrue,
      );
      expect(
        hasAnyNextWeekMeal(
          now: now,
          mealDates: [DateTime.utc(2026, 10, 30, 12)],
        ),
        isTrue,
      );
      expect(
        hasAnyNextWeekMeal(
          now: now,
          mealDates: [DateTime.utc(2026, 10, 23, 23)],
        ),
        isFalse,
      );
      expect(
        hasAnyNextWeekMeal(now: now, mealDates: [DateTime.utc(2026, 10, 31)]),
        isFalse,
      );
    });

    test('no meal in the window means the nudge may speak', () {
      expect(
        hasAnyNextWeekMeal(
          now: DateTime.utc(2026, 10, 19),
          mealDates: const [],
        ),
        isFalse,
      );
    });
  });

  group('the six checks', () {
    test('they are the ones the product owner asked for', () {
      expect(nudgeChecks, hasLength(6));
      expect(
        nudgeChecks.map((c) => '${c.weekday} ${c.hour}:${c.minute}').toList(),
        [
          '${DateTime.wednesday} 12:0',
          '${DateTime.wednesday} 16:0',
          '${DateTime.wednesday} 21:0',
          '${DateTime.thursday} 9:0',
          '${DateTime.thursday} 12:0',
          '${DateTime.thursday} 16:30',
        ],
      );
    });

    test('the last one fires half an hour before the 17:00 wall', () {
      // The deadline is 17:00 on Thursday. A check on the wall itself would
      // race it: a few seconds late and the weekend's first meal has already
      // locked. 16:30 leaves enough room for one final actionable nudge.
      final last = nudgeChecks.last;
      expect(last.weekday, DateTime.thursday);
      expect(last.hour, 16);
      expect(last.minute, 30);
      expect(
        last.time.minutesSinceMidnight,
        ClockTime.cutoff.minutesSinceMidnight - 30,
      );
    });
  });

  group('the next check', () {
    test('before the window, the first check is ahead', () {
      final next = nextNudgeCheck(DateTime.utc(2026, 10, 21, 9));
      expect(next, isNotNull);
      expect(next!.check, nudgeChecks.first);
      expect(next.passed, 0);
    });

    test('after a check, the next one is ahead', () {
      final next = nextNudgeCheck(DateTime.utc(2026, 10, 21, 12, 30));
      expect(next!.check, nudgeChecks[1]);
      expect(next.passed, 1);
    });

    test('exactly on a check time, the next one is ahead', () {
      // A check at exactly 12:00 has not "passed" — the fire is at that
      // instant, so the one after it is the next to arm.
      final next = nextNudgeCheck(DateTime.utc(2026, 10, 21, 12));
      expect(next!.check, nudgeChecks[1]);
      expect(next.passed, 1);
    });

    test('a minute before a check, that check is still ahead', () {
      final next = nextNudgeCheck(DateTime.utc(2026, 10, 21, 11, 59));
      expect(next!.check, nudgeChecks.first);
      expect(next.passed, 0);
    });

    test('Wednesday night advances to Thursday morning', () {
      final next = nextNudgeCheck(DateTime.utc(2026, 10, 21, 22));
      expect(next!.check, nudgeChecks[3]);
      expect(next.passed, 3);
    });

    test('after the last check, the window is over', () {
      // Nothing left to check: the wall is half an hour away, and nagging
      // about a meal that can no longer be reserved is worse than silence.
      expect(nextNudgeCheck(DateTime.utc(2026, 10, 22, 16, 31)), isNull);
      expect(nextNudgeCheck(DateTime.utc(2026, 10, 22, 17, 1)), isNull);
      expect(nextNudgeCheck(DateTime.utc(2026, 10, 22, 18)), isNull);
      expect(nextNudgeCheck(DateTime.utc(2026, 10, 22, 23)), isNull);
    });

    test('at 16:00 the 16:30 check is still armed', () {
      final next = nextNudgeCheck(DateTime.utc(2026, 10, 22, 16, 0));
      expect(next!.check, nudgeChecks.last);
      expect(next.passed, nudgeChecks.length - 1);
    });

    test('on a Friday, the window is over for this week', () {
      expect(nextNudgeCheck(friday), isNull);
    });

    test('before Wednesday, the first check is still this coming week', () {
      final next = nextNudgeCheck(DateTime.utc(2026, 10, 20, 22));
      expect(next!.check, nudgeChecks.first);
      expect(next.passed, 0);
    });
  });

  group('the fire time', () {
    // 09:00 portal-local on Wednesday, before the first check. That is
    // 05:30 UTC, because the portal is UTC+3:30.
    final clock = FixedServerClock.now(DateTime.utc(2026, 10, 21, 5, 30));

    test('the first check fires at noon portal-local', () {
      // 12:00 portal-local is 08:30 UTC, because the portal is UTC+3:30.
      final fireAt = nextNudgeFireUtc(
        now: clock.portalNow,
        today: clock.portalTodayUtc,
      );
      expect(fireAt, DateTime.utc(2026, 10, 21, 8, 30));
    });

    test('a later check fires on Thursday', () {
      // 22:00 UTC on Wednesday is 01:30 Thursday portal-local, which is past
      // every Wednesday check.
      final wednesdayNight = FixedServerClock.now(
        DateTime.utc(2026, 10, 21, 22),
      );
      final fireAt = nextNudgeFireUtc(
        now: wednesdayNight.portalNow,
        today: wednesdayNight.portalTodayUtc,
      );
      // 09:00 Thursday portal-local is 05:30 UTC.
      expect(fireAt, DateTime.utc(2026, 10, 22, 5, 30));
    });

    test('after the window, nothing is armed', () {
      final thursdayEvening = FixedServerClock.now(
        DateTime.utc(2026, 10, 22, 18),
      );
      expect(
        nextNudgeFireUtc(
          now: thursdayEvening.portalNow,
          today: thursdayEvening.portalTodayUtc,
        ),
        isNull,
      );
    });

    test('the fire time is in the future, never in the past', () {
      // A check that would be in the past is the bug that fires a reminder
      // immediately and repeatedly.
      for (var day = 19; day <= 26; day++) {
        for (var hour = 0; hour < 24; hour++) {
          final c = FixedServerClock.now(DateTime.utc(2026, 10, day, hour));
          final fireAt = nextNudgeFireUtc(
            now: c.portalNow,
            today: c.portalTodayUtc,
          );
          if (fireAt == null) continue;
          expect(
            fireAt.isAfter(c.nowUtc),
            isTrue,
            reason: 'the fire time must be in the future: $day $hour',
          );
        }
      }
    });

    test('it does not need a synced clock', () {
      // The clock throws when it is not synced, and a cold start has no server
      // time yet. Reading the clock's own "today" here would throw out of the
      // arming path — and take the slot alarms with it, because they are armed
      // in the same pass.
      final unsynced = SyncedServerClock();
      expect(unsynced.isSynced, isFalse);

      // Early on Wednesday morning, before the first check.
      final fireAt = nextNudgeFireUtc(
        now: DateTime.utc(2026, 10, 21, 5),
        today: DateTime.utc(2026, 10, 21),
      );
      expect(fireAt, isNotNull);
      // 12:00 portal-local is 08:30 UTC.
      expect(fireAt, DateTime.utc(2026, 10, 21, 8, 30));
      expect(fireAt!.isAfter(DateTime.utc(2026, 10, 21, 5)), isTrue);
    });
  });
}
