import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bahonar_nut/core/account_store.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:bahonar_nut/platform/platform_services.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/home_shell.dart';
import 'package:bahonar_nut/ui/screens/captcha_dialog.dart';
import 'package:bahonar_nut/ui/widgets/rotating_refresh_button.dart';

import '../helpers/memory_stores.dart';
import '../helpers/portal_stubs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final clock = FixedServerClock.now(DateTime.utc(2026, 10, 20, 12));

  testWidgets('parallel sync executes multiple accounts concurrently',
      (tester) async {
    final portal = ConcurrentTrackingPortalClient();

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

    await state.upsertAccount(studentId: '400111111');
    await state.upsertAccount(studentId: '400222222');
    await state.load();

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
          child: HomeShell(state: state, services: services),
        ),
      ),
    );

    // Auto-refresh on startup runs. Wait for it to settle.
    await tester.pumpAndSettle();

    // Reset tracking counters before manual refresh test
    portal.resetCounters();

    // Trigger refresh from portal
    final refreshFinder = find.byType(RotatingRefreshButton).first;
    await tester.tap(refreshFinder);

    // Pump multiple small frames so simulated delays advance while running concurrently
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    await tester.pumpAndSettle();

    // Verify that at least 2 requests executed concurrently at the same time
    expect(portal.maxConcurrentRequests, greaterThanOrEqualTo(2),
        reason: 'Multiple accounts must be fetched in parallel concurrently');
  });

  testWidgets('parallel sync preserves isolated data and session independence',
      (tester) async {
    final portal = DataIsolatingPortalClient();

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

    await state.upsertAccount(studentId: '400111111');
    await state.upsertAccount(studentId: '400222222');
    await state.load();
    final acc1 = state.accounts[0];
    final acc2 = state.accounts[1];

    // Pre-configure distinct responses for each account
    portal.accountData[acc1.id] = AccountTestData(
      balanceRial: 1200000,
      profileName: 'علی محمدی',
      reservations: [
        Reservation(
          id: 'res-acc1',
          date: DateTime.utc(2026, 10, 21),
          slot: MealSlot.lunch,
          hall: const Hall(id: '1', name: 'مرکزی'),
          option: const MenuOption(id: '101', name: 'چلو قورمه سبزی', priceRial: 400000),
          state: ReservationState.active,
        ),
      ],
    );

    portal.accountData[acc2.id] = AccountTestData(
      balanceRial: 3500000,
      profileName: 'رضا کریمی',
      reservations: [
        Reservation(
          id: 'res-acc2',
          date: DateTime.utc(2026, 10, 22),
          slot: MealSlot.dinner,
          hall: const Hall(id: '2', name: 'یاس'),
          option: const MenuOption(id: '102', name: 'چلو قیمه', priceRial: 450000),
          state: ReservationState.active,
        ),
      ],
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
          child: HomeShell(state: state, services: services),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify balances were updated independently without crosstalk
    expect(state.balanceFor(acc1.id), equals(1200000));
    expect(state.balanceFor(acc2.id), equals(3500000));

    // Verify profile names were updated independently
    expect(state.accounts.firstWhere((a) => a.id == acc1.id).profileName, equals('علی محمدی'));
    expect(state.accounts.firstWhere((a) => a.id == acc2.id).profileName, equals('رضا کریمی'));

    // Verify mealStore isolated meals for both accounts without clobbering
    final mealsAcc1 = state.mealsFor(acc1.id);
    final mealsAcc2 = state.mealsFor(acc2.id);

    expect(mealsAcc1, hasLength(1));
    expect(mealsAcc1.first.dishName, equals('چلو قورمه سبزی'));
    expect(mealsAcc1.first.accountId, equals(acc1.id));

    expect(mealsAcc2, hasLength(1));
    expect(mealsAcc2.first.dishName, equals('چلو قیمه'));
    expect(mealsAcc2.first.accountId, equals(acc2.id));

    expect(services.mealStore.store.count, equals(2),
        reason: 'Meal store must retain both accounts meals concurrently');
  });

  testWidgets('startup auto-refresh runs non-blocking and smoothly eases out',
      (tester) async {
    final portal = ConcurrentTrackingPortalClient();

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

    await state.upsertAccount(studentId: '400333333');
    await state.load();
    final acc = state.accounts.first;

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
          child: HomeShell(state: state, services: services),
        ),
      ),
    );

    // First frame: UI is immediately displayed from cache, no blocking full-screen overlay
    expect(find.byType(HomeShell), findsOneWidget);
    expect(find.text('حساب‌ها'), findsWidgets);

    // Settle all background auto-refresh operations
    await tester.pumpAndSettle();

    // Verify balance is refreshed automatically without user tapping anything
    expect(state.balanceFor(acc.id), equals(500000));
    expect(state.isSyncing, isFalse);
  });

  testWidgets('re-entrancy guard prevents duplicate refresh while one is in flight',
      (tester) async {
    final portal = ConcurrentTrackingPortalClient();

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

    await state.upsertAccount(studentId: '400111111');
    await state.load();

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
          child: HomeShell(state: state, services: services),
        ),
      ),
    );
    await tester.pumpAndSettle();

    portal.resetCounters();

    // Tap refresh
    final refreshFinder = find.byType(RotatingRefreshButton).first;
    await tester.tap(refreshFinder);

    // Immediate second tap while syncing flag is true and in-flight
    await tester.tap(refreshFinder);

    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(portal.maxConcurrentBalanceRequests, equals(1),
        reason: 'Re-entrancy guard must prevent duplicate overlapping refreshes');
    expect(portal.totalBalanceRequests, equals(1),
        reason: 'Second tap must be ignored by re-entrancy guard');
  });

  testWidgets('parallel sync refreshes weekly table menu concurrently with accounts',
      (tester) async {
    final portal = ConcurrentTrackingPortalClient();

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

    await state.upsertAccount(studentId: '400111111');
    await state.upsertAccount(studentId: '400222222');
    await state.load();

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
          child: HomeShell(state: state, services: services),
        ),
      ),
    );
    await tester.pumpAndSettle();

    portal.resetCounters();

    // Trigger manual refresh
    final refreshFinder = find.byType(RotatingRefreshButton).first;
    await tester.tap(refreshFinder);

    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    await tester.pumpAndSettle();

    // Accounts + Table menu were queried concurrently (total concurrent requests >= 2)
    expect(portal.maxConcurrentRequests, greaterThanOrEqualTo(2));
    expect(portal.bookableMenuReads, greaterThanOrEqualTo(1));
  });

  testWidgets('tapping refresh on reservations screen triggers parallel refresh of accounts and table menu',
      (tester) async {
    final portal = ConcurrentTrackingPortalClient();

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

    await state.upsertAccount(studentId: '400111111');
    await state.upsertAccount(studentId: '400222222');
    await state.load();
    final acc1 = state.accounts[0];
    final acc2 = state.accounts[1];

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
          child: HomeShell(state: state, services: services),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Switch to reservations tab
    await tester.tap(find.text('رزروها'));
    await tester.pumpAndSettle();

    portal.resetCounters();

    // Tap RotatingRefreshButton on ReservationsScreen
    final refreshFinder = find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(RotatingRefreshButton),
    );
    expect(refreshFinder, findsOneWidget);
    await tester.tap(refreshFinder);

    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    await tester.pumpAndSettle();

    // Both accounts refreshed and table menu loaded
    expect(portal.bookableMenuReads, greaterThanOrEqualTo(1));
    expect(state.balanceFor(acc1.id), equals(500000));
    expect(state.balanceFor(acc2.id), equals(500000));
    expect(find.text('قابل رزرو'), findsOneWidget);
  });

  testWidgets('partial failure on one account preserves existing transactions of other accounts',
      (tester) async {
    final portal = DataIsolatingPortalClient();

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

    await state.upsertAccount(studentId: '400111111');
    await state.upsertAccount(studentId: '400222222');
    await state.load();
    final acc1 = state.accounts[0];
    final acc2 = state.accounts[1];

    // Pre-populate state with transactions for both accounts
    state.setTransactions([
      Transaction(
        accountId: acc1.id,
        type: 'رزرو غذا',
        foodName: 'عدس پلو',
        slot: MealSlot.lunch,
        weekday: 'دوشنبه',
        date: '1405/07/20',
        count: 1,
        amountRial: 200000,
      ),
      Transaction(
        accountId: acc2.id,
        type: 'رزرو غذا',
        foodName: 'زرشک پلو',
        slot: MealSlot.lunch,
        weekday: 'سه شنبه',
        date: '1405/07/21',
        count: 1,
        amountRial: 300000,
      ),
    ]);

    // acc1 succeeds with fresh transactions; acc2 fails
    portal.accountData[acc1.id] = AccountTestData(
      balanceRial: 800000,
      profileName: 'دانشجوی یک',
      reservations: const [],
      transactions: [
        Transaction(
          accountId: acc1.id,
          type: 'رزرو غذا',
          foodName: 'چلو قورمه',
          slot: MealSlot.lunch,
          weekday: 'چهارشنبه',
          date: '1405/07/22',
          count: 1,
          amountRial: 250000,
        ),
      ],
    );

    portal.failAccount = acc2.id;

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
          child: HomeShell(state: state, services: services),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Trigger manual refresh
    final refreshFinder = find.byType(RotatingRefreshButton).first;
    await tester.tap(refreshFinder);
    await tester.pumpAndSettle();

    // acc1 transactions updated to fresh data
    final acc1Tx = state.transactions.where((t) => t.accountId == acc1.id).toList();
    expect(acc1Tx, hasLength(1));
    expect(acc1Tx.first.foodName, equals('چلو قورمه'));

    // acc2 transactions MUST NOT have been wiped out by the partial sync!
    final acc2Tx = state.transactions.where((t) => t.accountId == acc2.id).toList();
    expect(acc2Tx, hasLength(1));
    expect(acc2Tx.first.foodName, equals('زرشک پلو'));
  });

  testWidgets('multiple accounts needing CAPTCHA are serialized via mutex and suppressed on startup',
      (tester) async {
    final portal = _MultiAccountCaptchaPortalClient();

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

    await state.upsertAccount(studentId: '400111111');
    await state.upsertAccount(studentId: '400222222');
    await state.load();
    final acc1 = state.accounts[0];
    final acc2 = state.accounts[1];

    portal.answers[acc1.id] = '1111';
    portal.answers[acc2.id] = '2222';
    portal.answers['400111111'] = '1111';
    portal.answers['400222222'] = '2222';

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
          child: HomeShell(state: state, services: services),
        ),
      ),
    );

    // 1. On startup auto-refresh, CAPTCHA challenges are suppressed (non-intrusive)
    await tester.pumpAndSettle();
    expect(find.byType(CaptchaDialog), findsNothing,
        reason: 'Auto-refresh on startup must never pop up blocking CAPTCHA modals');

    // 2. User initiates manual refresh - both accounts need CAPTCHA
    final refreshFinder = find.byType(RotatingRefreshButton).first;
    await tester.tap(refreshFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Mutex ensures exactly ONE dialog is presented, never stacked or overlapping
    expect(find.byType(CaptchaDialog), findsOneWidget);
    expect(find.text('کد امنیتی'), findsOneWidget);
    expect(find.text('حساب: 400111111'), findsOneWidget);

    // Answer the first dialog
    await tester.enterText(find.byType(TextField), '1111');
    await tester.tap(find.text('ادامه'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // After first dialog closes, the second dialog is presented
    expect(find.byType(CaptchaDialog), findsOneWidget);
    expect(find.text('کد امنیتی'), findsOneWidget);
    expect(find.text('حساب: 400222222'), findsOneWidget);

    // Answer the second dialog
    await tester.enterText(find.byType(TextField), '2222');
    await tester.tap(find.text('ادامه'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    await tester.pumpAndSettle();

    // Both finished, all dialogs closed, balances updated
    expect(find.byType(CaptchaDialog), findsNothing);
    expect(state.balanceFor(acc1.id), equals(600000));
    expect(state.balanceFor(acc2.id), equals(600000));
  });

  testWidgets(
      'active account is prioritized first in concurrency pool when accounts exceed limit',
      (tester) async {
    final client = _OrderTrackingPortalClient();
    final services = AppServices(
      bridge: PlatformBridge(),
      client: client,
      sessions: SessionManager(
        client: client,
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

    await state.upsertAccount(studentId: '100000001');
    await state.upsertAccount(studentId: '100000002');
    await state.upsertAccount(studentId: '100000003');
    await state.upsertAccount(studentId: '100000004');
    await state.load();

    final acc4 = state.accounts[3];
    state.selectReservationsAccount(acc4.id);

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
          child: HomeShell(state: state, services: services),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify acc4 (the active account) was processed first in the pool
    expect(client.syncOrder, isNotEmpty);
    expect(client.syncOrder.first, equals(acc4.id));
  });
}

class _OrderTrackingPortalClient extends FakePortalClient {
  final List<String> syncOrder = [];

  @override
  Future<Balance> fetchBalance(Session session) async {
    syncOrder.add(session.account);
    return Balance(amountRial: 500000, fetchedAt: DateTime.now().toUtc());
  }

  @override
  Future<List<Reservation>> fetchReservations(Session session) async {
    return const [];
  }

  @override
  Future<BookableMenus> fetchBookableMenus(Session session, {int days = 7}) async {
    return const BookableMenus(dates: [], menus: []);
  }
}


class ConcurrentTrackingPortalClient extends FakePortalClient {
  int _currentInFlight = 0;
  int maxConcurrentRequests = 0;
  int bookableMenuReads = 0;
  int _currentInFlightBalances = 0;
  int maxConcurrentBalanceRequests = 0;
  int totalBalanceRequests = 0;

  void resetCounters() {
    _currentInFlight = 0;
    maxConcurrentRequests = 0;
    bookableMenuReads = 0;
    _currentInFlightBalances = 0;
    maxConcurrentBalanceRequests = 0;
    totalBalanceRequests = 0;
  }

  @override
  Future<Balance> fetchBalance(Session session) async {
    totalBalanceRequests++;
    _currentInFlight++;
    _currentInFlightBalances++;
    if (_currentInFlight > maxConcurrentRequests) {
      maxConcurrentRequests = _currentInFlight;
    }
    if (_currentInFlightBalances > maxConcurrentBalanceRequests) {
      maxConcurrentBalanceRequests = _currentInFlightBalances;
    }

    // Simulate network delay so parallel requests overlap
    await Future.delayed(const Duration(milliseconds: 100));

    _currentInFlightBalances--;
    _currentInFlight--;
    return Balance(amountRial: 500000, fetchedAt: DateTime.now().toUtc());
  }

  @override
  Future<BookableMenus> fetchBookableMenus(Session session, {int days = 7}) async {
    bookableMenuReads++;
    _currentInFlight++;
    if (_currentInFlight > maxConcurrentRequests) {
      maxConcurrentRequests = _currentInFlight;
    }

    await Future.delayed(const Duration(milliseconds: 100));

    _currentInFlight--;
    return BookableMenus(
      dates: [DateTime.utc(2026, 10, 22)],
      menus: [
        MealMenu(
          date: DateTime.utc(2026, 10, 22),
          slot: MealSlot.lunch,
          halls: const [Hall(id: '1', name: 'مرکزی')],
          dishes: const [
            MenuOption(id: '101', name: 'چلو جوجه کباب', priceRial: 400000),
          ],
          reservable: true,
        ),
      ],
    );
  }

  @override
  Future<List<Reservation>> fetchReservations(Session session) async {
    return const [];
  }

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async {
    return const [];
  }
}

class AccountTestData {
  AccountTestData({
    required this.balanceRial,
    required this.profileName,
    required this.reservations,
    this.transactions = const [],
  });

  final int balanceRial;
  final String profileName;
  final List<Reservation> reservations;
  final List<Transaction> transactions;
}

class DataIsolatingPortalClient extends FakePortalClient {
  final Map<AccountId, AccountTestData> accountData = {};
  AccountId? failAccount;

  @override
  Future<Balance> fetchBalance(Session session) async {
    if (session.account == failAccount) {
      throw const PortalUnreachableException('simulated failure');
    }
    final data = accountData[session.account];
    return Balance(
      amountRial: data?.balanceRial ?? 0,
      profileName: data?.profileName,
      fetchedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<List<Reservation>> fetchReservations(Session session) async {
    if (session.account == failAccount) {
      throw const PortalUnreachableException('simulated failure');
    }
    final data = accountData[session.account];
    return data?.reservations ?? const [];
  }

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async {
    if (session.account == failAccount) {
      throw const PortalUnreachableException('simulated failure');
    }
    final data = accountData[session.account];
    return data?.transactions ?? const [];
  }
}

class _MultiAccountCaptchaPortalClient extends FakePortalClient {
  _MultiAccountCaptchaPortalClient({Map<String, String>? answers})
      : answers = answers ?? {};

  final Map<String, String> answers;
  final Set<String> solvedAccounts = {};

  @override
  Future<LoginChallenge?> beginLogin(String username) async {
    if (solvedAccounts.contains(username)) {
      return null;
    }
    return LoginChallenge(
      imageBytes: Uint8List.fromList([1, 2, 3, 4]),
      kind: ChallengeKind.digits4,
      sessionId: 'sess-$username',
    );
  }

  @override
  Future<Session> completeLogin({
    required String username,
    required String password,
    LoginChallengeResponse? challenge,
  }) async {
    if (challenge != null && challenge.answer == answers[username]) {
      solvedAccounts.add(username);
      return Session(
        account: username,
        cookies: const {},
        establishedAt: DateTime.now().toUtc(),
      );
    }
    throw const LoginRejectedException('کد امنیتی صحیح نمی باشد');
  }

  @override
  Future<Balance> fetchBalance(Session session) async {
    return Balance(amountRial: 600000, fetchedAt: DateTime.now().toUtc());
  }

  @override
  Future<List<Reservation>> fetchReservations(Session session) async {
    return const [];
  }

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async {
    return const [];
  }

  @override
  Future<BookableMenus> fetchBookableMenus(Session session, {int days = 7}) async {
    return const BookableMenus(dates: [], menus: []);
  }
}

