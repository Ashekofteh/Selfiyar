/// The next-week nudge's schedule: when to check, and when to stop checking.
///
/// ## Why this is a pure function
///
/// The nudge is a **sequence of checks**, not a single alarm. The product
/// owner specified six: Wednesday noon, Wednesday afternoon, Wednesday night,
/// Thursday morning, Thursday noon, and Thursday afternoon/evening.
///
/// Taken at face value that fires even when the week is already booked, which
/// trains the user to ignore the notification. The resolution the spec settled
/// on: the six times are **check times**, and a check fires only if something
/// is still unbooked.
///
/// So the schedule itself is arithmetic — which weekday, which hour, is it
/// still ahead — and it belongs in the domain where it can be tested against
/// every boundary without a device.
library;

import '../shared/time.dart';

/// One check time in the nudge's window.
class NudgeCheck {
  const NudgeCheck(this.weekday, this.hour, this.minute);

  /// The day of the week, [DateTime.saturday] for Saturday.
  final int weekday;

  /// The hour, portal-local.
  final int hour;

  /// The minute, portal-local.
  final int minute;

  /// The wall-clock time of this check.
  ClockTime get time => ClockTime(hour, minute);

  @override
  String toString() => 'NudgeCheck(${_weekdayName(weekday)} $hour:$minute)';
}

/// The six checks, in order.
///
/// Parity: Must match NativeReminderSchedule.nudgeChecks in
/// android/app/src/main/kotlin/ir/ac/uk/bahonar_nut/NativeReminderSchedule.kt.
///
/// The portal's wall is 17:00 on Thursday. The last check is at 16:30 — half
/// an hour before the wall — so it still fires while the weekend's first meal
/// can be reserved, instead of landing on the wall and being useless.
const List<NudgeCheck> nudgeChecks = [
  NudgeCheck(DateTime.wednesday, 12, 0),
  NudgeCheck(DateTime.wednesday, 16, 0),
  NudgeCheck(DateTime.wednesday, 21, 0),
  NudgeCheck(DateTime.thursday, 9, 0),
  NudgeCheck(DateTime.thursday, 12, 0),
  NudgeCheck(DateTime.thursday, 16, 30),
];

/// The coming week's reservation window: Saturday through Friday.
///
/// [now] is the portal's local wall clock. The window is the same one the
/// native nudge check uses when it reads `meals.held` with the app closed, so
/// both paths agree about which meals count as "next week".
({DateTime start, DateTime end}) nextWeekWindow(DateTime now) {
  final today = DateTime.utc(now.year, now.month, now.day);
  final daysUntilSaturday = (DateTime.saturday - today.weekday + 7) % 7;
  final thisSaturday = DateTime.utc(
    today.year,
    today.month,
    today.day + daysUntilSaturday,
  );
  // The week beginning today has already started, so "next week" is the one
  // after it — the same rule as [nextWeekStart] in next_week.dart.
  final start = today.weekday == DateTime.saturday
      ? DateTime.utc(
          thisSaturday.year,
          thisSaturday.month,
          thisSaturday.day + 7,
        )
      : thisSaturday;
  return (
    start: start,
    end: DateTime.utc(start.year, start.month, start.day + 6),
  );
}

/// True when at least one of [mealDates] falls in the coming week's window.
///
/// This is the one rule the closed-app nudge applies: any meal already reserved
/// for next week makes the reminder unnecessary, because the student has
/// already acted on it.
bool hasAnyNextWeekMeal({
  required DateTime now,
  required Iterable<DateTime> mealDates,
}) {
  final window = nextWeekWindow(now);
  for (final date in mealDates) {
    final day = DateTime.utc(date.year, date.month, date.day);
    if (!day.isBefore(window.start) && !day.isAfter(window.end)) return true;
  }
  return false;
}

/// The next check at or after [now], and how many have been passed.
///
/// [now] is the portal's local wall-clock time. The result is the check to
/// arm; [passed] is how many of the six are already behind, which is what
/// makes the escalation work: the first check that finds a gap fires, and
/// each later one re-fires only if the gap persists.
///
/// Returns null when the window has passed — after the 16:30 check on Thursday
/// there is nothing left to arm, and the nudge must go quiet rather than nag
/// about a meal that can no longer be reserved.
({NudgeCheck check, int passed})? nextNudgeCheck(DateTime now) {
  final today = DateTime.utc(now.year, now.month, now.day);
  final nowMinutes = now.hour * 60 + now.minute;

  var passed = 0;

  for (final check in nudgeChecks) {
    // How many days from today to the check's weekday.
    //
    // The check's weekday is *this week's* occurrence, so the difference is
    // signed: a weekday earlier in the week than today is behind, not seven
    // days away. Getting this wrong is what made a check on Thursday evening
    // wrap around to "next Wednesday" and re-arm a window that was over.
    final dayDelta = check.weekday - today.weekday;

    if (dayDelta < 0) {
      // The weekday is already past this week.
      passed++;
      continue;
    }

    if (dayDelta == 0 && check.time.minutesSinceMidnight <= nowMinutes) {
      // Today's check has already gone by.
      passed++;
      continue;
    }

    // The check is ahead: later today, or a later day this week.
    return (check: check, passed: passed);
  }

  // Every check is behind. The window has passed.
  return null;
}

/// The instant the next check fires, given the portal's local [now].
///
/// The check is a wall-clock time in the portal's timezone, so the instant is
/// that time minus the portal's offset — the same arithmetic the reservation
/// cutoff uses.
///
/// [today] is the portal's civil today, passed in rather than read from the
/// clock: the clock's `portalTodayUtc` **throws** when the clock is not
/// synced, and an unsynced clock is the normal state on a cold start. Reading
/// it here would throw out of the arming path and take the slot alarms with
/// it.
DateTime? nextNudgeFireUtc({required DateTime now, required DateTime today}) {
  final next = nextNudgeCheck(now);
  if (next == null) return null;

  final civilToday = DateTime.utc(today.year, today.month, today.day);

  // The check's weekday is this week's occurrence, so the difference is
  // signed — the same reasoning as in [nextNudgeCheck].
  final daysAhead = next.check.weekday - civilToday.weekday;

  final day = DateTime.utc(
    civilToday.year,
    civilToday.month,
    civilToday.day + daysAhead,
  );

  return DateTime.utc(
    day.year,
    day.month,
    day.day,
    next.check.hour,
    next.check.minute,
  ).subtract(ServerClock.portalUtcOffset);
}

String _weekdayName(int weekday) => const [
  'دوشنبه',
  'سه شنبه',
  'چهارشنبه',
  'پنجشنبه',
  'جمعه',
  'شنبه',
  'یکشنبه',
][weekday - 1];
