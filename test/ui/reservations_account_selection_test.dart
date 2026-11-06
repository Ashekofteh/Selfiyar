import 'package:bahonar_nut/core/account_store.dart';
import 'package:bahonar_nut/core/local_meal_store.dart';
import 'package:bahonar_nut/core/meal_invariant.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/persian.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/screens/booking_sheet.dart';
import 'package:bahonar_nut/ui/screens/reservations_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrap(AppState state, Widget child) {
    return MaterialApp(
      locale: const Locale('fa', 'IR'),
      supportedLocales: const [Locale('fa', 'IR')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: child,
      ),
    );
  }

  testWidgets('ReservationsScreen displays account picker and switches between multiple accounts',
      (tester) async {
    final state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
      huntConfigStore: InMemoryHuntConfigStore(),
      mealStore: LocalMealStore(),
    );

    // Account 1: Ali (ID: 400111)
    await state.upsertAccount(studentId: '400111', alias: 'علی');
    // Account 2: Reza (ID: 400222)
    await state.upsertAccount(studentId: '400222', alias: 'رضا');
    await state.load();

    final acc1 = state.accounts[0].id;
    final acc2 = state.accounts[1].id;

    state.setBalance(acc1, 350000); // 35,000 Toman
    state.setBalance(acc2, 700000); // 70,000 Toman

    final date = DateTime.utc(2026, 10, 24);
    // Put meal for Ali
    state.mealStore.put(StoredMeal(
      accountId: acc1,
      date: date,
      slot: MealSlot.lunch,
      source: MealSource.weeklyReservation,
      capturedAt: date,
      dishName: 'چلو قرمه سبزی',
      hallName: 'مرکزی',
      priceRial: 350000,
    ));

    // Put meal for Reza
    state.mealStore.put(StoredMeal(
      accountId: acc2,
      date: date,
      slot: MealSlot.lunch,
      source: MealSource.weeklyReservation,
      capturedAt: date,
      dishName: 'زرشک پلو با مرغ',
      hallName: 'مرکزی',
      priceRial: 700000,
    ));

    final clock = FixedServerClock.now(DateTime.utc(2026, 10, 24, 12));

    AccountId? switchedAccount;
    await tester.pumpWidget(
      wrap(
        state,
        ReservationsScreen(
          state: state,
          clock: clock,
          onAccountChanged: (id) => switchedAccount = id,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify account picker is rendered
    expect(find.text('رزرو برای حساب:'), findsOneWidget);
    expect(find.textContaining('علی'), findsWidgets);
    expect(find.textContaining('رضا'), findsWidgets);

    // Initial account should show Ali's meal
    expect(find.text('چلو قرمه سبزی'), findsOneWidget);
    expect(find.text('زرشک پلو با مرغ'), findsNothing);

    // Tap Reza's chip to switch account
    await tester.tap(find.textContaining('رضا'));
    await tester.pumpAndSettle();

    // Verify callback was called with Reza's account ID
    expect(switchedAccount, acc2);
    expect(state.selectedReservationsAccountId, acc2);

    // Verify UI updated to show Reza's meal
    expect(find.text('زرشک پلو با مرغ'), findsOneWidget);
    expect(find.text('چلو قرمه سبزی'), findsNothing);
  });

  testWidgets('BookingSheet renders account badge when accountName is provided', (tester) async {
    final menu = MealMenu(
      date: DateTime.utc(2026, 10, 24),
      slot: MealSlot.lunch,
      halls: const [Hall(id: '1', name: 'مرکزی')],
      dishes: const [MenuOption(id: '10', name: 'چلو کباب', priceRial: 500000)],
      reservable: true,
    );

    await tester.pumpWidget(
      wrap(
        AppState(
          accountStore: InMemoryAccountStore(),
          reminderConfigStore: InMemoryReminderConfigStore(),
          huntConfigStore: InMemoryHuntConfigStore(),
        ),
        Scaffold(
          body: BookingSheet(
            menu: menu,
            accountName: 'شریفی',
            onBook: (_) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('شریفی'), findsOneWidget);
    expect(find.byIcon(Icons.person), findsOneWidget);
  });

  testWidgets(
      'ReservationsScreen maintains independent batch selection state per account',
      (tester) async {
    final state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
      huntConfigStore: InMemoryHuntConfigStore(),
      mealStore: LocalMealStore(),
    );

    await state.upsertAccount(studentId: '400111', alias: 'علی');
    await state.upsertAccount(studentId: '400222', alias: 'رضا');
    await state.load();

    final acc1 = state.accounts[0].id;
    final acc2 = state.accounts[1].id;

    state.setBalance(acc1, 500000); // 50,000 Toman
    state.setBalance(acc2, 300000); // 30,000 Toman

    final dateTue = DateTime.utc(2026, 10, 20);
    final dateWed = DateTime.utc(2026, 10, 21);

    final menus = [
      MealMenu(
        date: dateTue,
        slot: MealSlot.lunch,
        halls: const [Hall(id: '1', name: 'مرکزی')],
        dishes: const [MenuOption(id: '1', name: 'قورمه سبزی', priceRial: 300000)],
        reservable: true,
      ),
      MealMenu(
        date: dateWed,
        slot: MealSlot.lunch,
        halls: const [Hall(id: '1', name: 'مرکزی')],
        dishes: const [MenuOption(id: '2', name: 'قیمه', priceRial: 250000)],
        reservable: true,
      ),
    ];

    final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 12));

    await tester.pumpWidget(
      wrap(
        state,
        ReservationsScreen(
          state: state,
          clock: clock,
          menus: menus,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Initial view: Ali is active. Turn on multi-select.
    expect(find.byIcon(Icons.checklist_rtl), findsOneWidget);
    await tester.tap(find.byIcon(Icons.checklist_rtl));
    await tester.pumpAndSettle();

    // 2. Select Saturday meal for Ali
    expect(find.byType(Checkbox), findsWidgets);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();

    // Verify Ali's summary bar is visible with 1 meal
    expect(find.text('۱ وعده انتخاب شده'), findsOneWidget);
    expect(find.text('مجموع: ${formatTomanPersian(300000)}'), findsOneWidget);
    // Chip for Ali shows badge count: Ali (1)
    expect(find.textContaining('علی (۱)'), findsOneWidget);

    // 3. Switch to Reza
    await tester.tap(find.textContaining('رضا'));
    await tester.pumpAndSettle();

    // Reza's view is clean: not in selection mode, summary bar hidden
    expect(find.text('۱ وعده انتخاب شده'), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);
    expect(find.byIcon(Icons.checklist_rtl), findsOneWidget);
    // Ali's chip still shows (1) indicator!
    expect(find.textContaining('علی (۱)'), findsOneWidget);

    // 4. Activate selection mode for Reza and select Wednesday meal
    await tester.tap(find.byIcon(Icons.checklist_rtl));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).last);
    await tester.pumpAndSettle();

    // Reza's summary bar shows 1 meal with Reza's price (25,000 Toman)
    expect(find.text('۱ وعده انتخاب شده'), findsOneWidget);
    expect(find.text('مجموع: ${formatTomanPersian(250000)}'), findsOneWidget);
    expect(find.textContaining('رضا (۱)'), findsOneWidget);

    // 5. Switch back to Ali: Ali's selections and mode are preserved!
    await tester.tap(find.textContaining('علی'));
    await tester.pumpAndSettle();

    // Ali's summary bar shows 30,000 Toman, and selection mode is active
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.text('۱ وعده انتخاب شده'), findsOneWidget);
    expect(find.text('مجموع: ${formatTomanPersian(300000)}'), findsOneWidget);

    // 6. Switch back to Reza: Reza's selections are preserved!
    await tester.tap(find.textContaining('رضا'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.text('۱ وعده انتخاب شده'), findsOneWidget);
    expect(find.text('مجموع: ${formatTomanPersian(250000)}'), findsOneWidget);
  });
}
