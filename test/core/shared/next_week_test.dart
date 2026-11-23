import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/shared/next_week.dart';
import 'package:bahonar_nut/core/reminder/reminder.dart';
import 'package:bahonar_nut/core/shared/time.dart';
import 'package:test/test.dart';

/// Next week in this fixture begins Saturday 2026-10-24 (1405/08/02).
/// Its first servable meal is Saturday lunch, which falls due on Saturday and
/// locks on Thursday 2026-10-22 at 17:00 portal-local = 13:30 UTC.
final weekStart = DateTime.utc(2026, 10, 24);
final deadline = DateTime.utc(2026, 10, 22, 13, 30);

const central = Hall(id: '1', name: 'مرکزی برادران');

Reservation held(DateTime date, MealSlot slot) => Reservation(
  id: 'r-${date.day}-${slot.name}',
  date: date,
  slot: slot,
  hall: central,
  option: const MenuOption(id: 'x', name: 'dish', priceRial: 350000),
  state: ReservationState.active,
);

/// Every servable meal of the week, reserved — the "fully booked" baseline.
List<Reservation> fullyBookedWeek() {
  final out = <Reservation>[];
  for (var i = 0; i < 7; i++) {
    final date = DateTime.utc(2026, 10, 24 + i);
    final weekday = date.weekday;
    for (final slot in MealSlot.values) {
      // Mirror the verified calendar: Fri nothing, Thu no dinner, Sat no breakfast.
      if (weekday == DateTime.friday) continue;
      if (weekday == DateTime.thursday && slot == MealSlot.dinner) continue;
      if (weekday == DateTime.saturday && slot == MealSlot.breakfast) continue;
      out.add(held(date, slot));
    }
  }
  return out;
}

