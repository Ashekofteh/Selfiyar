import 'package:bahonar_nut/core/meal/local_meal_store.dart';
import 'package:bahonar_nut/core/meal/meal_invariant.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/shared/time.dart';
import 'package:bahonar_nut/ui/features/reservations/reservation_table_model.dart';
import 'package:test/test.dart';

void main() {
  group('weekStartSaturday', () {
    // 2026-10-17 is Saturday (1405/07/25)
    // 2026-10-18 is Sunday (1405/07/26)
    // 2026-10-19 is Monday (1405/07/27)
    // 2026-10-23 is Friday (1405/08/01)
    // 2026-10-24 is Saturday (1405/08/02)
    test('identifies Saturday as its own week start', () {
      final sat = DateTime.utc(2026, 10, 17, 15, 30);
      final start = weekStartSaturday(sat);
      expect(start, DateTime.utc(2026, 10, 17));
    });

    test('identifies Saturday for Sunday of the same week', () {
      final sun = DateTime.utc(2026, 10, 18, 8);
      final start = weekStartSaturday(sun);
      expect(start, DateTime.utc(2026, 10, 17));
    });

    test('identifies Saturday for Monday of the same week', () {
      final mon = DateTime.utc(2026, 10, 19);
      final start = weekStartSaturday(mon);
      expect(start, DateTime.utc(2026, 10, 17));
    });

    test('identifies Saturday for Friday of the same week', () {
      final fri = DateTime.utc(2026, 10, 23, 23, 59);
      final start = weekStartSaturday(fri);
      expect(start, DateTime.utc(2026, 10, 17));
    });

    test('next Saturday starts the new week', () {
      final nextSat = DateTime.utc(2026, 10, 24);
      final start = weekStartSaturday(nextSat);
      expect(start, DateTime.utc(2026, 10, 24));
    });
  });

  group('weekEndFriday', () {
    test('adds 6 days to Saturday', () {
      final sat = DateTime.utc(2026, 10, 17);
      final fri = weekEndFriday(sat);
      expect(fri, DateTime.utc(2026, 10, 23));
      expect(fri.weekday, DateTime.friday);
    });
  });

  group('formatWeekRange', () {
    test('formats range crossing Jalali month boundary (Mehr to Aban)', () {
      // 2026-10-17 (25 Mehr 1405) .. 2026-10-23 (1 Aban 1405)
      final sat = DateTime.utc(2026, 10, 17);
      final range = formatWeekRange(sat);
      expect(range, '۲۵ مهر الی ۱ آبان ۱۴۰۵');
    });

    test('formats range within the same Jalali month', () {
      // 2026-10-24 (2 Aban 1405) .. 2026-10-30 (8 Aban 1405)
      final sat = DateTime.utc(2026, 10, 24);
      final range = formatWeekRange(sat);
      expect(range, '۲ الی ۸ آبان ۱۴۰۵');
    });
  });

  group('formatWeekTitle', () {
    test('returns exact titles for relative offsets', () {
      expect(formatWeekTitle(0), 'هفته جاری');
      expect(formatWeekTitle(1), 'هفته بعد');
      expect(formatWeekTitle(-1), 'هفته قبل');
      expect(formatWeekTitle(2), '۲ هفته بعد');
      expect(formatWeekTitle(-2), '۲ هفته قبل');
      expect(formatWeekTitle(3), '۳ هفته بعد');
    });
  });

  group('filterRowsForWeek', () {
    final rowPast = MealRow(
      date: DateTime.utc(2026, 10, 15),
      slot: MealSlot.lunch,
      status: MealRowStatus.heldLocked,
    );
    final rowThisWeekSat = MealRow(
      date: DateTime.utc(2026, 10, 17),
      slot: MealSlot.lunch,
      status: MealRowStatus.bookable,
    );
    final rowThisWeekWed = MealRow(
      date: DateTime.utc(2026, 10, 21),
      slot: MealSlot.dinner,
      status: MealRowStatus.held,
    );
    final rowNextWeekSat = MealRow(
      date: DateTime.utc(2026, 10, 24),
      slot: MealSlot.lunch,
      status: MealRowStatus.bookable,
    );

    final allRows = [rowPast, rowThisWeekSat, rowThisWeekWed, rowNextWeekSat];

    test('filters to current week only', () {
      final thisWeek = filterRowsForWeek(allRows, DateTime.utc(2026, 10, 17));
      expect(thisWeek, [rowThisWeekSat, rowThisWeekWed]);
    });

    test('filters to next week only', () {
      final nextWeek = filterRowsForWeek(allRows, DateTime.utc(2026, 10, 24));
      expect(nextWeek, [rowNextWeekSat]);
    });

    test('filters to past week only', () {
      final pastWeek = filterRowsForWeek(allRows, DateTime.utc(2026, 10, 10));
      expect(pastWeek, [rowPast]);
    });
  });

  group('neutral status labels (H4)', () {
    MealRow row(MealRowStatus status) => MealRow(
      date: DateTime.utc(2026, 10, 21),
      slot: MealSlot.lunch,
      status: status,
    );

    test('a locked row says بسته, not مهلت گذشته', () {
      expect(row(MealRowStatus.locked).statusLabel, 'بسته');
    });

    test('a held-locked row says رزرو شده (بسته)', () {
      expect(row(MealRowStatus.heldLocked).statusLabel, 'رزرو شده (بسته)');
    });

    test('neither label claims the deadline passed', () {
      for (final status in [MealRowStatus.locked, MealRowStatus.heldLocked]) {
        expect(row(status).statusLabel, isNot(contains('مهلت گذشته')));
      }
    });
  });

  group('slot-aware row locks (H1)', () {
    // Sunday 2026-10-18 18:05 portal-local = 14:35 UTC.
    final sundayEvening = FixedServerClock.now(
      DateTime.utc(2026, 10, 18, 14, 35),
    );
    final wednesday = DateTime.utc(2026, 10, 21);

    MealMenu menu(DateTime date, MealSlot slot) => MealMenu(
      date: date,
      slot: slot,
      halls: const [Hall(id: '1', name: 'مرکزی برادران')],
      dishes: const [
        MenuOption(id: '1', name: 'چلو اکبرجوجه', priceRial: 500000),
      ],
      reservable: true,
    );

    test('Wednesday breakfast is locked while Wednesday lunch is open', () {
      final rows = buildMealRows(
        menus: [
          menu(wednesday, MealSlot.breakfast),
          menu(wednesday, MealSlot.lunch),
        ],
        held: const [],
        clock: sundayEvening,
      );

      final breakfast = rows.singleWhere((r) => r.slot == MealSlot.breakfast);
      final lunch = rows.singleWhere((r) => r.slot == MealSlot.lunch);
      expect(breakfast.status, MealRowStatus.locked);
      expect(lunch.status, MealRowStatus.bookable);
    });

    test('a held Wednesday breakfast is held-locked, a held lunch is not', () {
      final rows = buildMealRows(
        menus: const [],
        held: [
          StoredMeal(
            accountId: 'a1',
            date: wednesday,
            slot: MealSlot.breakfast,
            source: MealSource.weeklyReservation,
            capturedAt: DateTime.utc(2026, 10, 18),
            dishName: 'صبحانه',
            priceRial: 150000,
          ),
          StoredMeal(
            accountId: 'a1',
            date: wednesday,
            slot: MealSlot.lunch,
            source: MealSource.weeklyReservation,
            capturedAt: DateTime.utc(2026, 10, 18),
            dishName: 'ناهار',
            priceRial: 350000,
          ),
        ],
        clock: sundayEvening,
      );

      final breakfast = rows.singleWhere((r) => r.slot == MealSlot.breakfast);
      final lunch = rows.singleWhere((r) => r.slot == MealSlot.lunch);
      expect(breakfast.status, MealRowStatus.heldLocked);
      expect(lunch.status, MealRowStatus.held);
    });
  });
}
