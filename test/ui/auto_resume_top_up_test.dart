import 'package:bahonar_nut/core/account_store.dart';
import 'package:bahonar_nut/core/local_meal_store.dart';
import 'package:bahonar_nut/core/meal_invariant.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/persian.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/core/top_up.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:bahonar_nut/platform/platform_services.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/home_shell.dart';
import 'package:bahonar_nut/ui/screens/booking_sheet.dart';
import 'package:bahonar_nut/ui/screens/meal_detail_sheet.dart';
import 'package:bahonar_nut/ui/screens/top_up_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/memory_stores.dart';
import '../helpers/portal_stubs.dart';

class _AutoResumeTrackingPortalClient extends FakePortalClient {
  _AutoResumeTrackingPortalClient({
    required List<MealMenu> menus,
    required this.bookableDays,
    this.initialBalanceRial = 100000,
  }) {
    this.menus = menus;
    balanceRial = initialBalanceRial;
  }

  final int initialBalanceRial;
  final Map<String, List<Reservation>> heldReservations = {};
  final List<DateTime> bookableDays;

  bool shouldFailReserve = false;
  String failReserveReason = 'ظرفیت این غذا تکمیل شده است.';
  int reserveCallCount = 0;
  int modifyCallCount = 0;

  @override
  Future<Session> refresh(Session session) async => session;

  @override
  Future<void> logout(Session session) async {}

  @override
  Future<DateTime> fetchServerTime(Session session) async =>
      DateTime.utc(2026, 10, 20, 12);

  @override
  Future<Balance> fetchBalance(Session session) async => Balance(
        amountRial: balanceRial,
        fetchedAt: DateTime.utc(2026, 10, 20, 12),
      );

  @override
  Future<BookableMenus> fetchBookableMenus(Session session, {int days = 7}) async {
    return BookableMenus(dates: bookableDays, menus: menus);
  }

  @override
  Future<List<Reservation>> fetchReservations(Session session) async {
    return heldReservations[session.account] ?? const [];
  }

  int? _creditedAmount;

  @override
  Future<Reservation> reserve(Session session, MealOffering offering) async {
    reserveCallCount++;
    if (shouldFailReserve) {
      throw Exception(failReserveReason);
    }
    final existingList = heldReservations[session.account];
    Reservation? existing;
    if (existingList != null) {
      for (final r in existingList) {
        if (r.date == offering.date && r.slot == offering.slot) {
          existing = r;
          break;
        }
      }
    }
    final diff = existing != null
        ? offering.option.priceRial - existing.option.priceRial
        : offering.option.priceRial;
    balanceRial -= diff;
    final res = Reservation(
      id: 'res_${DateTime.now().millisecondsSinceEpoch}',
      date: offering.date,
      slot: offering.slot,
      hall: offering.hall,
      option: offering.option,
      state: ReservationState.active,
    );
    final userList = heldReservations.putIfAbsent(session.account, () => []);
    userList.removeWhere(
      (r) => r.date == offering.date && r.slot == offering.slot,
    );
    userList.add(res);
    return res;
  }

  @override
  Future<TopUpPage> fetchTopUpPage(Session session) async => TopUpPage(
        balanceRial: balanceRial,
        banks: const [
          TopUpBank(
            id: r'ctl00$cphMain$dataLstBank$ctl00$imgBankLogo',
            name: 'درگاه سداد',
            logoPath: null,
          ),
        ],
        defaultAmountRial: balanceRial,
      );

  @override
  Future<Uri> beginTopUp(
    Session session,
    int amountRial,
    TopUpBank bank,
  ) async {
    topUpRequestedAmountRial = amountRial;
    topUpRequestedBank = bank;
    return Uri.parse('https://sadad.shaparak.ir/purchase?token=test_token_123');
  }

  @override
  Future<List<TopUpPayment>> fetchTopUpPayments(Session session) async {
    if (topUpRequestedAmountRial != null) {
      if (_creditedAmount != topUpRequestedAmountRial) {
        balanceRial += topUpRequestedAmountRial!;
        _creditedAmount = topUpRequestedAmountRial;
      }
      return [
        TopUpPayment(
          amountRial: topUpRequestedAmountRial!,
          status: TopUpStatus.paid,
        ),
      ];
    }
    return const [];
  }

