import 'package:bahonar_nut/core/auth/account_store.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/core/reminder/reminder.dart';
import 'package:bahonar_nut/core/auth/session_manager.dart';
import 'package:bahonar_nut/core/shared/time.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:bahonar_nut/platform/platform_services.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/shell/home_shell.dart';

import '../../helpers/portal_stubs.dart' show FakePortalClient;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/memory_stores.dart';

/// The shell's refresh, at the level a user sees it.
///
/// The defect these guard against was not a parsing bug but a **wiring** one:
/// the meal store existed in three separate instances, so the sync filled one
/// and the screens read another. The reservations screen was therefore
/// permanently empty, whatever the portal said — and the refresh button
/// appeared to work.
///
/// So the assertion here is deliberately about the *screen*, not about a store:
/// the user must see the meal after a refresh.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ir.ac.uk.bahonar_nut/platform');

  /// The platform calls the app made, so a test can assert on what was armed.
  final platformCalls = <MethodCall>[];

  setUp(() {
    platformCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          platformCalls.add(call);
          return null;
        });
  });

  late _FakePortalClient portal;
  late AppState state;
  late AppServices services;

  /// 1405/07/28 = 2026-10-20
  final theDay = DateTime.utc(2026, 10, 20);

  final clock = FixedServerClock.now(DateTime.utc(2026, 10, 20, 12));

  Future<void> pumpShell(WidgetTester tester) async {
    portal = _FakePortalClient();

    services = AppServices(
      bridge: PlatformBridge(channel: channel),
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

    // The state reads the **same** store the services own. This is the wiring
    // the defect broke: the state used to build its own.
    state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
      huntConfigStore: InMemoryHuntConfigStore(),
      mealStore: services.mealStore.store,
    );
    await state.upsertAccount(studentId: '400123456');
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
  }

  /// Opens a bottom-navigation tab by its destination label.
  ///
  /// Scoped to the navigation bar: the app bar carries the same Persian word
  /// as the destination, so an unscoped text finder matches two widgets and
  /// the tap is ambiguous. The label rather than the icon, because a
  /// destination shows its *selected* icon while it is active, so the
  /// unselected icon is not in the tree.
  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(label),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Opens the reservations tab.
  Future<void> openReservations(WidgetTester tester) async {
    await openTab(tester, 'رزروها');
  }

  /// Opens the accounts tab and reads the portal.
  Future<void> refreshFromPortal(WidgetTester tester) async {
    await openTab(tester, 'حساب‌ها');
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
  }

  testWidgets('a refresh makes the reservation appear on the screen', (
    tester,
  ) async {
    await pumpShell(tester);

    portal.reservations = [
      Reservation(
        id: 'row-lunch',
        date: theDay,
        slot: MealSlot.lunch,
        hall: const Hall(id: '1', name: 'مرکزی برادران'),
        option: const MenuOption(
          id: '62738',
          name: 'چلو اکبرجوجه',
          priceRial: 500000,
        ),
        state: ReservationState.active,
      ),
    ];

    await openReservations(tester);
    expect(
      find.text('هنوز وعده‌ای برای نمایش نیست'),
      findsOneWidget,
      reason: 'nothing has been read yet',
    );

    await refreshFromPortal(tester);
    await openReservations(tester);

    expect(
      find.text('چلو اکبرجوجه'),
      findsOneWidget,
      reason: 'the meal the portal reported must reach the screen',
    );
    expect(find.text('هنوز وعده‌ای برای نمایش نیست'), findsNothing);
  });

  testWidgets('a basket purchase reaches the reservations screen', (
    tester,
  ) async {
    // A basket purchase never appears in the weekly grid (verified live), so
    // the ledger is the only source that can show it.
    await pumpShell(tester);

    portal.transactions = [
      const Transaction(
        accountId: 'acc-1',
        type: 'رزرو غذا',
        foodName: 'چلو اکبرجوجه,دوغ',
        slot: MealSlot.lunch,
        weekday: 'سه شنبه',
        date: '1405/07/28',
        count: 1,
        amountRial: 500000,
      ),
    ];

    await refreshFromPortal(tester);
    await openReservations(tester);

    expect(find.text('چلو اکبرجوجه,دوغ'), findsOneWidget);
  });

  testWidgets('the dashboard shows the spend the ledger reports', (
    tester,
  ) async {
    await pumpShell(tester);

    portal.transactions = [
      const Transaction(
        accountId: 'acc-1',
        type: 'رزرو غذا',
        foodName: 'چلو اکبرجوجه,دوغ',
        slot: MealSlot.lunch,
        weekday: 'سه شنبه',
        date: '1405/07/28',
        count: 1,
        amountRial: 500000,
      ),
    ];

    await refreshFromPortal(tester);

    expect(
      state.transactions,
      isNotEmpty,
      reason: 'the dashboard reads the ledger the sync read',
    );
  });

  testWidgets('the reminder alarms are armed on startup, from the stored '
      'configuration', (tester) async {
    // The configuration is read from disk asynchronously, so arming the
    // alarms before the load finishes would use the *default* configuration —
    // which names no accounts, so no alarm would be set. The failure is
    // silent: the app looks healthy and the reminders never fire.
    //
    // The configuration is **already stored** before the shell is built, so
    // this exercises the startup path alone. A config change also arms, and
    // that would mask a broken startup.
    portal = _FakePortalClient();

    services = AppServices(
      bridge: PlatformBridge(channel: channel),
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

    // A configuration store that already holds a selected account.
    final configStore = InMemoryReminderConfigStore();
    await configStore.save(ReminderConfig(accountIds: {'acc-1'}));

    state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: configStore,
      huntConfigStore: InMemoryHuntConfigStore(),
      mealStore: services.mealStore.store,
    );
    await state.upsertAccount(studentId: '400123456');
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

    final scheduled = <(int, String?)>[
      for (final call in platformCalls)
        if (call.method == 'scheduleAlarm')
          (
            (call.arguments as Map)['requestCode'] as int,
            (call.arguments as Map)['payload'] as String?,
          ),
    ];

    expect(
      scheduled,
      isNotEmpty,
      reason:
          'the alarms must be armed at startup, from the configuration '
          'that was loaded — otherwise the reminders silently never fire',
    );
  });
}

