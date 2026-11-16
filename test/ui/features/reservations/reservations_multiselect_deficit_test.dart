import 'package:bahonar_nut/core/auth/account_store.dart';
import 'package:bahonar_nut/core/meal/local_meal_store.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/shared/persian.dart';
import 'package:bahonar_nut/core/shared/time.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/features/reservations/reservations_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Sunday, 2026-10-18 12:00 UTC.
  // Tuesday (2026-10-20) cutoff is Sunday 20:00 -> reservable.
  // Wednesday (2026-10-21) cutoff is Monday 20:00 -> reservable.
  final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 12));

  Future<AppState> buildState({int initialBalance = 150000}) async {
    final state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
      mealStore: LocalMealStore(),
    );
    await state.load();
    await state.upsertAccount(studentId: '400123456', alias: 'آرمین');
    final accountId = state.accounts.first.id;
    state.setBalance(accountId, initialBalance); // 15,000 Toman
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
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: child,
      ),
    );
  }

  final tuesday = DateTime.utc(2026, 10, 20);
  final wednesday = DateTime.utc(2026, 10, 21);

  final testMenus = [
    MealMenu(
      date: tuesday,
      slot: MealSlot.lunch,
      halls: const [Hall(id: '1', name: 'سلف مرکزی')],
      dishes: const [
        MenuOption(id: '101', name: 'چلو قورمه سبزی', priceRial: 200000), // 20,000 Toman
      ],
      reservable: true,
    ),
    MealMenu(
      date: wednesday,
      slot: MealSlot.lunch,
      halls: const [Hall(id: '1', name: 'سلف مرکزی')],
      dishes: const [
        MenuOption(id: '102', name: 'زرشک پلو با مرغ', priceRial: 250000), // 25,000 Toman
      ],
      reservable: true,
    ),
  ];

  testWidgets(
      'ReservationsScreen multi-select computes total and detects deficit when balance is low',
      (tester) async {
    final state = await buildState(initialBalance: 150000); // 15,000 Toman
    int? capturedDeficit;

    await tester.pumpWidget(
      wrap(
        ReservationsScreen(
          state: state,
          clock: clock,
          menus: testMenus,
          onTopUp: (deficit, {pendingRows}) {
            capturedDeficit = deficit;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Tap multi-select icon
    final selectToggle = find.byIcon(Icons.checklist_rtl);
    expect(selectToggle, findsOneWidget);
    await tester.tap(selectToggle);
    await tester.pumpAndSettle();

    // Checkboxes should appear for the 2 bookable rows
    final checkboxes = find.byType(Checkbox);
    expect(checkboxes, findsNWidgets(2));

    // Select the first meal (200,000 Rial) -> Balance is 150,000 Rial -> Deficit is 50,000 Rial (5,000 Toman)
    await tester.tap(checkboxes.first);
    await tester.pumpAndSettle();

    expect(find.text('کسری موجودی: ${formatTomanPersian(50000)}'), findsOneWidget);
    expect(find.text('شارژ حساب (${formatTomanPersian(50000)})'), findsOneWidget);

    // Select second meal (250,000 Rial) -> Total 450,000 Rial -> Deficit is 300,000 Rial (30,000 Toman)
    await tester.tap(checkboxes.at(1));
    await tester.pumpAndSettle();

    expect(find.text('کسری موجودی: ${formatTomanPersian(300000)}'), findsOneWidget);
    expect(find.text('شارژ حساب (${formatTomanPersian(300000)})'), findsOneWidget);

    // Tap on increase balance button
    await tester.tap(find.text('شارژ حساب (${formatTomanPersian(300000)})'));
    await tester.pumpAndSettle();

    expect(capturedDeficit, 300000);
  });
}
