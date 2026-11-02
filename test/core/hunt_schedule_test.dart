/// When a hunt actually runs — the collection date, and the wake instant.
///
/// The defect these pin is F83: a hunt's window was a bare time of day, so a
/// hunt for tomorrow's dinner, started in the morning, found its window open
/// *today*, hunted today's market — which it could never buy from — burned its
/// request budget against it, and ended a day early.
///
/// The breakfast case is the sharpest: breakfast is collected with the
/// previous evening's dinner, so a hunt for Friday's breakfast has to be in
/// the market on *Thursday*.
library;

import 'package:bahonar_nut/core/hunt_config.dart';
import 'package:bahonar_nut/core/hunt_schedule.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/snipe.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:test/test.dart';

/// A civil date, in the portal's frame.
DateTime day(int year, int month, int dayOfMonth) =>
    DateTime.utc(year, month, dayOfMonth);

void main() {
  group('the collection date', () {
    test('a lunch is collected on its own date', () {
      expect(
        HuntSchedules.collectionDate(
          targetDate: day(2026, 10, 22),
          slot: MealSlot.lunch,
        ),
        day(2026, 10, 22),
      );
    });

    test('a dinner is collected on its own date', () {
      expect(
        HuntSchedules.collectionDate(
          targetDate: day(2026, 10, 22),
          slot: MealSlot.dinner,
        ),
        day(2026, 10, 22),
      );
    });

    test('a breakfast is collected the evening before', () {
      // 2026-10-22 is a Thursday; a breakfast for Thursday is collected with
      // Wednesday's dinner, so the collection day is the Wednesday.
      expect(
        HuntSchedules.collectionDate(
          targetDate: day(2026, 10, 22),
          slot: MealSlot.breakfast,
        ),
        day(2026, 10, 21),
      );
    });

    test('a breakfast whose collection evening has no dinner does not exist',
        () {
      // 2026-10-23 is a Friday. Its collection evening is Thursday, which
      // serves no dinner — so Friday has no breakfast to collect.
      expect(
        HuntSchedules.collectionDate(
          targetDate: day(2026, 10, 23),
          slot: MealSlot.breakfast,
        ),
        isNull,
      );
    });

    test('a breakfast collected on a Saturday evening exists', () {
      // 2026-10-25 is a Sunday, collected with Saturday's dinner, and
      // Saturday does serve dinner.
      expect(
        HuntSchedules.collectionDate(
          targetDate: day(2026, 10, 25),
          slot: MealSlot.breakfast,
        ),
        day(2026, 10, 24),
      );
    });

    test('a target with no date has no collection date', () {
      expect(
        HuntSchedules.collectionDate(targetDate: null, slot: MealSlot.dinner),
        isNull,
      );
    });
  });

  group('the wake instant', () {
    test('a dinner for tomorrow wakes tomorrow, not today', () {
      // A dinner for 2026-10-24, which is a **Saturday** — a day the halls do
      // serve dinner. (The 22nd is a Thursday, and Thursday has no dinner; a
      // hunt aimed at one is refused as mealNotServed, which is a different
      // test below.)
      //
      // Now is 2026-10-23 at 09:00 portal-local.
      final now = DateTime.utc(2026, 10, 23, 5, 30);

      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 10, 24),
        slot: MealSlot.dinner,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        nowUtc: now,
      );

      expect(result.isScheduled, isTrue);
      final schedule = result.schedule!;
      expect(schedule.collectionDate, day(2026, 10, 24));

      // 16:30 portal-local == 13:00 UTC (the portal is UTC+3:30).
      expect(schedule.wakeAtUtc, DateTime.utc(2026, 10, 24, 13, 0));
      expect(schedule.windowEndUtc, DateTime.utc(2026, 10, 24, 17, 0));
    });

    test('a dinner on a Thursday is not scheduled at all', () {
      // Thursday serves no dinner (see [ServiceCalendar]), so there is no
      // listing the portal will ever publish for it. Before this check the
      // hunt was armed anyway, fired, and was refused hours later with nobody
      // looking — the device showed exactly that: a Thursday-dinner hunt
      // armed at 18:11 and fired at once.
      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 10, 22),
        slot: MealSlot.dinner,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        nowUtc: DateTime.utc(2026, 10, 21, 5, 30),
      );

      expect(result.status, HuntScheduleStatus.mealNotServed);
      expect(result.schedule, isNull);
    });

    test('anything on a Friday is not scheduled at all', () {
      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 10, 23),
        slot: MealSlot.lunch,
        windowStart: const ClockTime(9, 0),
        windowEnd: const ClockTime(15, 30),
        nowUtc: DateTime.utc(2026, 10, 21, 5, 30),
      );

      expect(result.status, HuntScheduleStatus.mealNotServed);
    });

    test('a window that is open right now is reported as open, not scheduled',
        () {
      // The device's case: enabling at 18:11 a hunt whose window opened at
      // 16:30 the same day. The window is open, so the hunt starts at once —
      // but reporting it as `scheduled` with a start time of 16:30 is a claim
      // the screen then printed and the student could check and find false.
      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 10, 24),
        slot: MealSlot.dinner,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        // 15:00Z is 18:30 portal-local — inside the 16:30..20:30 window.
        nowUtc: DateTime.utc(2026, 10, 24, 15),
      );

      expect(result.status, HuntScheduleStatus.windowOpen);
      expect(result.isScheduled, isFalse,
          reason: 'a start time already past is not a future schedule');
      expect(result.isOpenNow, isTrue);
      // The schedule still rides along, because the first arm needs the
      // instant to fire at once — see HuntScheduleService.arm.
      expect(result.schedule!.wakeAtUtc, DateTime.utc(2026, 10, 24, 13, 0));
    });

    test('a breakfast for tomorrow wakes tonight', () {
      // The breakfast of 2026-10-22 is collected with the dinner of
      // 2026-10-21, so the window opens on the 21st — the same evening the
      // student set the hunt up.
      final now = DateTime.utc(2026, 10, 21, 5, 30);

      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 10, 22),
        slot: MealSlot.breakfast,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        nowUtc: now,
      );

      expect(result.isScheduled, isTrue);
      expect(result.schedule!.collectionDate, day(2026, 10, 21));
      expect(result.schedule!.wakeAtUtc, DateTime.utc(2026, 10, 21, 13, 0));
    });

    test('a window on a later day is not treated as having passed', () {
      // A dinner for Saturday the 24th, set up at 21:00 on the 23rd: the
      // 24th's window has not closed — it has not even opened.
      final now = DateTime.utc(2026, 10, 23, 17, 30);

      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 10, 24),
        slot: MealSlot.dinner,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        nowUtc: now,
      );

      expect(result.isScheduled, isTrue);
      expect(result.schedule!.wakeAtUtc, DateTime.utc(2026, 10, 24, 13, 0));
    });

    test('a window that has already closed is not scheduled', () {
      // A dinner for today (the 21st), configured at 21:00 portal-local —
      // after the 20:30 window closed. The meal it is for is released in that
      // window, so there is nothing left to hunt for.
      final now = DateTime.utc(2026, 10, 21, 17, 30);

      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 10, 21),
        slot: MealSlot.dinner,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        nowUtc: now,
      );

      expect(result.status, HuntScheduleStatus.windowPassed);
      expect(result.isScheduled, isFalse);
    });

    test('a window that never opens is not scheduled', () {
      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 10, 22),
        slot: MealSlot.dinner,
        windowStart: const ClockTime(20, 30),
        windowEnd: const ClockTime(16, 30),
        nowUtc: DateTime.utc(2026, 10, 21, 5, 30),
      );

      expect(result.status, HuntScheduleStatus.windowInvalid);
    });

    test('a breakfast that does not exist is not scheduled', () {
      // A Friday breakfast is collected with Thursday's dinner, and Thursday
      // serves no dinner — so there is no such breakfast to hunt for.
      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 10, 23),
        slot: MealSlot.breakfast,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        nowUtc: DateTime.utc(2026, 10, 21, 5, 30),
      );

      expect(result.status, HuntScheduleStatus.mealNotServed);
    });

    test('a hunt with no target date is not scheduled', () {
      final result = HuntSchedules.scheduleFor(
        targetDate: null,
        slot: MealSlot.dinner,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        nowUtc: DateTime.utc(2026, 10, 21, 5, 30),
      );

      expect(result.status, HuntScheduleStatus.noTargetDate);
    });
  });

  group('the rule carries the collection date', () {
    SnipeRule ruleFor(MealSlot slot, DateTime? target) => HuntConfig(
          targetSlot: slot,
          targetDate: target,
        ).toRule(id: 'r1', account: 'a1');

    test('a dinner rule opens on its own date', () {
      final rule = ruleFor(MealSlot.dinner, day(2026, 10, 22));
      expect(rule.windowDate, day(2026, 10, 22));
    });

    test('a breakfast rule opens the evening before', () {
      final rule = ruleFor(MealSlot.breakfast, day(2026, 10, 22));
      expect(rule.windowDate, day(2026, 10, 21));
    });

    test('a breakfast that does not exist carries no window date', () {
      final rule = ruleFor(MealSlot.breakfast, day(2026, 10, 23));
      expect(rule.windowDate, isNull);
    });
  });

  group('the window is checked against the date as well as the time', () {
    final rule = SnipeRule(
      id: 'r1',
      account: 'a1',
      preferences: const {},
      windowStart: const ClockTime(16, 30),
      windowEnd: const ClockTime(20, 30),
      windowDate: day(2026, 10, 22),
    );

    test('the window is closed on another day, even at the right time', () {
      expect(
        rule.isOpenAt(const ClockTime(17, 0), day(2026, 10, 21)),
        isFalse,
        reason: 'a hunt for the 22nd must not open the 21st\'s window',
      );
    });

    test('the window is open on its own day', () {
      expect(rule.isOpenAt(const ClockTime(17, 0), day(2026, 10, 22)), isTrue);
    });

    test('the time of day is still enforced on its own day', () {
      expect(rule.isOpenAt(const ClockTime(9, 0), day(2026, 10, 22)), isFalse);
    });

    test('a rule with no date keeps the time-of-day behaviour', () {
      final plain = SnipeRule(
        id: 'r2',
        account: 'a1',
        preferences: const {},
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
      );

      expect(plain.isOpenAt(const ClockTime(17, 0), day(2026, 10, 21)), isTrue);
    });

    test('an unknown date falls back to the time of day', () {
      expect(rule.isOpenAt(const ClockTime(17, 0), null), isTrue,
          reason: 'a date nobody can name is not a reason to refuse the window');
    });
  });

  group('the re-arm', () {
    // The defect this pins: the headless hunt re-armed its alarm with the
    // **same** target date, so the next alarm landed on a window that had
    // already opened — and fired at once. The hunt refused, re-armed, fired
    // again, refused again: a tight loop of wake-ups, each one a round of
    // portal requests, for as long as the window stayed open.
    //
    // The first arm is the student's own action, so an open window fires at
    // once there — that is what they meant. The re-arm is automatic, and it
    // must not.

    test('a window that has not opened yet is armed', () {
      final result = HuntSchedules.rearmFor(
        targetDate: day(2026, 10, 24),
        slot: MealSlot.dinner,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        // 2026-10-23, before the 24th's window.
        nowUtc: day(2026, 10, 23),
      );

      expect(result.status, HuntScheduleStatus.scheduled);
      expect(result.schedule, isNotNull);
    });

    test('a window that has already opened is not armed again', () {
      final result = HuntSchedules.rearmFor(
        targetDate: day(2026, 10, 24),
        slot: MealSlot.dinner,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        // 15:00Z is 18:30 portal — inside the 16:30..20:30 window, so it is
        // open. (The window's start is 13:00Z, its end 17:00Z.)
        nowUtc: DateTime.utc(2026, 10, 24, 15),
      );

      expect(result.status, HuntScheduleStatus.windowOpen);
      expect(result.isOpenNow, isTrue);
      // `isScheduled` is the flag a caller arms on, and it is false for an open
      // window: arming into one would fire at once, and the hunt would restart
      // the moment it ended. The schedule itself is still present (the first
      // arm needs the instant), so the *status* is what refuses the re-arm —
      // see HuntScheduleService.rearm, which arms only `isScheduled`.
      expect(result.isScheduled, isFalse,
          reason: 'an alarm into an open window would fire at once, and the '
              'hunt would restart the moment it ended');
    });

    test('a window that has closed is not armed either', () {
      final result = HuntSchedules.rearmFor(
        targetDate: day(2026, 10, 24),
        slot: MealSlot.dinner,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        nowUtc: day(2026, 10, 25),
      );

      expect(result.status, HuntScheduleStatus.windowPassed);
      expect(result.schedule, isNull);
    });

    test('a breakfast is re-armed for the evening before', () {
      // The collection date is the evening before, so the re-arm must be
      // judged against that date, not the target's.
      //
      // The target is 2026-10-27 (a Tuesday), so its breakfast is collected
      // with Monday the 26th's dinner — which is served.
      final result = HuntSchedules.rearmFor(
        targetDate: day(2026, 10, 27),
        slot: MealSlot.breakfast,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        // Still before the collection evening (the 26th).
        nowUtc: day(2026, 10, 24),
      );

      expect(result.status, HuntScheduleStatus.scheduled);
      expect(result.schedule!.collectionDate, day(2026, 10, 26));
    });

    test('portal date is computed in portal frame across UTC midnight', () {
      // In Tehran, 2026-10-25 01:00 AM (UTC+3:30) is 2026-10-24 21:30 UTC.
      // So portal today is 2026-10-25.
      // A collection date for 2026-10-24 is before portal today, so it has passed.
      final nowUtc = DateTime.utc(2026, 10, 24, 21, 30);

      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 10, 24),
        slot: MealSlot.dinner,
        windowStart: const ClockTime(16, 30),
        windowEnd: const ClockTime(20, 30),
        nowUtc: nowUtc,
      );

      expect(result.status, HuntScheduleStatus.windowPassed);
    });
  });

  group('cross-day and overnight hunt schedule', () {
    test('tomorrow lunch started today at 18:20 ending tomorrow at 14:00 is open right now', () {
      // User scenario from screenshot:
      // Today is 2026-11-02 (Monday).
      // Target meal is tomorrow 2026-11-03 (Tuesday) lunch.
      // Start time: 18:20 (14:50 UTC).
      // End time: 14:00 tomorrow (10:30 UTC).
      // Operation start date: 2026-11-02 (today).
      final nowUtc = DateTime.utc(2026, 11, 2, 14, 50); // 18:20 portal time

      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 11, 3),
        startDate: day(2026, 11, 2),
        slot: MealSlot.lunch,
        windowStart: const ClockTime(18, 20),
        windowEnd: const ClockTime(14, 0),
        nowUtc: nowUtc,
      );

      expect(result.status, HuntScheduleStatus.windowOpen);
      expect(result.isOpenNow, isTrue);
      expect(result.isScheduled, isFalse);
      expect(result.schedule, isNotNull);
      expect(result.schedule!.startDate, day(2026, 11, 2));
      expect(result.schedule!.collectionDate, day(2026, 11, 3));
      expect(result.schedule!.wakeAtUtc, DateTime.utc(2026, 11, 2, 14, 50));
      expect(result.schedule!.windowEndUtc, DateTime.utc(2026, 11, 3, 10, 30));
    });

    test('tomorrow lunch started today at 18:20 scheduled before wake instant', () {
      // 10:00 portal time today (06:30 UTC), before 18:20 start
      final nowUtc = DateTime.utc(2026, 11, 2, 6, 30);

      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 11, 3),
        startDate: day(2026, 11, 2),
        slot: MealSlot.lunch,
        windowStart: const ClockTime(18, 20),
        windowEnd: const ClockTime(14, 0),
        nowUtc: nowUtc,
      );

      expect(result.status, HuntScheduleStatus.scheduled);
      expect(result.isScheduled, isTrue);
      expect(result.schedule!.startDate, day(2026, 11, 2));
      expect(result.schedule!.collectionDate, day(2026, 11, 3));
      expect(result.schedule!.wakeAtUtc, DateTime.utc(2026, 11, 2, 14, 50));
      expect(result.schedule!.windowEndUtc, DateTime.utc(2026, 11, 3, 10, 30));
    });

    test('cross-day hunt after window ends tomorrow is windowPassed', () {
      // 15:00 portal time tomorrow (11:30 UTC), after 14:00 end
      final nowUtc = DateTime.utc(2026, 11, 3, 11, 30);

      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 11, 3),
        startDate: day(2026, 11, 2),
        slot: MealSlot.lunch,
        windowStart: const ClockTime(18, 20),
        windowEnd: const ClockTime(14, 0),
        nowUtc: nowUtc,
      );

      expect(result.status, HuntScheduleStatus.windowPassed);
    });

    test('starting on the same day with windowEnd <= windowStart is windowInvalid', () {
      // If startDate is set to the collection date itself (tomorrow),
      // 18:20 to 14:00 on the same day is invalid.
      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 11, 3),
        startDate: day(2026, 11, 3),
        slot: MealSlot.lunch,
        windowStart: const ClockTime(18, 20),
        windowEnd: const ClockTime(14, 0),
        nowUtc: DateTime.utc(2026, 11, 2, 14, 50),
      );

      expect(result.status, HuntScheduleStatus.windowInvalid);
    });

    test('startDate after collectionDate is windowInvalid', () {
      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 11, 3),
        startDate: day(2026, 11, 4),
        slot: MealSlot.lunch,
        windowStart: const ClockTime(10, 0),
        windowEnd: const ClockTime(14, 0),
        nowUtc: DateTime.utc(2026, 11, 2, 14, 50),
      );

      expect(result.status, HuntScheduleStatus.windowInvalid);
    });

    test('rearm with open cross-day window refuses immediate arming', () {
      final result = HuntSchedules.rearmFor(
        targetDate: day(2026, 11, 3),
        startDate: day(2026, 11, 2),
        slot: MealSlot.lunch,
        windowStart: const ClockTime(18, 20),
        windowEnd: const ClockTime(14, 0),
        nowUtc: DateTime.utc(2026, 11, 2, 14, 50),
      );

      expect(result.status, HuntScheduleStatus.windowOpen);
      expect(result.isScheduled, isFalse);
    });

    test('tomorrow lunch with 18:20 to 14:00 and startDate null is windowInvalid on bare scheduleFor', () {
      final nowUtc = DateTime.utc(2026, 11, 2, 14, 50);

      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 11, 3),
        startDate: null,
        slot: MealSlot.lunch,
        windowStart: const ClockTime(18, 20),
        windowEnd: const ClockTime(14, 0),
        nowUtc: nowUtc,
      );

      expect(result.status, HuntScheduleStatus.windowInvalid);
    });

    test('today lunch with 18:20 to 14:00 and startDate null is windowInvalid on same day', () {
      final nowUtc = DateTime.utc(2026, 11, 2, 14, 50);

      final result = HuntSchedules.scheduleFor(
        targetDate: day(2026, 11, 2),
        startDate: null,
        slot: MealSlot.lunch,
        windowStart: const ClockTime(18, 20),
        windowEnd: const ClockTime(14, 0),
        nowUtc: nowUtc,
      );

      expect(result.status, HuntScheduleStatus.windowInvalid);
    });
  });
}