/// A portal that serves a fixed set of reservations and transactions.
class _FakePortalClient extends FakePortalClient {
  List<Reservation> reservations = const [];
  List<Transaction> transactions = const [];

  @override
  Future<LoginChallenge?> beginLogin(String username) async => null;

  @override
  Future<Session> completeLogin({
    required String username,
    required String password,
    LoginChallengeResponse? challenge,
  }) async => Session(
    account: username,
    cookies: const {},
    establishedAt: DateTime.now().toUtc(),
  );

  @override
  Future<Session> refresh(Session session) async => session;

  @override
  Future<void> logout(Session session) async {}

  @override
  Future<DateTime> fetchServerTime(Session session) async =>
      DateTime.now().toUtc();

  @override
  Future<Balance> fetchBalance(Session session) async =>
      Balance(amountRial: 500000, fetchedAt: DateTime.now().toUtc());

  @override
  Future<List<MealOffering>> fetchOfferings(
    Session session,
    DateTime date,
  ) async => const [];

  @override
  Future<List<MealMenu>> fetchMenu(Session session, DateTime date) async =>
      const [];

  @override
  Future<BookableMenus> fetchBookableMenus(
    Session session, {
    int days = 7,
  }) async => const BookableMenus(dates: [], menus: []);

  @override
  Future<List<Reservation>> fetchReservations(Session session) async =>
      reservations;

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async =>
      transactions;

  @override
  Future<BasketPage> fetchBasket(Session session, {String? cursor}) async =>
      const BasketPage(listings: []);

  @override
  Future<BasketHoldStatus?> holdingsOnBuyPage(
    Session session, {
    required DateTime date,
    required String optionId,
  }) async => null;

  @override
  Uri? topUpUrl(Session session) => null;

  @override
  Future<ClaimResult> claim(Session session, ListingId listingId) async =>
      throw UnimplementedError();

  @override
  Future<Reservation> reserve(Session session, MealOffering offering) async =>
      throw UnimplementedError();

  @override
  Future<CancelOutcome> cancel(Session session, MealRef ref) async =>
      const CancelSucceeded();
}

/// A session store that holds credentials, so a login can happen.
