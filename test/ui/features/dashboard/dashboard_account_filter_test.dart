import 'package:bahonar_nut/core/auth/account_store.dart';
import 'package:bahonar_nut/core/meal/local_meal_store.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/features/dashboard/dashboard_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Widget wrap(AppState state, Widget child) {
  return MaterialApp(
    locale: const Locale('fa', 'IR'),
    supportedLocales: const [Locale('fa', 'IR')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(body: child),
  );
}

void main() {
  group('Dashboard account filtering', () {
    testWidgets('filtering by account shows only selected account spend', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
        mealStore: LocalMealStore(),
      );
      await state.load();

      // Add two accounts
      await state.upsertAccount(studentId: '400123456', alias: 'اکانت اول');
      await state.upsertAccount(studentId: '401157013', alias: 'اکانت دوم');

      final acc1 = state.accounts.firstWhere((a) => a.studentId == '400123456');
      final acc2 = state.accounts.firstWhere((a) => a.studentId == '401157013');

      // Transactions can have accountId as studentId or account.id
      state.setTransactions([
        const Transaction(
          accountId: '400123456',
          type: 'رزرو غذا',
          foodName: 'چلو جوجه',
          slot: MealSlot.lunch,
          weekday: 'سه شنبه',
          date: '1405/07/28',
          count: 1,
          amountRial: 500000,
        ),
        const Transaction(
          accountId: '401157013',
          type: 'رزرو غذا',
          foodName: 'شیر و پنیر',
          slot: MealSlot.breakfast,
          weekday: 'دوشنبه',
          date: '1405/07/27',
          count: 1,
          amountRial: 150000,
        ),
      ]);

      await tester.pumpWidget(wrap(state, DashboardScreen(state: state)));
      await tester.pumpAndSettle();

      // Initially both are displayed
      expect(state.spendSummary.totalRial, 650000);
      expect(find.text('چلو جوجه'), findsOneWidget);
      expect(find.text('شیر و پنیر'), findsOneWidget);

      // Filter by first account
      await tester.tap(find.widgetWithText(FilterChip, 'اکانت اول'));
      await tester.pumpAndSettle();

      expect(state.spendFilter.accountIds.contains(acc1.id), isTrue);
      expect(state.spendSummary.totalRial, 500000);
      expect(find.text('چلو جوجه'), findsOneWidget);
      expect(find.text('شیر و پنیر'), findsNothing);

      // Deselect first account -> returns to all
      await tester.tap(find.widgetWithText(FilterChip, 'اکانت اول'));
      await tester.pumpAndSettle();

      expect(state.spendFilter.accountIds.isEmpty, isTrue);
      expect(state.spendSummary.totalRial, 650000);
      expect(find.text('چلو جوجه'), findsOneWidget);
      expect(find.text('شیر و پنیر'), findsOneWidget);

      // Filter by second account
      await tester.tap(find.widgetWithText(FilterChip, 'اکانت دوم'));
      await tester.pumpAndSettle();

      expect(state.spendFilter.accountIds.contains(acc2.id), isTrue);
      expect(state.spendSummary.totalRial, 150000);
      expect(find.text('چلو جوجه'), findsNothing);
      expect(find.text('شیر و پنیر'), findsOneWidget);

      // Select both accounts together
      await tester.tap(find.widgetWithText(FilterChip, 'اکانت اول'));
      await tester.pumpAndSettle();

      expect(state.spendSummary.totalRial, 650000);
      expect(find.text('چلو جوجه'), findsOneWidget);
      expect(find.text('شیر و پنیر'), findsOneWidget);
    });

    test('updateTransactionsForAccount replaces only target account transactions', () async {
      final state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
        mealStore: LocalMealStore(),
      );
      await state.load();

      await state.upsertAccount(studentId: '400123456', alias: 'اکانت اول');
      await state.upsertAccount(studentId: '401157013', alias: 'اکانت دوم');

      final acc1 = state.accounts.firstWhere((a) => a.studentId == '400123456');
      final acc2 = state.accounts.firstWhere((a) => a.studentId == '401157013');

      state.setTransactions([
        Transaction(
          accountId: acc1.id,
          type: 'رزرو غذا',
          foodName: 'چلو کباب',
          slot: MealSlot.lunch,
          weekday: 'سه شنبه',
          date: '1405/07/28',
          count: 1,
          amountRial: 600000,
        ),
        Transaction(
          accountId: acc2.id,
          type: 'رزرو غذا',
          foodName: 'املت',
          slot: MealSlot.dinner,
          weekday: 'دوشنبه',
          date: '1405/07/27',
          count: 1,
          amountRial: 200000,
        ),
      ]);

      expect(state.transactions.length, 2);

      // Update transactions for acc1 only
      state.updateTransactionsForAccount(acc1.id, [
        const Transaction(
          accountId: '400123456',
          type: 'رزرو غذا',
          foodName: 'چلو قرمه سبزی',
          slot: MealSlot.lunch,
          weekday: 'چهارشنبه',
          date: '1405/07/29',
          count: 1,
          amountRial: 550000,
        ),
      ]);

      // acc2's transaction should still be there!
      expect(state.transactions.length, 2);
      expect(state.transactions.any((t) => t.foodName == 'املت'), isTrue);
      expect(state.transactions.any((t) => t.foodName == 'چلو قرمه سبزی'), isTrue);
      expect(state.transactions.any((t) => t.foodName == 'چلو کباب'), isFalse);
    });
  });
}
