import 'package:bahonar_nut/core/auth/account_store.dart';
import 'package:bahonar_nut/core/meal/local_meal_store.dart';
import 'package:bahonar_nut/core/meal/meal_invariant.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/finance/spend_summary.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/core/auth/session.dart';
import 'package:bahonar_nut/core/shared/time.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import '../helpers/memory_stores.dart';
import 'package:bahonar_nut/ui/features/accounts/accounts_screen.dart';
import 'package:bahonar_nut/ui/features/dashboard/dashboard_screen.dart';
import 'package:bahonar_nut/ui/features/reminders/reminders_screen.dart';
import 'package:bahonar_nut/ui/features/reservations/reservations_screen.dart';
import 'package:bahonar_nut/ui/theme/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// Screen-level tests: the screens must render, in Persian, with the right
/// content — including that every money figure is in **Toman**.
void main() {
  Future<AppState> buildState({
    List<Transaction> transactions = const [],
    bool withAccounts = true,
    MemorySecureStore? secureStore,
  }) async {
    final state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
      mealStore: LocalMealStore(),
      credentialStore: secureStore,
      transactions: transactions,
    );
    await state.load();

    if (withAccounts) {
      await state.upsertAccount(studentId: '400123456', alias: 'برادر');
      await state.upsertAccount(studentId: '401157013', alias: 'رضا');
    }
    return state;
  }

  /// Scrolls the screen until [text] is found.
  ///
  /// A `ListView` builds only the rows near the viewport, so content below the
  /// fold is genuinely absent from the tree — `find.text` cannot see it. These
  /// screens are long, so the test must scroll the way a user would.
  Future<void> scrollTo(
    WidgetTester tester,
    String text, {
    bool contains = false,
  }) async {
    final finder = contains
        ? find.textContaining(text)
        : find.text(text);
    for (var attempt = 0; attempt < 12; attempt++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.drag(find.byType(Scrollable).first,
          const Offset(0, -400));
      await tester.pumpAndSettle();
    }
  }

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

  group('the accounts screen', () {
    testWidgets('shows the empty state with no accounts', (tester) async {
      final state = await buildState(withAccounts: false);
      await tester.pumpWidget(wrap(state, AccountsScreen(state: state)));

      expect(find.text('حساب‌ها'), findsOneWidget);
      expect(find.text('هنوز حسابی اضافه نشده'), findsOneWidget);
      expect(find.text('افزودن حساب'), findsOneWidget);
    });

    testWidgets('lists accounts with their resolved names', (tester) async {
      final state = await buildState();
      await tester.pumpWidget(wrap(state, AccountsScreen(state: state)));

      expect(find.text('برادر'), findsOneWidget);
      expect(find.text('رضا'), findsOneWidget);
    });

    testWidgets('shows the student id and where the name came from',
        (tester) async {
      final state = await buildState();
      await tester.pumpWidget(wrap(state, AccountsScreen(state: state)));

      // The alias is in use, so the source line says so.
      await scrollTo(tester, '400123456', contains: true);
      expect(find.textContaining('400123456'), findsOneWidget);
      // Both accounts use an alias, so both subtitles say so.
      expect(find.textContaining('نام دلخواه'), findsNWidgets(2));
    });

    testWidgets('the add-account dialog opens', (tester) async {
      final state = await buildState(withAccounts: false);
      await tester.pumpWidget(wrap(state, AccountsScreen(state: state)));

      await tester.tap(find.text('افزودن حساب'));
      await tester.pumpAndSettle();

      expect(find.text('افزودن حساب'), findsWidgets);
      expect(find.text('شماره دانشجویی'), findsOneWidget);
      expect(find.text('نام دلخواه (اختیاری)'), findsOneWidget);
    });

    testWidgets('the edit dialog saves a typed password to the secure store',
        (tester) async {
      // The edit dialog's password field starts empty even in edit mode. A
      // non-empty value must reach the secure store — a silent drop would
      // leave the no-credentials warning standing while the user believes
      // they saved everything (F86: found on device, the red warning never
      // cleared after saving through the edit dialog).
      final secure = MemorySecureStore();
      final state = await buildState(secureStore: secure);
      await tester.pumpWidget(wrap(state, AccountsScreen(state: state)));

      // Open the edit dialog for the first account and type a password.
      final pencil = find.byIcon(Icons.edit_outlined).first;
      await tester.tap(pencil);
      await tester.pumpAndSettle();
      expect(find.text('ویرایش حساب'), findsOneWidget);

      await tester.enterText(
        find.byType(TextField).at(2),
        'pass-400123456',
      );
      await tester.tap(find.text('ذخیره'));
      await tester.pumpAndSettle();

      // The credentials landed in the secure store — not plain prefs, not
      // the account record.
      final accountId = state.accounts.first.id;
      final stored = await secure.read(accountId);
      expect(stored, isNotNull);
      expect(stored!.password, 'pass-400123456');
      expect(stored.studentId, '400123456');
      expect(await state.hasCredentials(accountId), isTrue);
    });

    testWidgets('an empty password field in the edit dialog leaves the '
        'stored credentials alone', (tester) async {
      final secure = MemorySecureStore();
      final state = await buildState(secureStore: secure);
      final accountId = state.accounts.first.id;
      await state.saveCredentials(
        accountId,
        const Credentials(studentId: '400123456', password: 'old-pass'),
      );
      await tester.pumpWidget(wrap(state, AccountsScreen(state: state)));
      expect(await secure.read(accountId), isNotNull);

      // Edit without touching the password field: the old password stays.
      await tester.tap(find.byIcon(Icons.edit_outlined).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('ذخیره'));
      await tester.pumpAndSettle();

      final stored = await secure.read(accountId);
      expect(stored!.password, 'old-pass');
    });
  });

  group('the dashboard', () {
    testWidgets('shows the empty state with no transactions', (tester) async {
      final state = await buildState();
      await tester.pumpWidget(wrap(state, DashboardScreen(state: state)));

      expect(find.text('هنوز تراکنشی ثبت نشده'), findsOneWidget);
    });

    testWidgets('shows totals in Toman, never Rial', (tester) async {
      final state = await buildState(transactions: [
        const Transaction(
          accountId: '400123456',
          type: 'رزرو غذا',
          foodName: 'چلو اکبرجوجه,دوغ',
          slot: MealSlot.lunch,
          weekday: 'سه شنبه',
          date: '1405/07/28',
          count: 1,
          amountRial: 500000,
        ),
      ]);
      await tester.pumpWidget(wrap(state, DashboardScreen(state: state)));

      // 500,000 Rial is 50,000 Toman.
      expect(find.textContaining('۵۰٬۰۰۰'), findsWidgets);
      expect(find.textContaining('تومان'), findsWidgets);
      expect(find.textContaining('ریال'), findsNothing);
    });

    testWidgets('shows the multi-select filters', (tester) async {
      final state = await buildState(transactions: [
        const Transaction(
          accountId: '400123456',
          type: 'رزرو غذا',
          foodName: 'چلو',
          slot: MealSlot.lunch,
          weekday: 'سه شنبه',
          date: '1405/07/28',
          count: 1,
          amountRial: 500000,
        ),
      ]);
      await tester.pumpWidget(wrap(state, DashboardScreen(state: state)));

      expect(find.text('فیلتر'), findsOneWidget);
      // The account chips.
      expect(find.widgetWithText(FilterChip, 'برادر'), findsOneWidget);
      // The slot chips.
      expect(find.widgetWithText(FilterChip, 'ناهار'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'صبحانه'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'شام'), findsOneWidget);
    });

    testWidgets('selecting a slot filters the total', (tester) async {
      final state = await buildState(transactions: [
        const Transaction(
          accountId: '400123456',
          type: 'رزرو غذا',
          foodName: 'چلو',
          slot: MealSlot.lunch,
          weekday: 'سه شنبه',
          date: '1405/07/28',
          count: 1,
          amountRial: 500000,
        ),
        const Transaction(
          accountId: '400123456',
          type: 'رزرو غذا',
          foodName: 'شیر',
          slot: MealSlot.breakfast,
          weekday: 'دوشنبه',
          date: '1405/07/27',
          count: 1,
          amountRial: 150000,
        ),
      ]);
      await tester.pumpWidget(wrap(state, DashboardScreen(state: state)));

      expect(state.spendSummary.totalRial, 650000);

      await tester.tap(find.widgetWithText(FilterChip, 'ناهار'));
      await tester.pumpAndSettle();

      expect(state.spendSummary.totalRial, 500000);
      expect(find.textContaining('۵۰٬۰۰۰'), findsWidgets);
    });

    testWidgets('selecting week period filters by week and enables week switching', (tester) async {
      // 1405/07/28 (2026-10-20) in current week (ref)
      // 1405/07/21 (2026-10-13) in previous week
      final state = await buildState(transactions: [
        const Transaction(
          accountId: '400123456',
          type: 'رزرو غذا',
          foodName: 'چلو',
          slot: MealSlot.lunch,
          weekday: 'سه شنبه',
          date: '1405/07/28',
          count: 1,
          amountRial: 500000,
        ),
        const Transaction(
          accountId: '400123456',
          type: 'رزرو غذا',
          foodName: 'شیر',
          slot: MealSlot.breakfast,
          weekday: 'سه شنبه',
          date: '1405/07/21',
          count: 1,
          amountRial: 150000,
        ),
      ]);
      state.setSpendReferenceDate(DateTime.utc(2026, 10, 20));

      await tester.pumpWidget(wrap(state, DashboardScreen(state: state)));
      expect(state.spendSummary.totalRial, 650000);

      // Select week filter
      await tester.scrollUntilVisible(find.widgetWithText(ChoiceChip, 'هفته'), 300);
      await tester.tap(find.widgetWithText(ChoiceChip, 'هفته'));
      await tester.pumpAndSettle();

      expect(state.spendFilter.periodType, SpendPeriodType.week);
      expect(state.spendSummary.totalRial, 500000);
      expect(find.text('هفته جاری'), findsWidgets);

      // Tap previous week chevron to switch weeks
      await tester.tap(find.byTooltip('هفته قبل'));
      await tester.pumpAndSettle();

      expect(state.spendFilter.weekOffset, -1);
      expect(state.spendSummary.totalRial, 150000);
      expect(find.text('هفته قبل'), findsWidgets);

      // Tap next week chevron to return to current week
      await tester.tap(find.byTooltip('هفته بعد'));
      await tester.pumpAndSettle();

      expect(state.spendFilter.weekOffset, 0);
      expect(state.spendSummary.totalRial, 500000);
    });

    testWidgets('selecting month period filters by month', (tester) async {
      final state = await buildState(transactions: [
        const Transaction(
          accountId: '400123456',
          type: 'رزرو غذا',
          foodName: 'چلو',
          slot: MealSlot.lunch,
          weekday: 'یکشنبه',
          date: '1405/08/03',
          count: 1,
          amountRial: 500000,
        ),
        const Transaction(
          accountId: '400123456',
          type: 'رزرو غذا',
          foodName: 'شیر',
          slot: MealSlot.breakfast,
          weekday: 'سه شنبه',
          date: '1405/07/28',
          count: 1,
          amountRial: 150000,
        ),
      ]);
      // Ref date in Mehr (1405/07/28)
      state.setSpendReferenceDate(DateTime.utc(2026, 10, 20));

      await tester.pumpWidget(wrap(state, DashboardScreen(state: state)));
      expect(state.spendSummary.totalRial, 650000);

      // Select month filter
      await tester.scrollUntilVisible(find.widgetWithText(ChoiceChip, 'ماه'), 300);
      await tester.tap(find.widgetWithText(ChoiceChip, 'ماه'));
      await tester.pumpAndSettle();

      expect(state.spendFilter.periodType, SpendPeriodType.month);
      // Mehr total is 150,000
      expect(state.spendSummary.totalRial, 150000);
      expect(find.text('ماه جاری'), findsWidgets);

      // Switch to next month (Aban)
      await tester.tap(find.byTooltip('ماه بعد'));
      await tester.pumpAndSettle();

      expect(state.spendFilter.monthOffset, 1);
      expect(state.spendSummary.totalRial, 500000);
    });
  });

  group('the reminders screen', () {
    testWidgets('shows the master switch and both slots', (tester) async {
      final state = await buildState();
      await tester.pumpWidget(wrap(state, RemindersScreen(state: state)));

      expect(find.text('فعال‌سازی یادآورها'), findsOneWidget);
      expect(find.text('یادآور ناهار'), findsOneWidget);
      expect(find.text('یادآور شام و صبحانه فردا'), findsOneWidget);
    });

    testWidgets('shows the default times in Persian', (tester) async {
      final state = await buildState();
      await tester.pumpWidget(wrap(state, RemindersScreen(state: state)));

      expect(find.text('۱۰:۳۰'), findsOneWidget);
      expect(find.text('۱۶:۳۰'), findsOneWidget);
    });

    testWidgets('turning the master switch off says so', (tester) async {
      final state = await buildState();
      await tester.pumpWidget(wrap(state, RemindersScreen(state: state)));

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(state.reminderConfig.masterEnabled, isFalse);
      expect(
        find.textContaining('همه یادآورها خاموش‌اند'),
        findsOneWidget,
      );
    });

    testWidgets('the live check is presented as off by default',
        (tester) async {
      final state = await buildState();
      await tester.pumpWidget(wrap(state, RemindersScreen(state: state)));

      await scrollTo(tester, 'بررسی آنلاین سامانه');
      expect(find.text('بررسی آنلاین سامانه'), findsOneWidget);
      await scrollTo(tester, 'خاموش (پیش‌فرض)');
      expect(find.text('خاموش (پیش‌فرض)'), findsOneWidget);
    });

    testWidgets('the live check switch can be toggled on and off',
        (tester) async {
      final state = await buildState();
      await tester.pumpWidget(wrap(state, RemindersScreen(state: state)));

      await scrollTo(tester, 'بررسی آنلاین سامانه');
      expect(find.text('بررسی آنلاین سامانه'), findsOneWidget);
      expect(find.text('خاموش (پیش‌فرض)'), findsOneWidget);

      final liveSyncCardFinder = find.ancestor(
        of: find.text('بررسی آنلاین سامانه'),
        matching: find.byType(SectionCard),
      );
      final liveSwitchFinder = find.descendant(
        of: liveSyncCardFinder,
        matching: find.byType(Switch),
      );
      expect(liveSwitchFinder, findsOneWidget);

      await tester.tap(liveSwitchFinder);
      await tester.pumpAndSettle();

      expect(state.reminderConfig.liveCheckEnabled, isTrue);
      expect(find.text('روشن (بررسی قبل از ارسال)'), findsOneWidget);

      await tester.tap(liveSwitchFinder);
      await tester.pumpAndSettle();

      expect(state.reminderConfig.liveCheckEnabled, isFalse);
      expect(find.text('خاموش (پیش‌فرض)'), findsOneWidget);
    });

    testWidgets('the next-week nudge has its own switch', (tester) async {
      final state = await buildState();
      await tester.pumpWidget(wrap(state, RemindersScreen(state: state)));

      await scrollTo(tester, 'یادآور رزرو هفته آینده');
      expect(find.text('یادآور رزرو هفته آینده'), findsOneWidget);
    });
  });

  group('the reservations screen', () {
    testWidgets('shows the empty state with no meals', (tester) async {
      final state = await buildState();
      await tester.pumpWidget(wrap(state, ReservationsScreen(state: state)));

      expect(find.text('هنوز وعده‌ای برای نمایش نیست'), findsOneWidget);
    });

    testWidgets('lists held meals by day with their prices in Toman',
        (tester) async {
      final state = await buildState();
      final accountId = state.accounts.first.id;
      state.mealStore.put(StoredMeal(
        accountId: accountId,
        date: DateTime.utc(2026, 10, 19),
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: DateTime.utc(2026, 10, 19),
        dishName: 'چلو اکبرجوجه,دوغ',
        hallName: 'مرکزی برادران',
        priceRial: 500000,
      ));

      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 19, 12));
      await tester.pumpWidget(
        wrap(state, ReservationsScreen(state: state, clock: clock)),
      );

      expect(find.text('چلو اکبرجوجه,دوغ'), findsOneWidget);
      expect(find.textContaining('مرکزی برادران'), findsOneWidget);
      // 500,000 Rial is 50,000 Toman.
      expect(find.textContaining('۵۰٬۰۰۰'), findsWidgets);
      expect(find.textContaining('ریال'), findsNothing);
    });
  });
}