  @override
  Future<List<TopUpPayment>> verifyTopUpPayment(Session session) async {
    if (topUpRequestedAmountRial != null) {
      if (_creditedAmount != topUpRequestedAmountRial) {
        balanceRial += topUpRequestedAmountRial!;
        _creditedAmount = topUpRequestedAmountRial;
      }
      return [
        TopUpPayment(
          amountRial: topUpRequestedAmountRial!,
          status: TopUpStatus.paid,
        ),
      ];
    }
    return const [];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final clock = FixedServerClock.now(DateTime.utc(2026, 10, 20, 12));
  final testDate = DateTime.utc(2026, 10, 22);

  const joojehOption = MenuOption(
    id: '101',
    name: 'چلو جوجه کباب',
    priceRial: 250000, // 25,000 Toman
  );

  const qormehOption = MenuOption(
    id: '102',
    name: 'چلوخورشت قیمه',
    priceRial: 150000, // 15,000 Toman
  );

  final lunchMenu = MealMenu(
    date: testDate,
    slot: MealSlot.lunch,
    halls: const [Hall(id: '1', name: 'مرکزی')],
    dishes: const [joojehOption, qormehOption],
    reservable: true,
  );

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

  testWidgets(
      'Single meal deficit directs to top-up, auto-resumes reservation on successful payment, and updates balance in real-time',
      (tester) async {
    final portal = _AutoResumeTrackingPortalClient(
      menus: [lunchMenu],
      bookableDays: [testDate],
      initialBalanceRial: 100000, // 10,000 Toman, deficit for Joojeh is 15,000 Toman (150,000 Rial)
    );

    final services = AppServices(
      bridge: PlatformBridge(),
      client: portal,
      sessions: SessionManager(
        client: portal,
        store: MemorySessionStore(),
        solver: NoSolver(),
        clock: clock,
      ),
      credentialStore: MemorySecureStore(),
      plainStore: MemoryPlainStore(),
      clock: clock,
    );

    final state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
      huntConfigStore: InMemoryHuntConfigStore(),
      mealStore: services.mealStore.store,
    );

    await state.upsertAccount(studentId: '400111', alias: 'آرمین');
    await state.load();
    final accountId = state.accounts.first.id;
    state.setBalance(accountId, 100000);

    await tester.pumpWidget(wrap(HomeShell(state: state, services: services)));
    await tester.pumpAndSettle();

    // 1. Check initial balance on Accounts screen: 10,000 Toman
    expect(find.text('اعتبار: ${formatTomanPersian(100000)}'), findsOneWidget);

    // 2. Go to Reservations tab
    await tester.tap(find.text('رزروها'));
    await tester.pumpAndSettle();

    // Refresh table from portal
    await tester.tap(find.byTooltip('به‌روزرسانی از سامانه'));
    await tester.pumpAndSettle();

    // Verify row is bookable and tap to book
    expect(find.byTooltip('رزرو این وعده'), findsOneWidget);
    await tester.tap(find.byTooltip('رزرو این وعده'));
    await tester.pumpAndSettle();

    // Verify BookingSheet opened
    expect(find.byType(BookingSheet), findsOneWidget);
    await tester.tap(find.text('چلو جوجه کباب'));
    await tester.pumpAndSettle();

    // Deficit banner is shown: 15,000 Toman
    expect(find.text('کسری موجودی: ${formatTomanPersian(150000)}'), findsOneWidget);
    expect(find.text('افزایش موجودی'), findsOneWidget);

    // Tap 'افزایش موجودی' from banner
    await tester.tap(find.text('افزایش موجودی'));
    await tester.pumpAndSettle();

    // 3. TopUpSheet should be opened with deficit prefilled (150,000 Rial)
    expect(find.byType(TopUpSheet), findsOneWidget);
    expect(find.text('پرداخت و افزایش اعتبار'), findsOneWidget);

    // Tap submit payment in TopUpSheet
    await tester.tap(find.text('پرداخت و افزایش اعتبار'));
    await tester.pumpAndSettle();

    // 4. TopUpGatewayScreen is displayed
    expect(find.text('تکمیل و ثبت نهایی در برنامه'), findsOneWidget);

    // Tap complete in gateway to simulate returning from shaparak
    await tester.tap(find.text('تکمیل و ثبت نهایی در برنامه'));
    await tester.pumpAndSettle();

    // 5. VERIFY AUTO-RESUME OF RESERVATION:
    // Portal reserve was called automatically!
    expect(portal.reserveCallCount, 1);

    // Success SnackBar is displayed naming the auto-reserved dish
    expect(
      find.text('پرداخت با موفقیت انجام شد و غذای «چلو جوجه کباب» به طور خودکار رزرو گردید.'),
      findsOneWidget,
    );

    // 6. VERIFY REAL-TIME BALANCE UPDATE:
    // 100,000 + 150,000 paid = 250,000 Rial.
    // Meal was reserved (-250,000 Rial), leaving 0 Rial balance.
    expect(state.balanceFor(accountId), 0);
    expect(find.text('اعتبار: ${formatTomanPersian(0)}'), findsWidgets);

    // Check Accounts tab confirms real-time balance
    await tester.tap(find.text('حساب‌ها'));
    await tester.pumpAndSettle();
    expect(find.text('اعتبار: ${formatTomanPersian(0)}'), findsOneWidget);
  });

