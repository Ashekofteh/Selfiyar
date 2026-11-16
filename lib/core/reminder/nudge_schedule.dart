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
  String toString() =>
      'NudgeCheck(${_weekdayName(weekday)} $hour:$minute)';
}

/// The six checks, in order.
///
/// The last one is at 17:00 on Thursday, three hours before the 20:00 wall —
/// the last moment a student can still act on the weekend's first meal.
const List<NudgeCheck> nudgeChecks = [
  NudgeCheck(DateTime.wednesday, 12, 0),
  NudgeCheck(DateTime.wednesday, 16, 0),
  NudgeCheck(DateTime.wednesday, 21, 0),
  NudgeCheck(DateTime.thursday, 9, 0),
  NudgeCheck(DateTime.thursday, 12, 0),
  NudgeCheck(DateTime.thursday, 17, 0),
];

/// The next check at or after [now], and how many have been passed.
///
/// [now] is the portal's local wall-clock time. The result is the check to
/// arm; [passed] is how many of the six are already behind, which is what
/// makes the escalation work: the first check that finds a gap fires, and
/// each later one re-fires only if the gap persists.
///
/// Returns null when the window has passed — after Thursday 17:00 there is
/// nothing left to check, and the nudge must go quiet rather than nag about a
/// meal that can no longer be reserved.
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

    if (dayDelta == 0 &&
        check.time.minutesSinceMidnight <= nowMinutes) {
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
DateTime? nextNudgeFireUtc({
  required DateTime now,
  required DateTime today,
}) {
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
