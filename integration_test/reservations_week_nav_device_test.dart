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
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('verifies week navigation controls and week labels on device', (
    tester,
  ) async {
    final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 12));
    final state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
      mealStore: LocalMealStore(),
    );
    await state.load();
    await state.upsertAccount(studentId: '400123456', alias: 'آرمین');
    final accountId = state.accounts.first.id;

    // Put a current week meal
    state.mealStore.put(
      StoredMeal(
        accountId: accountId,
        date: DateTime.utc(2026, 10, 19),
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: DateTime.utc(2026, 10, 18),
        dishName: 'چلو جوجه کباب',
        priceRial: 400000,
      ),
    );

    // Put a next week meal
    state.mealStore.put(
      StoredMeal(
        accountId: accountId,
        date: DateTime.utc(2026, 10, 26),
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: DateTime.utc(2026, 10, 18),
        dishName: 'چلو کباب کوبیده',
        priceRial: 450000,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('fa', 'IR'),
        supportedLocales: const [Locale('fa', 'IR')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: ReservationsScreen(state: state, clock: clock),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Current week is shown
    expect(find.text('هفته جاری'), findsOneWidget);
    expect(find.text('۲۵ مهر الی ۱ آبان ۱۴۰۵'), findsOneWidget);
    expect(find.text('چلو جوجه کباب'), findsOneWidget);
    expect(find.text('چلو کباب کوبیده'), findsNothing);

    // 2. Navigate to next week
    await tester.tap(find.byTooltip('هفته بعد'));
    await tester.pumpAndSettle();

    expect(find.text('هفته بعد'), findsOneWidget);
    expect(find.text('۲ الی ۸ آبان ۱۴۰۵'), findsOneWidget);
    expect(find.text('چلو کباب کوبیده'), findsOneWidget);
    expect(find.text('چلو جوجه کباب'), findsNothing);

    // 3. Free forward navigation (+2 weeks)
    await tester.tap(find.byTooltip('هفته بعد'));
    await tester.pumpAndSettle();
    expect(find.text('۲ هفته بعد'), findsOneWidget);

    // 4. Return to current week
    await tester.tap(find.text('بازگشت به امروز'));
    await tester.pumpAndSettle();
    expect(find.text('هفته جاری'), findsOneWidget);
    expect(find.text('چلو جوجه کباب'), findsOneWidget);

    // 5. Navigate to past week
    await tester.tap(find.byTooltip('هفته قبل'));
    await tester.pumpAndSettle();
    expect(find.text('هفته قبل'), findsOneWidget);
    expect(find.text('۱۸ الی ۲۴ مهر ۱۴۰۵'), findsOneWidget);
  });
}
