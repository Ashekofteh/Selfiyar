import 'package:bahonar_nut/core/account_store.dart';
import 'package:bahonar_nut/core/local_meal_store.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/platform_stores.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/screens/dashboard_screen.dart';
import 'package:bahonar_nut/ui/widgets/offline_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/memory_stores.dart';

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
  group('Transaction serialization & persistence round-trip', () {
    test('encodeTransactionList and decodeTransactionList round-trip all fields', () {
      final original = [
        const Transaction(
          accountId: 'acc-1',
          type: 'رزرو غذا',
          foodName: 'چلو قورمه سبزی',
          slot: MealSlot.lunch,
          weekday: 'شنبه',
          date: '1405/08/01',
          count: 1,
          amountRial: 500000,
        ),
        const Transaction(
          accountId: 'acc-2',
          type: 'خرید از سبد',
          foodName: 'زرشک پلو',
          slot: MealSlot.dinner,
          weekday: 'یکشنبه',
          date: '1405/08/02',
          count: 2,
          amountRial: 1200000,
        ),
      ];

      final encoded = encodeTransactionList(original);
      final decoded = decodeTransactionList(encoded);

      expect(decoded.length, original.length);
      for (var i = 0; i < original.length; i++) {
        expect(decoded[i].accountId, original[i].accountId);
        expect(decoded[i].type, original[i].type);
        expect(decoded[i].foodName, original[i].foodName);
        expect(decoded[i].slot, original[i].slot);
        expect(decoded[i].weekday, original[i].weekday);
        expect(decoded[i].date, original[i].date);
        expect(decoded[i].count, original[i].count);
        expect(decoded[i].amountRial, original[i].amountRial);
      }
    });

    test('decodeTransactionList handles malformed and invalid data gracefully', () {
      expect(decodeTransactionList(''), isEmpty);
      expect(decodeTransactionList('bad json'), isEmpty);
      expect(decodeTransactionList('{"not": "a list"}'), isEmpty);
      expect(decodeTransactionList('[123, "string", null]'), isEmpty);
    });
  });

  group('28-Day Retention Policy (pruneTransactions)', () {
    test('pruneTransactions retains records within 28 days and prunes older ones', () {
      // Reference date: 1405/08/10 (approx Nov 2026)
      // 1405/08/05 is 5 days old -> keep
      // 1405/07/20 is 20 days old -> keep
      // 1405/06/01 is > 60 days old -> prune
      final now = DateTime.utc(2026, 10, 31); // 1405/08/10
      final txList = [
        const Transaction(
          accountId: 'a1',
          type: 'رزرو',
          foodName: 'غذا ۱',
          slot: MealSlot.lunch,
          weekday: 'شنبه',
          date: '1405/08/05',
          count: 1,
          amountRial: 500000,
        ),
        const Transaction(
          accountId: 'a1',
          type: 'رزرو',
          foodName: 'غذا ۲',
          slot: MealSlot.dinner,
          weekday: 'دوشنبه',
          date: '1405/07/20',
          count: 1,
          amountRial: 500000,
        ),
        const Transaction(
          accountId: 'a1',
          type: 'رزرو',
          foodName: 'غذای خیلی قدیمی',
          slot: MealSlot.lunch,
          weekday: 'جمعه',
          date: '1405/06/01',
          count: 1,
          amountRial: 500000,
        ),
      ];

      final pruned = AppState.pruneTransactions(txList, now, retentionDays: 28);
      expect(pruned.length, 2);
      expect(pruned.any((t) => t.foodName == 'غذای خیلی قدیمی'), isFalse);
    });
  });

  group('AppState Offline Financial Loading & Account Cleanup', () {
    test('AppState.load() loads persisted transactions from plainStore', () async {
      final plainStore = MemoryPlainStore();
      final List<Transaction> initialTx = [
        const Transaction(
          accountId: 'stored-acc',
          type: 'رزرو غذا',
          foodName: 'چلو کباب',
          slot: MealSlot.lunch,
          weekday: 'شنبه',
          date: '1405/08/01',
          count: 1,
          amountRial: 700000,
        ),
      ];
      await plainStore.writeString(StoreKeys.transactions, encodeTransactionList(initialTx));

      final state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
        mealStore: LocalMealStore(),
        plainStore: plainStore,
      );

      expect(state.transactions, isEmpty);
      await state.load();
      expect(state.transactions.length, 1);
      expect(state.transactions.first.foodName, 'چلو کباب');
      expect(state.transactions.first.amountRial, 700000);
    });

    test('removeAccount() removes all transactions for the deleted account and updates persistence', () async {
      final plainStore = MemoryPlainStore();
      final state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
        mealStore: LocalMealStore(),
        plainStore: plainStore,
      );
      await state.load();

      await state.upsertAccount(studentId: '400123456', alias: 'اکانت ۱');
      final acc = state.accounts.first;

      state.updateTransactionsForAccount(acc.id, [
        Transaction(
          accountId: acc.id,
          type: 'رزرو غذا',
          foodName: 'قورمه سبزی',
          slot: MealSlot.lunch,
          weekday: 'شنبه',
          date: '1405/08/01',
          count: 1,
          amountRial: 500000,
        ),
      ]);
      expect(state.transactions.length, 1);

      // Verify written to plainStore
      final storedRaw = await plainStore.readString(StoreKeys.transactions);
      expect(storedRaw, isNotNull);
      expect(decodeTransactionList(storedRaw!).length, 1);

      // Now remove the account
      await state.removeAccount(acc.id);
      expect(state.transactions, isEmpty);

      // Verify plainStore is pruned as well
      final updatedRaw = await plainStore.readString(StoreKeys.transactions);
      expect(decodeTransactionList(updatedRaw ?? '').isEmpty, isTrue);
    });
  });

  group('DashboardScreen Offline UI Rendering', () {
    testWidgets('displays OfflineBanner and renders persisted transactions offline', (tester) async {
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

      await state.upsertAccount(studentId: '400123456', alias: 'اکانت علی');
      final acc = state.accounts.first;

      state.setTransactions([
        Transaction(
          accountId: acc.id,
          type: 'رزرو غذا',
          foodName: 'چلو قورمه سبزی خوشمزه',
          slot: MealSlot.lunch,
          weekday: 'شنبه',
          date: '1405/08/01',
          count: 1,
          amountRial: 500000,
        ),
      ]);

      // Set offline mode
      state.setOffline(true);

      await tester.pumpWidget(wrap(state, DashboardScreen(state: state)));
      await tester.pumpAndSettle();

      // Offline banner should be present and visible
      expect(find.byType(OfflineBanner), findsOneWidget);
      expect(find.textContaining('حالت آفلاین'), findsOneWidget);

      // Financial transaction information should be rendered even though offline
      expect(find.text('چلو قورمه سبزی خوشمزه'), findsOneWidget);
      expect(find.text('هنوز تراکنشی ثبت نشده'), findsNothing);
    });

    testWidgets('supports pull-to-refresh via onRefresh when provided', (tester) async {
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
      await state.upsertAccount(studentId: '400123456', alias: 'اکانت علی');
      final acc = state.accounts.first;

      state.setTransactions([
        Transaction(
          accountId: acc.id,
          type: 'رزرو غذا',
          foodName: 'چلو جوجه',
          slot: MealSlot.lunch,
          weekday: 'شنبه',
          date: '1405/08/01',
          count: 1,
          amountRial: 500000,
        ),
      ]);

      var refreshCalled = false;
      await tester.pumpWidget(
        wrap(
          state,
          DashboardScreen(
            state: state,
            onRefresh: () async {
              refreshCalled = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(RefreshIndicator), findsOneWidget);
      // ignore: unawaited_futures
      tester.state<RefreshIndicatorState>(find.byType(RefreshIndicator)).show();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(refreshCalled, isTrue);
    });
  });
}
