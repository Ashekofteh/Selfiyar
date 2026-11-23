import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/shared/time.dart';
import 'package:test/test.dart';

/// Portal timezone is UTC+3:30 (Iran, no DST since 2022).
/// So 17:00 portal-local == 13:30 UTC on the same civil day.
void main() {
  group('ClockTime', () {
    test('orders by minutes since midnight', () {
      expect(const ClockTime(9, 0) < const ClockTime(10, 0), isTrue);
      expect(const ClockTime(17, 0) <= const ClockTime(17, 0), isTrue);
      expect(const ClockTime(18, 0) > const ClockTime(17, 0), isTrue);
    });

    test('cutoff constant is 17:00', () {
      expect(ClockTime.cutoff.hour, 17);
      expect(ClockTime.cutoff.minute, 0);
      expect(ClockTime.cutoff.minutesSinceMidnight, 1020);
    });

    test('value equality holds', () {
      expect(const ClockTime(7, 30), const ClockTime(7, 30));
      expect(const ClockTime(7, 30).hashCode, const ClockTime(7, 30).hashCode);
    });
  });

  group('reservationLockTimeUtc', () {
    test('locks at 13:30 UTC two civil days before the target', () {
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 10, 0, 0));
      // Lunch/dinner target 2026-10-20 -> lock on 2026-10-18 at 17:00
      // portal-local = 13:30 UTC.
      final lock = clock.reservationLockTimeUtc(DateTime.utc(2026, 10, 20));
      expect(lock, DateTime.utc(2026, 10, 18, 13, 30));
    });

    test('lock instant is exactly 17:00 in portal-local terms', () {
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 10));
      final lock = clock.reservationLockTimeUtc(DateTime.utc(2026, 10, 20));
      final portalLocal = lock.add(ServerClock.portalUtcOffset);
      expect(portalLocal.hour, 17);
      expect(portalLocal.minute, 0);
      expect(portalLocal.day, 18);
    });

    test('lunch and dinner lock two days before the meal date', () {
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 10));
      final target = DateTime.utc(2026, 10, 21);
      expect(
        clock.reservationLockTimeUtc(target, MealSlot.lunch),
        DateTime.utc(2026, 10, 19, 13, 30),
      );
      expect(
        clock.reservationLockTimeUtc(target, MealSlot.dinner),
        DateTime.utc(2026, 10, 19, 13, 30),
      );
    });

    test('breakfast locks three days before the meal date', () {
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 10));
      // Breakfast on the 21st is delivered on the 20th, so its wall is the
      // 18th at 17:00 portal-local.
      expect(
        clock.reservationLockTimeUtc(
          DateTime.utc(2026, 10, 21),
          MealSlot.breakfast,
        ),
        DateTime.utc(2026, 10, 18, 13, 30),
      );
    });
  });

  group('isLocked / isReservable boundary', () {
    final target = DateTime.utc(2026, 10, 20);
    // Date-level (lunch/dinner) lock instant for this target is
    // 2026-10-18T13:30Z.

    test('one minute before lock is still reservable', () {
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 13, 29));
      expect(clock.isReservable(target), isTrue);
      expect(clock.isLocked(target), isFalse);
    });

    test('exactly at the lock instant is locked', () {
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 13, 30));
      expect(clock.isLocked(target), isTrue);
      expect(clock.isReservable(target), isFalse);
    });

    test('one second after lock is locked', () {
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 13, 30, 1));
      expect(clock.isLocked(target), isTrue);
    });

    test('well before the boundary is reservable', () {
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 15));
      expect(clock.isReservable(target), isTrue);
    });

    test('well after the boundary is locked', () {
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 19));
      expect(clock.isLocked(target), isTrue);
    });

    test('time component of targetDate is ignored (date-only semantics)', () {
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 13, 29));
      final midnight = DateTime.utc(2026, 10, 20);
      final lateInDay = DateTime.utc(2026, 10, 20, 23, 59, 59);
      expect(
        clock.reservationLockTimeUtc(midnight),
        clock.reservationLockTimeUtc(lateInDay),
      );
    });
  });

  group('slot-aware isLockedFor / isReservableFor', () {
    test('breakfast locks before lunch on the same meal date', () {
      // 2026-10-18 14:00 UTC = 17:30 portal-local Sunday.
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 14, 0));
      final wednesday = DateTime.utc(2026, 10, 21);

      expect(
        clock.isLockedFor(wednesday, MealSlot.breakfast),
        isTrue,
        reason: 'Wednesday breakfast is delivered Tuesday; wall Sunday 17:00',
      );
      expect(clock.isLockedFor(wednesday, MealSlot.lunch), isFalse);
      expect(clock.isLockedFor(wednesday, MealSlot.dinner), isFalse);
    });
  });

  group('acceptance: Sunday 18:05 portal-local', () {
    // 2026-10-18 is a Sunday. 18:05 portal-local == 14:35 UTC.
    final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 14, 35));
    final tuesday = DateTime.utc(2026, 10, 20);
    final wednesday = DateTime.utc(2026, 10, 21);

    test('Wednesday breakfast is locked', () {
      expect(clock.isLockedFor(wednesday, MealSlot.breakfast), isTrue);
    });

    test('Wednesday lunch is still open', () {
      expect(clock.isLockedFor(wednesday, MealSlot.lunch), isFalse);
      expect(clock.isReservableFor(wednesday, MealSlot.lunch), isTrue);
    });

    test('Tuesday lunch is locked', () {
      expect(clock.isLockedFor(tuesday, MealSlot.lunch), isTrue);
    });

    test('the first breakfast date skips a locked Wednesday', () {
      expect(
        clock.firstReservableDate(slot: MealSlot.breakfast),
        DateTime.utc(2026, 10, 22),
        reason: 'Wednesday breakfast is already locked; Thursday is next',
      );
    });
  });

  group('firstReservableDate', () {
    test('before today 17:00 portal-local, day-after-tomorrow is open', () {
      // 2026-10-18 10:00 UTC = 13:30 portal-local (before 17:00).
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 10, 0));
      expect(clock.firstReservableDate(), DateTime.utc(2026, 10, 20));
    });

    test('after today 17:00 portal-local, the window rolls a day forward', () {
      // 2026-10-18 14:00 UTC = 17:30 portal-local (past 17:00).
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 14, 0));
      expect(clock.firstReservableDate(), DateTime.utc(2026, 10, 21));
    });

    test(
      'breakfast starts a day later than lunch when today is past 17:00',
      () {
        // Sunday 18:05 portal-local: Wednesday lunch is still open, but
        // Wednesday breakfast is not, so breakfast's first date is Thursday.
        final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 14, 35));
        expect(clock.firstReservableDate(slot: MealSlot.breakfast), isNotNull);
        expect(
          clock.firstReservableDate(slot: MealSlot.breakfast),
          DateTime.utc(2026, 10, 22),
        );
        expect(
          clock.firstReservableDate(slot: MealSlot.lunch),
          DateTime.utc(2026, 10, 21),
        );
      },
    );

    test('the returned date is always actually reservable', () {
      // Sweep a full day in 30-minute steps across the cutoff.
      for (var halfHour = 0; halfHour < 48; halfHour++) {
        final instant = DateTime.utc(
          2026,
          10,
          18,
        ).add(Duration(minutes: 30 * halfHour));
        final clock = FixedServerClock.now(instant);
        final first = clock.firstReservableDate();
        expect(
          clock.isReservable(first),
          isTrue,
          reason: 'firstReservableDate must be reservable at $instant',
        );
        // And nothing before it should be reservable.
        final dayBefore = DateTime.utc(first.year, first.month, first.day - 1);
        expect(
          clock.isReservable(dayBefore),
          isFalse,
          reason: 'the day before $first must be locked at $instant',
        );
      }
    });

    test('the slot-aware first date is always reservable for that slot', () {
      for (var halfHour = 0; halfHour < 48; halfHour++) {
        final instant = DateTime.utc(
          2026,
          10,
          18,
        ).add(Duration(minutes: 30 * halfHour));
        final clock = FixedServerClock.now(instant);
        for (final slot in MealSlot.values) {
          final first = clock.firstReservableDate(slot: slot);
          expect(
            clock.isReservableFor(first, slot),
            isTrue,
            reason: '$slot at $instant',
          );
          final dayBefore = DateTime.utc(
            first.year,
            first.month,
            first.day - 1,
          );
          expect(
            clock.isReservableFor(dayBefore, slot),
            isFalse,
            reason: '$slot day before $first must be locked at $instant',
          );
        }
      }
    });
  });

  group('minutesUntilLock', () {
    test('positive before the boundary, negative after', () {
      final before = FixedServerClock.now(DateTime.utc(2026, 10, 18, 13, 0));
      expect(before.minutesUntilLock(DateTime.utc(2026, 10, 20)), 30);

      final after = FixedServerClock.now(DateTime.utc(2026, 10, 18, 14, 0));
      expect(after.minutesUntilLock(DateTime.utc(2026, 10, 20)), -30);
    });
  });

  group('portal timezone sanity', () {
    test('portalNow is utc + 3:30', () {
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 12, 0));
      final portal = clock.portalNow;
      expect(portal.hour, 15);
      expect(portal.minute, 30);
    });

    test(
      'a UTC instant late on the 18th is already the 19th in the portal',
      () {
        // 2026-10-18 21:00 UTC = 2026-10-19 00:30 portal-local.
        final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 21, 0));
        expect(clock.portalTodayUtc, DateTime.utc(2026, 10, 19));
      },
    );
  });
}