  testWidgets(
      'Meal modification with deficit directs to top-up, auto-resumes modification on return, and updates balance',
      (tester) async {
    final portal = _AutoResumeTrackingPortalClient(
      menus: [lunchMenu],
      bookableDays: [testDate],
      initialBalanceRial: 50000, // 5,000 Toman
    );

    final services = AppServices(
      bridge: PlatformBridge(),
      client: portal,
      sessions: SessionManager(
        client: portal,
        store: MemorySessionStore(),
        solver: NoSolver(),
        clock: clock,
      ),
      credentialStore: MemorySecureStore(),
      plainStore: MemoryPlainStore(),
      clock: clock,
    );

    final state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
      huntConfigStore: InMemoryHuntConfigStore(),
      mealStore: services.mealStore.store,
    );

    await state.upsertAccount(studentId: '400111', alias: 'آرمین');
    await state.load();
    final accountId = state.accounts.first.id;
    state.setBalance(accountId, 50000);

    // Existing reservation: Qormeh (150,000 Rial)
    final existingRes = Reservation(
      id: 'res_existing',
      date: testDate,
      slot: MealSlot.lunch,
      hall: const Hall(id: '1', name: 'مرکزی'),
      option: qormehOption,
      state: ReservationState.active,
    );
    portal.heldReservations[accountId] = [existingRes];
    services.mealStore.store.put(StoredMeal(
      accountId: accountId,
      date: testDate,
      slot: MealSlot.lunch,
      source: MealSource.weeklyReservation,
      capturedAt: testDate,
      dishName: qormehOption.name,
      hallName: 'مرکزی',
      priceRial: qormehOption.priceRial,
    ));

    await tester.pumpWidget(wrap(HomeShell(state: state, services: services)));
    await tester.pumpAndSettle();

    // Go to Reservations tab
    await tester.tap(find.text('رزروها'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('به‌روزرسانی از سامانه'));
    await tester.pumpAndSettle();

    // Tap row to open MealDetailSheet
    await tester.tap(find.text('چلوخورشت قیمه'));
    await tester.pumpAndSettle();

    expect(find.byType(MealDetailSheet), findsOneWidget);

    // Select more expensive alternative dish (چلو جوجه کباب - 250,000 Rial, diff: +100,000 Rial)
    // Current balance: 50,000 Rial -> Deficit: 50,000 Rial
    await tester.tap(find.text('چلو جوجه کباب'));
    await tester.pumpAndSettle();

    expect(find.text('کسری موجودی: ${formatTomanPersian(50000)}'), findsOneWidget);
    expect(find.text('افزایش موجودی'), findsOneWidget);

    // Tap 'افزایش موجودی'
    await tester.tap(find.text('افزایش موجودی'));
    await tester.pumpAndSettle();

    // TopUpSheet should be opened with 50,000 Rial suggested
    expect(find.byType(TopUpSheet), findsOneWidget);
    await tester.tap(find.text('پرداخت و افزایش اعتبار'));
    await tester.pumpAndSettle();

    // Gateway screen is visible, tap complete
    expect(find.text('تکمیل و ثبت نهایی در برنامه'), findsOneWidget);
    await tester.tap(find.text('تکمیل و ثبت نهایی در برنامه'));
    await tester.pumpAndSettle();

    // VERIFY AUTO-RESUME OF MODIFICATION:
    expect(
      find.text('پرداخت با موفقیت انجام شد و تغییر غذا به «چلو جوجه کباب» به طور خودکار ثبت گردید.'),
      findsOneWidget,
    );

    // Check that table reflects updated dish
    expect(find.text('چلو جوجه کباب'), findsOneWidget);

    // Initial 50,000 + TopUp min 120,000 = 170,000. Price diff: 100,000 -> 70,000 Rial.
    expect(state.balanceFor(accountId), 70000);
  });

