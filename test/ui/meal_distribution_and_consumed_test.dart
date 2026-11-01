import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/core/local_meal_store.dart';
import 'package:bahonar_nut/core/meal_invariant.dart';
import 'package:bahonar_nut/core/platform_stores.dart';
import 'package:bahonar_nut/ui/reservation_table_model.dart';
import 'package:bahonar_nut/ui/screens/reservations_table.dart';

void main() {
  group('isMealDistributionPassed', () {
    // 2026-10-20 at 12:00 UTC == 15:30 Iran time (UTC+3:30)
    final clockAtLunchCutoff = FixedServerClock.now(DateTime.utc(2026, 10, 20, 12, 0));
    // 2026-10-20 at 12:01 UTC == 15:31 Iran time
    final clockAfterLunchCutoff = FixedServerClock.now(DateTime.utc(2026, 10, 20, 12, 1));
    // 2026-10-20 at 17:01 UTC == 20:31 Iran time
    final clockAfterDinnerCutoff = FixedServerClock.now(DateTime.utc(2026, 10, 20, 17, 1));
    // 2026-10-20 at 05:01 UTC == 08:31 Iran time
    final clockAfterBreakfastCutoff = FixedServerClock.now(DateTime.utc(2026, 10, 20, 5, 1));

    test('past date is always passed', () {
      final pastDate = DateTime.utc(2026, 10, 19);
      expect(
        isMealDistributionPassed(pastDate, MealSlot.lunch, clock: clockAtLunchCutoff),
        isTrue,
      );
      expect(
        isMealDistributionPassed(pastDate, MealSlot.dinner, clock: clockAtLunchCutoff),
        isTrue,
      );
    });

    test('future date is never passed', () {
      final futureDate = DateTime.utc(2026, 10, 21);
      expect(
        isMealDistributionPassed(futureDate, MealSlot.lunch, clock: clockAfterDinnerCutoff),
        isFalse,
      );
      expect(
        isMealDistributionPassed(futureDate, MealSlot.breakfast, clock: clockAfterDinnerCutoff),
        isFalse,
      );
    });

    test('today lunch is not passed at 15:30, but is passed at 15:31', () {
      final today = DateTime.utc(2026, 10, 20);
      expect(
        isMealDistributionPassed(today, MealSlot.lunch, clock: clockAtLunchCutoff),
        isFalse,
      );
      expect(
        isMealDistributionPassed(today, MealSlot.lunch, clock: clockAfterLunchCutoff),
        isTrue,
      );
    });

    test('today dinner is not passed at 15:30, but is passed at 20:31', () {
      final today = DateTime.utc(2026, 10, 20);
      expect(
        isMealDistributionPassed(today, MealSlot.dinner, clock: clockAtLunchCutoff),
        isFalse,
      );
      expect(
        isMealDistributionPassed(today, MealSlot.dinner, clock: clockAfterDinnerCutoff),
        isTrue,
      );
    });

    test('today breakfast is passed after 08:30', () {
      final today = DateTime.utc(2026, 10, 20);
      expect(
        isMealDistributionPassed(today, MealSlot.breakfast, clock: clockAfterBreakfastCutoff),
        isTrue,
      );
    });
  });

  group('StoredMeal isConsumed serialization', () {
    test('encodeMealList preserves isConsumed and decodeMealList restores it', () {
      final meals = [
        StoredMeal(
          accountId: 'acc1',
          date: DateTime.utc(2026, 10, 20),
          slot: MealSlot.lunch,
          source: MealSource.weeklyReservation,
          capturedAt: DateTime.utc(2026, 10, 18),
          dishName: 'قرمه سبزی',
          isConsumed: true,
        ),
        StoredMeal(
          accountId: 'acc1',
          date: DateTime.utc(2026, 10, 21),
          slot: MealSlot.dinner,
          source: MealSource.weeklyReservation,
          capturedAt: DateTime.utc(2026, 10, 18),
          dishName: 'زرشک پلو',
          isConsumed: false,
        ),
      ];

      final encoded = encodeMealList(meals);
      final decoded = decodeMealList(encoded);

      expect(decoded.length, 2);
      expect(decoded[0].isConsumed, isTrue);
      expect(decoded[1].isConsumed, isFalse);
    });
  });

  group('buildMealRows with consumed and distribution cutoff', () {
    test('marks row as consumed when held meal has isConsumed=true', () {
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 20, 12, 0));
      final rows = buildMealRows(
        menus: const [],
        held: [
          StoredMeal(
            accountId: 'acc1',
            date: DateTime.utc(2026, 10, 20),
            slot: MealSlot.lunch,
            source: MealSource.weeklyReservation,
            capturedAt: DateTime.utc(2026, 10, 18),
            dishName: 'چلو جوجه کباب',
            isConsumed: true,
          ),
        ],
        clock: clock,
      );

      expect(rows.length, 1);
      final row = rows.first;
      expect(row.status, MealRowStatus.consumed);
      expect(row.isConsumed, isTrue);
      expect(row.statusLabel, 'خورده شده');
      expect(row.cancellable, isFalse);
      expect(row.sellable, isFalse);
    });

    test('marks isDistributionPassed=true when past distribution cutoff', () {
      // 12:01 UTC == 15:31 Iran time, so lunch cutoff (15:30) has passed
      final clockAfterCutoff = FixedServerClock.now(DateTime.utc(2026, 10, 20, 12, 1));
      final rows = buildMealRows(
        menus: const [],
        held: [
          StoredMeal(
            accountId: 'acc1',
            date: DateTime.utc(2026, 10, 20),
            slot: MealSlot.lunch,
            source: MealSource.weeklyReservation,
            capturedAt: DateTime.utc(2026, 10, 18),
            dishName: 'چلو قرمه سبزی',
            isConsumed: false,
          ),
        ],
        clock: clockAfterCutoff,
      );

      expect(rows.length, 1);
      final row = rows.first;
      expect(row.isDistributionPassed, isTrue);
      expect(row.sellable, isFalse);
      expect(row.cancellable, isFalse);
    });
  });

  group('ReservationsTable UI rendering for cutoff and consumed', () {
    Widget wrap(Widget child) => MaterialApp(
          home: Scaffold(body: child),
        );

    testWidgets('disables sell and receipt buttons when distribution has passed', (tester) async {
      bool sellCalled = false;
      bool receiptCalled = false;

      final rows = [
        MealRow(
          date: DateTime.utc(2026, 10, 20),
          slot: MealSlot.lunch,
          status: MealRowStatus.heldLocked,
          dishName: 'چلو قیمه',
          priceRial: 300000,
          isDistributionPassed: true,
        ),
      ];

      await tester.pumpWidget(
        wrap(
          ReservationsTable(
            rows: rows,
            onBook: (_, _) {},
            onCancel: (_, _) {},
            onSell: (_, _) => sellCalled = true,
            onForgotReceipt: (_, _, _, _) => receiptCalled = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tooltips indicate actions are disabled
      expect(find.byTooltip('مهلت فروش به پایان رسیده است'), findsOneWidget);
      expect(find.byTooltip('مهلت دریافت فیش به پایان رسیده است'), findsOneWidget);

      // Tap sell button -> should not trigger
      await tester.tap(find.byTooltip('مهلت فروش به پایان رسیده است'));
      await tester.pump();
      expect(sellCalled, isFalse);

      // Tap receipt button -> should not trigger
      await tester.tap(find.byTooltip('مهلت دریافت فیش به پایان رسیده است'));
      await tester.pump();
      expect(receiptCalled, isFalse);
    });

    testWidgets('displays consumed badge and icon when row is consumed', (tester) async {
      final rows = [
        MealRow(
          date: DateTime.utc(2026, 10, 20),
          slot: MealSlot.lunch,
          status: MealRowStatus.consumed,
          dishName: 'چلو اکبرجوجه',
          priceRial: 400000,
          isConsumed: true,
          isDistributionPassed: true,
        ),
      ];

      await tester.pumpWidget(
        wrap(
          ReservationsTable(
            rows: rows,
            onBook: (_, _) {},
            onCancel: (_, _) {},
            onSell: (_, _) {},
            onForgotReceipt: (_, _, _, _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Check status chip displays "خورده شده"
      expect(find.text('خورده شده'), findsOneWidget);

      // Check actions area displays "تحویل شده" badge
      expect(find.text('تحویل شده'), findsOneWidget);
      expect(find.byTooltip('این وعده تحویل گرفته شده (خورده شده)'), findsOneWidget);

      // Restaurant icon is displayed for consumed slot badge and action
      expect(find.byIcon(Icons.restaurant), findsNWidgets(2));
    });

    testWidgets('shows cached receipt code even when distribution has passed', (tester) async {
      bool viewReceiptCalled = false;

      final rows = [
        MealRow(
          date: DateTime.utc(2026, 10, 20),
          slot: MealSlot.lunch,
          status: MealRowStatus.heldLocked,
          dishName: 'چلو قیمه',
          priceRial: 300000,
          receiptCode: '87654321',
          isDistributionPassed: true,
        ),
      ];

      await tester.pumpWidget(
        wrap(
          ReservationsTable(
            rows: rows,
            onBook: (_, _) {},
            onCancel: (_, _) {},
            onSell: (_, _) {},
            onForgotReceipt: (_, _, _, _) => viewReceiptCalled = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Receipt code viewing button remains active
      final receiptBtn = find.byTooltip('مشاهده فیش صادر شده (کد: 87654321)');
      expect(receiptBtn, findsOneWidget);

      await tester.tap(receiptBtn);
      await tester.pump();
      expect(viewReceiptCalled, isTrue);
    });
  });
}
