import 'package:bahonar_nut/core/meal/local_meal_store.dart';
import 'package:bahonar_nut/core/meal/meal_invariant.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/shared/time.dart';
import 'package:bahonar_nut/ui/features/reservations/reservation_table_model.dart';
import 'package:test/test.dart';

/// The reservations table's model.
///
/// ## What it decides
///
/// The table merges three sources into one row per (date, slot):
///
///   * the **menu** — what the portal serves, and at what price;
///   * the **mirror** — what the student already holds;
///   * the **clock** — what is past its cutoff.
///
/// The rules that matter are the ones where getting it wrong costs money, so
/// each is pinned here.
void main() {
  /// A menu for one meal.
  MealMenu menu(
    DateTime date,
    MealSlot slot, {
    List<MenuOption> dishes = const [],
    bool reservable = true,
  }) =>
      MealMenu(
        date: date,
        slot: slot,
        halls: const [Hall(id: '1', name: 'مرکزی برادران')],
        dishes: dishes.isEmpty
            ? const [MenuOption(id: '1', name: 'چلو اکبرجوجه', priceRial: 500000)]
            : dishes,
        reservable: reservable,
      );

  /// A clock whose portal today is 2026-10-20, so the first reservable date
  /// is 2026-10-22.
  final clock = FixedServerClock.now(DateTime.utc(2026, 10, 20, 12));

  group('the rows', () {
    test('are one per (date, slot), in date then meal order', () {
      final rows = buildMealRows(
        menus: [
          menu(DateTime.utc(2026, 10, 23), MealSlot.dinner),
          menu(DateTime.utc(2026, 10, 22), MealSlot.lunch),
          menu(DateTime.utc(2026, 10, 22), MealSlot.breakfast),
        ],
        held: const [],
        clock: clock,
      );

      expect(
        rows.map((r) => '${r.date.toIso8601String().substring(0, 10)}|${r.slot.name}'),
        [
          '2026-10-22|breakfast',
          '2026-10-22|lunch',
          '2026-10-23|dinner',
        ],
        reason: 'the table reads as a schedule: day by day, meal by meal',
      );
    });

    test('a bookable meal says so, and carries its price', () {
      final rows = buildMealRows(
        menus: [menu(DateTime.utc(2026, 10, 22), MealSlot.lunch)],
        held: const [],
        clock: clock,
      );

      expect(rows.single.status, MealRowStatus.bookable);
      expect(rows.single.priceRial, 500000);
      expect(rows.single.optionCount, 1);
    });

    test('a meal past its cutoff says so, and offers nothing', () {
      // 2026-10-21 is inside the cutoff wall — it locks at 20:00 on the 19th.
      final rows = buildMealRows(
        menus: [menu(DateTime.utc(2026, 10, 21), MealSlot.lunch)],
        held: const [],
        clock: clock,
      );

      expect(rows.single.status, MealRowStatus.locked,
          reason: 'the portal refuses a locked row silently, so the app has '
              'to say so first');
    });

    test('a held meal names its dish and its price', () {
      final rows = buildMealRows(
        menus: const [],
        held: [
          StoredMeal(
            accountId: 'a1',
            date: DateTime.utc(2026, 10, 22),
            slot: MealSlot.lunch,
            source: MealSource.weeklyReservation,
            capturedAt: DateTime.utc(2026, 10, 20),
            dishName: 'چلو خورشت قیمه',
            hallName: 'فنی برادران',
            priceRial: 350000,
          ),
        ],
        clock: clock,
      );

      final row = rows.single;
      expect(row.status, MealRowStatus.held);
      expect(row.dishName, 'چلو خورشت قیمه');
      expect(row.hallName, 'فنی برادران');
      expect(row.priceRial, 350000);
      expect(row.cancellable, isTrue,
          reason: 'a weekly reservation can be given back while its date is '
              'editable');
      expect(row.sellable, isFalse);
    });

    test('a basket purchase is held, and cannot be cancelled', () {
      final rows = buildMealRows(
        menus: const [],
        held: [
          StoredMeal(
            accountId: 'a1',
            date: DateTime.utc(2026, 10, 22),
            slot: MealSlot.lunch,
            source: MealSource.basketPurchase,
            capturedAt: DateTime.utc(2026, 10, 20),
            dishName: 'چلو اکبرجوجه',
            priceRial: 500000,
          ),
        ],
        clock: clock,
      );

      final row = rows.single;
      expect(row.status, MealRowStatus.bought);
      expect(row.cancellable, isFalse,
          reason: 'a basket purchase is irreversible — offering a cancel '
              'would be a lie');
      expect(row.sellable, isFalse);
    });

    test('a meal the student holds appears even when the portal serves none',
        () {
      // A basket purchase never appears in the weekly grid (F16), so a
      // menu-only table would hide a meal the student paid for.
      final rows = buildMealRows(
        menus: const [],
        held: [
          StoredMeal(
            accountId: 'a1',
            date: DateTime.utc(2026, 10, 24),
            slot: MealSlot.dinner,
            source: MealSource.basketPurchase,
            capturedAt: DateTime.utc(2026, 10, 20),
            dishName: 'خوراک سالاد الویه',
            priceRial: 350000,
          ),
        ],
        clock: clock,
      );

      expect(rows, hasLength(1));
      expect(rows.single.dishName, 'خوراک سالاد الویه');
    });

    test('a meal the portal does not serve, and the student does not hold, '
        'is not shown', () {
      final rows = buildMealRows(
        menus: const [],
        held: const [],
        clock: clock,
      );

      expect(rows, isEmpty);
    });

    test('the price cell carries the cheapest option', () {
      final rows = buildMealRows(
        menus: [
          menu(
            DateTime.utc(2026, 10, 22),
            MealSlot.lunch,
            dishes: const [
              MenuOption(id: '1', name: 'گران', priceRial: 700000),
              MenuOption(id: '2', name: 'ارزان', priceRial: 300000),
            ],
          ),
        ],
        held: const [],
        clock: clock,
      );

      expect(rows.single.priceRial, 300000,
          reason: 'the cheapest is the number a student looks at first');
      expect(rows.single.optionCount, 2);
    });

    test('without a synced clock no meal is called locked', () {
      // The cutoff is the portal's own, and the portal's clock is the only
      // authority on it. Guessing would lock meals that are open.
      final rows = buildMealRows(
        menus: [menu(DateTime.utc(2026, 10, 21), MealSlot.lunch)],
        held: const [],
        clock: null,
      );

      expect(rows.single.status, MealRowStatus.bookable);
    });

    test('a held meal past its cutoff cannot be cancelled', () async {
      // A locked date's cancel is discarded by the portal (F14), so a cancel
      // button on this row would offer a cancellation that silently does
      // nothing (F63). The meal is still shown — the student holds it — but
      // it is not cancellable.
      final rows = buildMealRows(
        menus: const [],
        held: [
          StoredMeal(
            accountId: 'a1',
            date: DateTime.utc(2026, 10, 20),
            slot: MealSlot.lunch,
            source: MealSource.weeklyReservation,
            capturedAt: DateTime.utc(2026, 10, 18),
            dishName: 'زرشک پلو با مرغ',
            priceRial: 500000,
          ),
        ],
        clock: clock,
      );

      final row = rows.single;
      expect(row.status, MealRowStatus.heldLocked);
      expect(row.cancellable, isFalse);
      expect(row.sellable, isTrue);
      expect(row.dishName, 'زرشک پلو با مرغ',
          reason: 'the meal is still the student\'s, so it is still shown');
    });

    test('a held meal before its cutoff can still be cancelled', () {
      final rows = buildMealRows(
        menus: const [],
        held: [
          StoredMeal(
            accountId: 'a1',
            date: DateTime.utc(2026, 10, 22),
            slot: MealSlot.lunch,
            source: MealSource.weeklyReservation,
            capturedAt: DateTime.utc(2026, 10, 20),
            dishName: 'چلو اکبرجوجه',
            priceRial: 500000,
          ),
        ],
        clock: clock,
      );

      expect(rows.single.status, MealRowStatus.held);
      expect(rows.single.cancellable, isTrue);
    });

    test('a next-week meal the grid reports is held, and can be cancelled', () {
      // The live defect (2026-10-21): the account held a breakfast on
      // 2026-10-25 — a **next-week** date. The reservation read stopped at
      // the current week, so the mirror never saw it in the grid and fell
      // back to the ledger. And the ledger records a weekly reservation and a
      // Food Basket purchase identically, so the meal was filed as an
      // **irreversible basket purchase**.
      //
      // The symptom: the table showed «خریداری شده» on a meal the portal
      // would have let the student give back, and offered no cancel button —
      // while the portal's own page carried the green «رزرو شده» icon and a
      // non-zero amount for it.
      //
      // So the row is built from what the grid says, and a next-week weekly
      // reservation is cancellable like any other.
      final rows = buildMealRows(
        menus: [
          menu(DateTime.utc(2026, 10, 25), MealSlot.breakfast),
        ],
        held: [
          StoredMeal(
            accountId: 'a1',
            date: DateTime.utc(2026, 10, 25),
            slot: MealSlot.breakfast,
            source: MealSource.weeklyReservation,
            capturedAt: DateTime.utc(2026, 10, 21),
            dishName: 'پنیر/خیار/نان/چای/قند',
            hallName: 'مرکزی برادران',
            priceRial: 150000,
          ),
        ],
        clock: clock,
      );

      final row = rows.single;
      expect(row.status, MealRowStatus.held,
          reason: 'the grid says it is a weekly reservation, so it is one');
      expect(row.cancellable, isTrue,
          reason: 'a next-week reservation is still editable, so it can be '
              'given back');
      expect(row.statusLabel, 'رزرو شده');
    });
  });
}
