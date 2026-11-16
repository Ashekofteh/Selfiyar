import 'package:bahonar_nut/core/auth/account_store.dart';
import 'package:bahonar_nut/core/meal/local_meal_store.dart';
import 'package:bahonar_nut/core/meal/meal_invariant.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/shared/time.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/features/reservations/reservations_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Use a fixed server clock synced to Sunday, 1405/07/26 (2026-10-18 12:00 UTC).
  // Current week: Sat 1405/07/25 (2026-10-17) .. Fri 1405/08/01 (2026-10-23).
  // Next week:    Sat 1405/08/02 (2026-10-24) .. Fri 1405/08/08 (2026-10-30).
  // Last week:    Sat 1405/07/18 (2026-10-10) .. Fri 1405/07/24 (2026-10-16).
  final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 12));

  Future<AppState> buildState() async {
    final state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
      mealStore: LocalMealStore(),
    );
    await state.load();
    await state.upsertAccount(studentId: '400123456', alias: 'آرمین');
    return state;
  }

  Widget wrap(Widget child) {
    return MaterialApp(
      locale: const Locale('fa', 'IR'),
      supportedLocales: const [Locale('fa', 'IR')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Directionality(textDirection: TextDirection.rtl, child: child),
    );
  }

  testWidgets(
    'initial render displays current week title and Jalali date range',
    (tester) async {
      final state = await buildState();

      await tester.pumpWidget(
        wrap(ReservationsScreen(state: state, clock: clock)),
      );
      await tester.pumpAndSettle();

      expect(find.text('هفته جاری'), findsOneWidget);
      // Range: 25 Mehr to 1 Aban 1405
      expect(find.text('۲۵ مهر الی ۱ آبان ۱۴۰۵'), findsOneWidget);
      // Reset badge should not be visible when already on current week
      expect(find.text('بازگشت به امروز'), findsNothing);
    },
  );

  testWidgets(
    'tapping next week advances by one week and displays next week meals',
    (tester) async {
      final state = await buildState();
      final accountId = state.accounts.first.id;

      // Put a meal in the current week (Monday 2026-10-19)
      state.mealStore.put(
        StoredMeal(
          accountId: accountId,
          date: DateTime.utc(2026, 10, 19),
          slot: MealSlot.lunch,
          source: MealSource.weeklyReservation,
          capturedAt: DateTime.utc(2026, 10, 18),
          dishName: 'قیمه بادمجان',
          priceRial: 350000,
        ),
      );

      // Put a meal in the next week (Sunday 2026-10-25)
      state.mealStore.put(
        StoredMeal(
          accountId: accountId,
          date: DateTime.utc(2026, 10, 25),
          slot: MealSlot.lunch,
          source: MealSource.weeklyReservation,
          capturedAt: DateTime.utc(2026, 10, 18),
          dishName: 'زرشک پلو با مرغ',
          priceRial: 450000,
        ),
      );

      await tester.pumpWidget(
        wrap(ReservationsScreen(state: state, clock: clock)),
      );
      await tester.pumpAndSettle();

      // On current week: should see current week's meal, not next week's
      expect(find.text('قیمه بادمجان'), findsOneWidget);
      expect(find.text('زرشک پلو با مرغ'), findsNothing);

      // Tap next week (tooltip: هفته بعد)
      await tester.tap(find.byTooltip('هفته بعد'));
      await tester.pumpAndSettle();

      // Now on next week
      expect(find.text('هفته بعد'), findsOneWidget);
      expect(find.text('۲ الی ۸ آبان ۱۴۰۵'), findsOneWidget);
      expect(find.text('بازگشت به امروز'), findsOneWidget);

      // Should see next week's meal, current week's meal is gone
      expect(find.text('زرشک پلو با مرغ'), findsOneWidget);
      expect(find.text('قیمه بادمجان'), findsNothing);
    },
  );

  testWidgets(
    'free forward navigation allows advancing multiple weeks (+2, +3)',
    (tester) async {
      final state = await buildState();

      await tester.pumpWidget(
        wrap(ReservationsScreen(state: state, clock: clock)),
      );
      await tester.pumpAndSettle();

      // Advance to week +1
      await tester.tap(find.byTooltip('هفته بعد'));
      await tester.pumpAndSettle();
      expect(find.text('هفته بعد'), findsOneWidget);

      // Advance to week +2
      await tester.tap(find.byTooltip('هفته بعد'));
      await tester.pumpAndSettle();
      expect(find.text('۲ هفته بعد'), findsOneWidget);
      expect(find.text('۹ الی ۱۵ آبان ۱۴۰۵'), findsOneWidget);
      expect(
        find.text('برنامه غذایی این هفته هنوز ارائه نشده است'),
        findsOneWidget,
      );

      // Advance to week +3
      await tester.tap(find.byTooltip('هفته بعد'));
      await tester.pumpAndSettle();
      expect(find.text('۳ هفته بعد'), findsOneWidget);
    },
  );

  testWidgets(
    'free backward navigation inspects past weeks and resets to today',
    (tester) async {
      final state = await buildState();
      final accountId = state.accounts.first.id;

      // Meal held in last week (Monday 2026-10-12)
      state.mealStore.put(
        StoredMeal(
          accountId: accountId,
          date: DateTime.utc(2026, 10, 12),
          slot: MealSlot.lunch,
          source: MealSource.weeklyReservation,
          capturedAt: DateTime.utc(2026, 10, 11),
          dishName: 'قورمه سبزی',
          priceRial: 400000,
        ),
      );

      await tester.pumpWidget(
        wrap(ReservationsScreen(state: state, clock: clock)),
      );
      await tester.pumpAndSettle();

      // Initially current week does not show past meal
      expect(find.text('قورمه سبزی'), findsNothing);

      // Tap previous week (tooltip: هفته قبل)
      await tester.tap(find.byTooltip('هفته قبل'));
      await tester.pumpAndSettle();

      expect(find.text('هفته قبل'), findsOneWidget);
      expect(find.text('۱۸ الی ۲۴ مهر ۱۴۰۵'), findsOneWidget);
      expect(find.text('بازگشت به امروز'), findsOneWidget);
      expect(find.text('قورمه سبزی'), findsOneWidget);

      // Tap previous week again (-2 weeks)
      await tester.tap(find.byTooltip('هفته قبل'));
      await tester.pumpAndSettle();
      expect(find.text('۲ هفته قبل'), findsOneWidget);
      expect(find.text('هیچ رزروی در این هفته ثبت نشده است'), findsOneWidget);

      // Tap "بازگشت به امروز" to jump back to current week
      await tester.tap(find.text('بازگشت به امروز'));
      await tester.pumpAndSettle();

      expect(find.text('هفته جاری'), findsOneWidget);
      expect(find.text('۲۵ مهر الی ۱ آبان ۱۴۰۵'), findsOneWidget);
      expect(find.text('بازگشت به امروز'), findsNothing);
    },
  );
}
