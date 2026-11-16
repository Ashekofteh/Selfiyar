/// Next-week reservation nudge: finding meals that are still unbooked.
///
/// The coming week begins Saturday. Its first deadline is Saturday's meals,
/// which cut off at 20:00 two days prior — **Thursday 20:00**. A student who
/// misses that wall has no weekend meals, so there is a real window in which a
/// nudge is actionable: roughly Wednesday noon through Thursday evening.
///
/// This library is pure: no clock, no I/O, no Flutter.
library;

import '../meal/models.dart';
import '../reminder/reminder.dart';
import 'service_calendar.dart';
import 'time.dart';

/// A meal that could still be reserved and is not held by every selected account.
class BookingGap {
  const BookingGap({
    required this.date,
    required this.slot,
    required this.missingAccountIds,
    required this.totalAccounts,
  });

  final DateTime date;
  final MealSlot slot;

  /// Accounts that do **not** hold this meal. Never empty: a gap exists only
  /// when at least one account is missing it.
  final List<AccountId> missingAccountIds;

  final int totalAccounts;

  /// True when no selected account holds this meal.
  bool get missingForEveryone => missingAccountIds.length == totalAccounts;

  /// True when some but not all accounts hold it.
  bool get missingForSome => !missingForEveryone;

  @override
  String toString() =>
      'BookingGap(${date.toIso8601String()} ${slot.name}, '
      'missing ${missingAccountIds.length}/$totalAccounts)';
}

/// The result of checking the coming week.
class NextWeekStatus {
  const NextWeekStatus({
    required this.weekStart,
    required this.weekEnd,
    required this.deadline,
    required this.gaps,
    this.failures = const [],
    required this.accountCount,
  });

  /// First day of the coming week (a Saturday).
  final DateTime weekStart;

  /// Last day of the coming week (a Friday).
  final DateTime weekEnd;

  /// When the first meal of the week locks: Thursday 20:00 portal-local.
  final DateTime deadline;

  final List<BookingGap> gaps;
  final List<ReminderFailure> failures;
  final int accountCount;

  /// True when every selected account holds every servable meal still open for booking.
  bool get isComplete => gaps.isEmpty;

  /// True when some accounts could not be checked, so completeness is unknown.
  bool get isPartial => failures.isNotEmpty;

  /// True only when the week is fully booked AND every account was checked.
  ///
  /// This is the condition under which the nudge stays silent, and the reason
  /// it is distinct from [isComplete]: completing on partial information would
  /// mean silently trusting an account that might be unfed.
  bool get isConfidentlyComplete => isComplete && !isPartial;
}

/// The seven civil dates of a week beginning at [weekStart].
List<DateTime> weekDates(DateTime weekStart) => List.generate(
      7,
      (i) => DateTime.utc(weekStart.year, weekStart.month, weekStart.day + i),
    );

/// The Saturday that begins the next week relative to [today].
///
/// Saturday is the first day of the week in this calendar (Friday is the last),
/// so a week always starts on a Saturday and ends on the following Friday.
DateTime nextWeekStart(DateTime today) {
  final date = DateTime.utc(today.year, today.month, today.day);
  // Days until the coming Saturday (0 when today already is Saturday).
  final delta = (DateTime.saturday - date.weekday + 7) % 7;
  final thisSaturday = DateTime.utc(date.year, date.month, date.day + delta);
  // If today is Saturday, "next week" means the week after this one, since the
  // current Saturday has already begun its own week.
  return date.weekday == DateTime.saturday
      ? DateTime.utc(thisSaturday.year, thisSaturday.month, thisSaturday.day + 7)
      : thisSaturday;
}

/// Detects unbooked meals in the coming week.
///
/// A gap is recorded when, for a served slot on a date whose cutoff has not yet
/// passed, **at least one selected account does not hold that meal**. The
/// success criterion is that everyone is fed, so a single unfed account is worth
/// telling the user about.
///
/// Two exclusions, both deliberate:
///   * **Closed slots** ([ServiceCalendar]) — no point asking for a meal the
///     halls do not serve.
///   * **Past-cutoff dates** — a slot that has already locked cannot be reserved,
///     and a notification demanding an impossible action is worse than silence.
NextWeekStatus detectNextWeekGaps({
  required DateTime weekStart,
  required Map<AccountId, List<Reservation>> reservationsByAccount,
  required ServerClock clock,
  ServiceCalendar calendar = const ServiceCalendar(),
  List<ReminderFailure> failures = const [],
}) {
  final dates = weekDates(weekStart);
  final weekEnd = dates.last;
  final accountIds = reservationsByAccount.keys.toList();

  // The deadline is when the first day's meals lock.
  final deadline = clock.reservationLockTimeUtc(weekStart);

  final gaps = <BookingGap>[];

  for (final date in dates) {
    for (final slot in MealSlot.values) {
      if (!calendar.isServedOn(date, slot)) continue;

      // Already locked: unbookable, so not a gap.
      if (clock.isLocked(date)) continue;

      final missing = <AccountId>[];
      for (final accountId in accountIds) {
        final held = reservationsByAccount[accountId] ?? const <Reservation>[];
        final hasIt = held.any(
          (r) =>
              r.slot == slot &&
              r.state == ReservationState.active &&
              _sameDate(r.date, date),
        );
        if (!hasIt) missing.add(accountId);
      }

      if (missing.isNotEmpty) {
        gaps.add(BookingGap(
          date: date,
          slot: slot,
          missingAccountIds: missing,
          totalAccounts: accountIds.length,
        ));
      }
    }
  }

  return NextWeekStatus(
    weekStart: weekStart,
    weekEnd: weekEnd,
    deadline: deadline,
    gaps: gaps,
    failures: failures,
    accountCount: accountIds.length,
  );
}

bool _sameDate(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;