  testWidgets(
      'When meal capacity is exhausted during top-up, funds remain safe and clear notification is displayed',
      (tester) async {
    final portal = _AutoResumeTrackingPortalClient(
      menus: [lunchMenu],
      bookableDays: [testDate],
      initialBalanceRial: 100000,
    );

    final services = AppServices(
      bridge: PlatformBridge(),
      client: portal,
      sessions: SessionManager(
        client: portal,
        store: MemorySessionStore(),
        solver: NoSolver(),
        clock: clock,
      ),
      credentialStore: MemorySecureStore(),
      plainStore: MemoryPlainStore(),
      clock: clock,
    );

    final state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
      huntConfigStore: InMemoryHuntConfigStore(),
      mealStore: services.mealStore.store,
    );

    await state.upsertAccount(studentId: '400111', alias: 'آرمین');
    await state.load();
    final accountId = state.accounts.first.id;
    state.setBalance(accountId, 100000);

    await tester.pumpWidget(wrap(HomeShell(state: state, services: services)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('رزروها'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('به‌روزرسانی از سامانه'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('رزرو این وعده'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('چلو جوجه کباب'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('افزایش موجودی'));
    await tester.pumpAndSettle();

    expect(find.byType(TopUpSheet), findsOneWidget);
    await tester.tap(find.text('پرداخت و افزایش اعتبار'));
    await tester.pumpAndSettle();

    // SIMULATE CAPACITY EXHAUSTION DURING PAYMENT
    portal.shouldFailReserve = true;
    portal.failReserveReason = 'ظرفیت این غذا در حین پرداخت به پایان رسید.';

    await tester.tap(find.text('تکمیل و ثبت نهایی در برنامه'));
    await tester.pumpAndSettle();

    // Verify clear reassurance message: money is preserved, booking not made
    expect(
      find.textContaining('مبلغ پرداختی در حساب شما محفوظ است'),
      findsOneWidget,
    );

    // Verify balance was credited and not deducted (100,000 + 150,000 = 250,000 Rial)
    expect(state.balanceFor(accountId), 250000);
    expect(find.text('اعتبار: ${formatTomanPersian(250000)}'), findsWidgets);
  });

  group('PendingUserAction TTL and Clock Drift Tests', () {
    test('isExpired returns false within 15 minutes', () {
      final now = DateTime(2026, 10, 20, 12, 0);
      final action = PendingReserveOfferingsAction(
        accountId: 'acc1',
        createdAt: now,
        offerings: const [],
      );
      expect(action.isExpired(now.add(const Duration(minutes: 10))), isFalse);
    });

    test('isExpired returns true after 15 minutes', () {
      final now = DateTime(2026, 10, 20, 12, 0);
      final action = PendingReserveOfferingsAction(
        accountId: 'acc1',
        createdAt: now,
        offerings: const [],
      );
      expect(action.isExpired(now.add(const Duration(minutes: 15, seconds: 1))), isTrue);
    });

    test('isExpired treats backward clock shift > 1 minute as expired', () {
      final now = DateTime(2026, 10, 20, 12, 0);
      final action = PendingReserveOfferingsAction(
        accountId: 'acc1',
        createdAt: now,
        offerings: const [],
      );
      // Clock shifted backwards by 2 minutes
      expect(action.isExpired(now.subtract(const Duration(minutes: 2))), isTrue);
    });

    test('isExpired tolerates minor NTP backwards drift (< 1 minute)', () {
      final now = DateTime(2026, 10, 20, 12, 0);
      final action = PendingReserveOfferingsAction(
        accountId: 'acc1',
        createdAt: now,
        offerings: const [],
      );
      // Clock shifted backwards by 5 seconds
      expect(action.isExpired(now.subtract(const Duration(seconds: 5))), isFalse);
    });
  });

  testWidgets(
      'Payment failure or cancellation clears pending action and does not trigger on next top-up',
      (tester) async {
    final portal = _AutoResumeTrackingPortalClient(
      menus: [lunchMenu],
      bookableDays: [testDate],
      initialBalanceRial: 100000,
    );

    final services = AppServices(
      bridge: PlatformBridge(),
      client: portal,
      sessions: SessionManager(
        client: portal,
        store: MemorySessionStore(),
        solver: NoSolver(),
        clock: clock,
      ),
      credentialStore: MemorySecureStore(),
      plainStore: MemoryPlainStore(),
      clock: clock,
    );

    final state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
      huntConfigStore: InMemoryHuntConfigStore(),
      mealStore: services.mealStore.store,
    );

    await state.upsertAccount(studentId: '400111', alias: 'آرمین');
    await state.load();
    final accountId = state.accounts.first.id;
    state.setBalance(accountId, 100000);

    await tester.pumpWidget(wrap(HomeShell(state: state, services: services)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('رزروها'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('به‌روزرسانی از سامانه'));
    await tester.pumpAndSettle();

    // 1. Initiate booking with deficit
    await tester.tap(find.byTooltip('رزرو این وعده'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('چلو جوجه کباب'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('افزایش موجودی'));
    await tester.pumpAndSettle();

    // In TopUpSheet, cancel sheet by dismissing it
    Navigator.of(tester.element(find.byType(TopUpSheet))).pop();
    await tester.pumpAndSettle();

    // Verify booking was NOT made
    expect(portal.reserveCallCount, 0);

    // 2. Now user goes to Accounts and performs a normal top-up (not for booking)
    await tester.tap(find.text('حساب‌ها'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('افزایش اعتبار'));
    await tester.pumpAndSettle();

    // Enter 12,000 Toman (120,000 Rial)
    await tester.enterText(find.byType(TextField), '12000');
    await tester.pumpAndSettle();
    await tester.tap(find.text('پرداخت و افزایش اعتبار'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('تکمیل و ثبت نهایی در برنامه'));
    await tester.pumpAndSettle();

    // Verify that NO meal was auto-reserved because the previous pending action was cancelled
    expect(portal.reserveCallCount, 0);
    // Balance was credited only: 100,000 + 120,000 = 220,000 Rial
    expect(state.balanceFor(accountId), 220000);
  });

  testWidgets(
      'Meal modification auto-resumes when stored meal has null priceRial, using menu price for difference',
      (tester) async {
    final portal = _AutoResumeTrackingPortalClient(
      menus: [lunchMenu],
      bookableDays: [testDate],
      initialBalanceRial: 50000,
    );

    final services = AppServices(
      bridge: PlatformBridge(),
      client: portal,
      sessions: SessionManager(
        client: portal,
        store: MemorySessionStore(),
        solver: NoSolver(),
        clock: clock,
      ),
      credentialStore: MemorySecureStore(),
      plainStore: MemoryPlainStore(),
      clock: clock,
    );

    final state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
      huntConfigStore: InMemoryHuntConfigStore(),
      mealStore: services.mealStore.store,
    );

    await state.upsertAccount(studentId: '400111', alias: 'آرمین');
    await state.load();
    final accountId = state.accounts.first.id;
    state.setBalance(accountId, 50000);

    // Stored meal with priceRial = null!
    final existingRes = Reservation(
      id: 'res_existing',
      date: testDate,
      slot: MealSlot.lunch,
      hall: const Hall(id: '1', name: 'مرکزی'),
      option: qormehOption,
      state: ReservationState.active,
    );
    portal.heldReservations[accountId] = [existingRes];
    services.mealStore.store.put(StoredMeal(
      accountId: accountId,
      date: testDate,
      slot: MealSlot.lunch,
      source: MealSource.weeklyReservation,
      capturedAt: testDate,
      optionId: qormehOption.id,
      dishName: qormehOption.name,
      hallName: 'مرکزی',
      priceRial: null, // NULL price!
    ));

    await tester.pumpWidget(wrap(HomeShell(state: state, services: services)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('رزروها'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('به‌روزرسانی از سامانه'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('چلوخورشت قیمه'));
    await tester.pumpAndSettle();

    // Select Joojeh (250,000 Rial, diff should be 250,000 - 150,000 = 100,000 Rial)
    await tester.tap(find.text('چلو جوجه کباب'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('افزایش موجودی'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('پرداخت و افزایش اعتبار'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('تکمیل و ثبت نهایی در برنامه'));
    await tester.pumpAndSettle();

    // Verify modification succeeded
    expect(
      find.text('پرداخت با موفقیت انجام شد و تغییر غذا به «چلو جوجه کباب» به طور خودکار ثبت گردید.'),
      findsOneWidget,
    );
    // Initial 50,000 + TopUp min 120,000 = 170,000. Price diff 100,000 -> balance 70,000 Rial!
    expect(state.balanceFor(accountId), 70000);
  });
}
