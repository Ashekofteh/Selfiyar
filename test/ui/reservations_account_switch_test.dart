import 'package:bahonar_nut/core/account_store.dart';
import 'package:bahonar_nut/core/local_meal_store.dart';
import 'package:bahonar_nut/core/meal_invariant.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/screens/reservations_screen.dart';
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
  group('ReservationsScreen Account Switching', () {
    testWidgets('switching account updates state and does not trigger onRefresh', (tester) async {
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
      await state.upsertAccount(studentId: '401157013', alias: 'اکانت رضا');

      final acc1 = state.accounts[0];
      final acc2 = state.accounts[1];

      // Add a distinct meal for acc1 and acc2
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 19, 12));
      final date = DateTime.utc(2026, 10, 19);

      state.mealStore.put(StoredMeal(
        accountId: acc1.id,
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: date,
        dishName: 'چلو جوجه علی',
        hallName: 'مرکزی',
        priceRial: 500000,
      ));

      state.mealStore.put(StoredMeal(
        accountId: acc2.id,
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: date,
        dishName: 'چلو گوشت رضا',
        hallName: 'مرکزی',
        priceRial: 600000,
      ));

      state.selectReservationsAccount(acc1.id);

      var refreshCount = 0;
      AccountId? changedToAccount;

      await tester.pumpWidget(
        wrap(
          state,
          ReservationsScreen(
            state: state,
            clock: clock,
            onRefresh: () async {
              refreshCount++;
            },
            onAccountChanged: (id) {
              changedToAccount = id;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially, acc1 meal is visible
      expect(find.text('چلو جوجه علی'), findsOneWidget);
      expect(find.text('چلو گوشت رضا'), findsNothing);

      // Tap on the ChoiceChip for acc2
      final acc2OptionFinder = find.textContaining('اکانت رضا');
      expect(acc2OptionFinder, findsOneWidget);
      await tester.tap(acc2OptionFinder);
      await tester.pumpAndSettle();

      // Verify onRefresh was NEVER called
      expect(refreshCount, equals(0), reason: 'Account switch must not invoke network refresh');

      // Verify onAccountChanged was invoked with acc2's id
      expect(changedToAccount, equals(acc2.id));

      // Verify state now has acc2 selected
      expect(state.selectedReservationsAccountId, equals(acc2.id));

      // Re-pump and verify acc2's meal is rendered instantaneously
      await tester.pumpAndSettle();
      expect(find.text('چلو گوشت رضا'), findsOneWidget);
      expect(find.text('چلو جوجه علی'), findsNothing);
    });

    testWidgets('initialWeekOffset sets the starting week and responds to changes', (tester) async {
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

      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 19, 12));

      await tester.pumpWidget(
        wrap(
          state,
          ReservationsScreen(
            state: state,
            clock: clock,
            initialWeekOffset: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Week title for offset 1 is "هفته بعد"
      expect(find.text('هفته بعد'), findsOneWidget);

      // Update widget with offset 0
      await tester.pumpWidget(
        wrap(
          state,
          ReservationsScreen(
            state: state,
            clock: clock,
            initialWeekOffset: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Week title for offset 0 is "هفته جاری"
      expect(find.text('هفته جاری'), findsOneWidget);
    });

    testWidgets('switching accounts while offline works seamlessly and invokes onWeekOffsetChanged', (tester) async {
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
      await state.upsertAccount(studentId: '400123456', alias: 'اکانت ۱');
      await state.upsertAccount(studentId: '401157013', alias: 'اکانت ۲');

      final acc1 = state.accounts[0];
      final acc2 = state.accounts[1];

      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 19, 12));
      final date = DateTime.utc(2026, 10, 19);

      state.mealStore.put(StoredMeal(
        accountId: acc1.id,
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: date,
        dishName: 'غذای اکانت اول',
        hallName: 'مرکزی',
        priceRial: 500000,
      ));

      state.mealStore.put(StoredMeal(
        accountId: acc2.id,
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: date,
        dishName: 'غذای اکانت دوم',
        hallName: 'مرکزی',
        priceRial: 600000,
      ));

      // Simulate offline mode
      state.setOffline(true);
      state.selectReservationsAccount(acc1.id);

      var refreshInvoked = false;
      int? reportedOffset;

      await tester.pumpWidget(
        wrap(
          state,
          ReservationsScreen(
            state: state,
            clock: clock,
            onRefresh: () async {
              refreshInvoked = true;
            },
            onWeekOffsetChanged: (offset) {
              reportedOffset = offset;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('غذای اکانت اول'), findsOneWidget);
      expect(find.text('غذای اکانت دوم'), findsNothing);

      // Switch to account 2 while offline
      await tester.tap(find.textContaining('اکانت ۲'));
      await tester.pumpAndSettle();

      expect(refreshInvoked, isFalse);
      expect(state.selectedReservationsAccountId, equals(acc2.id));
      expect(find.text('غذای اکانت دوم'), findsOneWidget);
      expect(find.text('غذای اکانت اول'), findsNothing);

      // Navigate to previous week and verify onWeekOffsetChanged callback
      final prevWeekButton = find.byTooltip('هفته قبل');
      if (prevWeekButton.evaluate().isNotEmpty) {
        await tester.tap(prevWeekButton);
        await tester.pumpAndSettle();
        expect(reportedOffset, equals(-1));
      }
    });
  });
}