void main() {
  group('nextWeekStart', () {
    test('from a mid-week day returns the coming Saturday', () {
      // 2026-10-18 is a Sunday; the coming Saturday is the 24th.
      expect(
        nextWeekStart(DateTime.utc(2026, 10, 18)),
        DateTime.utc(2026, 10, 24),
      );
    });

    test('from Friday returns the very next day', () {
      expect(
        nextWeekStart(DateTime.utc(2026, 10, 23)),
        DateTime.utc(2026, 10, 24),
      );
    });

    test(
      'from Saturday rolls a full week forward (that week already began)',
      () {
        expect(
          nextWeekStart(DateTime.utc(2026, 10, 24)),
          DateTime.utc(2026, 10, 31),
        );
      },
    );

    test('always lands on a Saturday', () {
      for (var i = 0; i < 21; i++) {
        final d = DateTime.utc(2026, 10, 1 + i);
        expect(
          nextWeekStart(d).weekday,
          DateTime.saturday,
          reason: 'from ${d.toIso8601String()}',
        );
      }
    });

    test('always lands strictly after the given day', () {
      for (var i = 0; i < 21; i++) {
        final d = DateTime.utc(2026, 10, 1 + i);
        expect(nextWeekStart(d).isAfter(d), isTrue);
      }
    });
  });

  group('weekDates', () {
    test('yields seven consecutive days starting Saturday', () {
      final dates = weekDates(weekStart);
      expect(dates.length, 7);
      expect(dates.first, DateTime.utc(2026, 10, 24));
      expect(dates.last, DateTime.utc(2026, 10, 30));
      expect(dates.first.weekday, DateTime.saturday);
      expect(dates.last.weekday, DateTime.friday);
    });
  });

  group('gap detection: complete week', () {
    test('a fully booked week has no gaps', () {
      final status = detectNextWeekGaps(
        weekStart: weekStart,
        reservationsByAccount: {'a1': fullyBookedWeek()},
        clock: FixedServerClock.now(
          DateTime.utc(2026, 10, 21),
        ), // Wed, pre-deadline
      );
      expect(status.gaps, isEmpty);
      expect(status.isComplete, isTrue);
      expect(status.isConfidentlyComplete, isTrue);
    });

    test('deadline is Thursday 17:00 portal-local', () {
      final status = detectNextWeekGaps(
        weekStart: weekStart,
        reservationsByAccount: {'a1': fullyBookedWeek()},
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 21)),
      );
      expect(status.deadline, deadline);
      expect(status.deadline.weekday, DateTime.thursday);
      expect(
        status.deadline.add(ServerClock.portalUtcOffset).hour,
        17,
        reason: 'the portal wall is 17:00, not the old 20:00',
      );
    });
  });

  group('gap detection: closed slots are never gaps', () {
    test('Friday produces no gaps even with nothing booked', () {
      final status = detectNextWeekGaps(
        weekStart: weekStart,
        reservationsByAccount: {'a1': const []},
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 21)),
      );
      final friday = DateTime.utc(2026, 10, 30);
      expect(status.gaps.where((g) => g.date == friday), isEmpty);
    });

    test('Thursday dinner is never a gap', () {
      final status = detectNextWeekGaps(
        weekStart: weekStart,
        reservationsByAccount: {'a1': const []},
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 21)),
      );
      final thursday = DateTime.utc(2026, 10, 29);
      expect(
        status.gaps.where(
          (g) => g.date == thursday && g.slot == MealSlot.dinner,
        ),
        isEmpty,
      );
    });

    test('Saturday breakfast is never a gap', () {
      final status = detectNextWeekGaps(
        weekStart: weekStart,
        reservationsByAccount: {'a1': const []},
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 21)),
      );
      expect(
        status.gaps.where(
          (g) => g.date == weekStart && g.slot == MealSlot.breakfast,
        ),
        isEmpty,
      );
    });

    test('an empty booking yields exactly the servable slots', () {
      final status = detectNextWeekGaps(
        weekStart: weekStart,
        reservationsByAccount: {'a1': const []},
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 21)),
      );
      // Per the verified calendar over 7 days:
      //   Sat 2, Sun 3, Mon 3, Tue 3, Wed 3, Thu 2, Fri 0 = 16
      expect(status.gaps.length, 16);
    });
  });

  group('gap detection: cutoff exclusion', () {
    test('days past their cutoff drop out while later days remain', () {
      // Each meal has its OWN cutoff (17:00 two days before delivery), so a
      // week does not lock all at once. On Friday 2026-10-23 the weekend has
      // locked but the following Tuesday onwards is still bookable.
      final status = detectNextWeekGaps(
        weekStart: weekStart,
        reservationsByAccount: {'a1': const []},
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 23)),
      );

      // Sat 24 locks Thu 22 17:00 -> already past.
      expect(
        status.gaps.where((g) => g.date == DateTime.utc(2026, 10, 24)),
        isEmpty,
      );
      // Sun 25 locks Fri 23 17:00 -> still open at 00:00 on the 23rd.
      expect(
        status.gaps.where((g) => g.date == DateTime.utc(2026, 10, 25)),
        isNotEmpty,
      );
      // Tue 27 (and later) definitely still open.
      expect(
        status.gaps.where((g) => g.date == DateTime.utc(2026, 10, 27)),
        isNotEmpty,
      );
    });

    test('after the whole week has locked there are no gaps', () {
      // Thursday 2026-10-29 is the last servable day of this week; its cutoff
      // has long passed, as have all others.
      final status = detectNextWeekGaps(
        weekStart: weekStart,
        reservationsByAccount: {'a1': const []},
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 29, 12, 0)),
      );
      expect(
        status.gaps,
        isEmpty,
        reason: 'every day of the week has locked by now',
      );
    });

    test('the gap list shrinks monotonically as the week progresses', () {
      var previous = 100;
      for (final day in [21, 22, 23, 25, 27, 29]) {
        final status = detectNextWeekGaps(
          weekStart: weekStart,
          reservationsByAccount: {'a1': const []},
          clock: FixedServerClock.now(DateTime.utc(2026, 10, day, 12, 0)),
        );
        expect(
          status.gaps.length,
          lessThanOrEqualTo(previous),
          reason: 'gap count must never grow as deadlines pass (day $day)',
        );
        previous = status.gaps.length;
      }
      expect(previous, 0, reason: 'by the 29th nothing remains bookable');
    });
  });

  group('acceptance: the Thursday 17:00 wall', () {
    // Thursday 2026-10-22. 16:00 portal-local == 12:30 UTC; 17:01 == 13:31 UTC.
    final thursday1600 = FixedServerClock.now(
      DateTime.utc(2026, 10, 22, 12, 30),
    );
    final thursday1701 = FixedServerClock.now(
      DateTime.utc(2026, 10, 22, 13, 31),
    );
    final saturday = DateTime.utc(2026, 10, 24);
    final sunday = DateTime.utc(2026, 10, 25);

    test('at 16:00 Saturday lunch is still a gap', () {
      final status = detectNextWeekGaps(
        weekStart: weekStart,
        reservationsByAccount: {'a1': const []},
        clock: thursday1600,
      );
      expect(
        status.gaps.where(
          (g) => g.date == saturday && g.slot == MealSlot.lunch,
        ),
        isNotEmpty,
      );
    });

    test('at 17:01 Saturday lunch is no longer a gap', () {
      final status = detectNextWeekGaps(
        weekStart: weekStart,
        reservationsByAccount: {'a1': const []},
        clock: thursday1701,
      );
      expect(
        status.gaps.where(
          (g) => g.date == saturday && g.slot == MealSlot.lunch,
        ),
        isEmpty,
        reason: 'the portal wall has passed; the nudge must stay silent',
      );
    });

    test('at 17:01 Saturday dinner and Sunday breakfast are closed too', () {
      final status = detectNextWeekGaps(
        weekStart: weekStart,
        reservationsByAccount: {'a1': const []},
        clock: thursday1701,
      );
      expect(
        status.gaps.where(
          (g) => g.date == saturday && g.slot == MealSlot.dinner,
        ),
        isEmpty,
      );
      expect(
        status.gaps.where(
          (g) => g.date == sunday && g.slot == MealSlot.breakfast,
        ),
        isEmpty,
        reason: 'Sunday breakfast is delivered Saturday, whose wall is 17:00',
      );
    });

    test('at 16:00 Sunday breakfast is still a gap', () {
      final status = detectNextWeekGaps(
        weekStart: weekStart,
        reservationsByAccount: {'a1': const []},
        clock: thursday1600,
      );
      expect(
        status.gaps.where(
          (g) => g.date == sunday && g.slot == MealSlot.breakfast,
        ),
        isNotEmpty,
      );
    });
  });

  group('gap detection: per-account granularity', () {
    test('a meal held by one of two accounts is still a gap', () {
      final status = detectNextWeekGaps(
        weekStart: weekStart,
        reservationsByAccount: {'a1': fullyBookedWeek(), 'a2': const []},
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 21)),
      );
      // a2 is entirely unbooked, so every servable slot is a gap.
      expect(status.gaps.length, 16);
      for (final gap in status.gaps) {
        expect(gap.missingAccountIds, ['a2']);
        expect(gap.totalAccounts, 2);
        expect(gap.missingForEveryone, isFalse);
        expect(gap.missingForSome, isTrue);
      }
    });

    test('missingForEveryone is true when nobody holds the meal', () {
      final status = detectNextWeekGaps(
        weekStart: weekStart,
        reservationsByAccount: {'a1': const [], 'a2': const []},
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 21)),
      );
      expect(status.gaps.first.missingForEveryone, isTrue);
      expect(status.gaps.first.missingAccountIds.length, 2);
    });

    test('cancelled reservations do not count as held', () {
      final cancelled = Reservation(
        id: 'r1',
        date: DateTime.utc(2026, 10, 25),
        slot: MealSlot.lunch,
        hall: central,
        option: const MenuOption(id: 'x', name: 'd', priceRial: 350000),
        state: ReservationState.cancelled,
      );
      final status = detectNextWeekGaps(
        weekStart: weekStart,
        reservationsByAccount: {
          'a1': [cancelled],
        },
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 21)),
      );
      expect(
        status.gaps.where(
          (g) =>
              g.date == DateTime.utc(2026, 10, 25) && g.slot == MealSlot.lunch,
        ),
        isNotEmpty,
        reason: 'a cancelled reservation is not a reservation',
      );
    });

    test('a reservation on a different date does not satisfy the slot', () {
      // Held Saturday 24 lunch, but asked about Sunday 25 lunch.
      final status = detectNextWeekGaps(
        weekStart: weekStart,
        reservationsByAccount: {
          'a1': [held(DateTime.utc(2026, 10, 24), MealSlot.lunch)],
        },
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 21)),
      );
      expect(
        status.gaps.where(
          (g) =>
              g.date == DateTime.utc(2026, 10, 25) && g.slot == MealSlot.lunch,
        ),
        isNotEmpty,
      );
    });
  });

  group('completeness never overclaims', () {
    test('failures make the week not confidently complete', () {
      final status = detectNextWeekGaps(
        weekStart: weekStart,
        reservationsByAccount: {'a1': fullyBookedWeek()},
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 21)),
        failures: const [
          ReminderFailure(
            accountId: 'a2',
            displayName: 'شریفی',
            cause: ReminderFailureCause.authFailed,
          ),
        ],
      );
      expect(
        status.isComplete,
        isTrue,
        reason: 'no gaps among checked accounts',
      );
      expect(status.isPartial, isTrue);
      expect(
        status.isConfidentlyComplete,
        isFalse,
        reason:
            'must not claim the week is handled when an account is unchecked',
      );
    });
  });

  group('no accounts selected', () {
    test('produces no gaps and is trivially complete', () {
      final status = detectNextWeekGaps(
        weekStart: weekStart,
        reservationsByAccount: const {},
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 21)),
      );
      expect(status.gaps, isEmpty);
      expect(status.accountCount, 0);
    });
  });
}
