import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bahonar_nut/core/account_store.dart';
import 'package:bahonar_nut/core/local_meal_store.dart';
import 'package:bahonar_nut/core/meal_invariant.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:bahonar_nut/platform/platform_services.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/home_shell.dart';
import 'package:bahonar_nut/ui/screens/reservations_screen.dart';
import 'package:bahonar_nut/ui/widgets/rotating_refresh_button.dart';

import '../helpers/memory_stores.dart';
import '../helpers/portal_stubs.dart';

class _TrackingBridge extends PlatformBridge {
  final List<Map<String, dynamic>> postedNotifications = [];
  String? initialDeepLink;

  @override
  Future<void> postNotification({
    required int id,
    required String title,
    required String body,
    String? deepLink,
  }) async {
    postedNotifications.add({
      'id': id,
      'title': title,
      'body': body,
      'deepLink': deepLink,
    });
  }

  @override
  Future<String?> getInitialDeepLink() async => initialDeepLink;

  @override
  Future<List<String>> pendingRequests() async => [];
}

class _TrackingPortalClient extends FakePortalClient {
  _TrackingPortalClient({
    List<MealMenu> menus = const [],
    this.reservations = const [],
    super.balanceRial = 1000000,
  }) {
    this.menus = menus;
  }

  List<Reservation> reservations;
  int balanceCalls = 0;
  int bookableMenuCalls = 0;

  @override
  Future<BookableMenus> fetchBookableMenus(Session session, {int days = 7}) async {
    bookableMenuCalls++;
    return BookableMenus(dates: const [], menus: menus);
  }

  @override
  Future<Balance> fetchBalance(Session session) async {
    balanceCalls++;
    return Balance(amountRial: balanceRial, fetchedAt: DateTime.now().toUtc());
  }

  @override
  Future<List<Reservation>> fetchReservations(Session session) async => reservations;

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async => [];

  @override
  Future<LoginChallenge?> beginLogin(String username) async => null;

  @override
  Future<Session> completeLogin({
    required String username,
    required String password,
    LoginChallengeResponse? challenge,
  }) async =>
      Session(
        account: username,
        cookies: const {'ASP.NET_SessionId': 'test-session-123'},
        establishedAt: DateTime.now().toUtc(),
      );

  @override
  Future<Session> refresh(Session session) async => session;

  @override
  Future<void> logout(Session session) async {}
}

MealMenu _createMenu(DateTime date, MealSlot slot, {String dish = 'چلو قورمه سبزی', int price = 500000}) {
  return MealMenu(
    date: date,
    slot: slot,
    reservable: true,
    halls: const [Hall(id: 'h1', name: 'سلف مرکزی')],
    dishes: [MenuOption(id: 'd1', name: dish, priceRial: price)],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Current Wednesday: 2026-10-21. Current week Sat: 2026-10-17. Next week Sat: 2026-10-24.
  final fixedDate = DateTime.utc(2026, 10, 21, 12);
  final clock = FixedServerClock.now(fixedDate);
  final currentWeekDay = DateTime.utc(2026, 10, 20);
  final nextWeekSat = DateTime.utc(2026, 10, 24);

  testWidgets('startup auto-refresh runs quietly, establishes live sessions, and notifies on meal status change', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Initial meal was booked and unconsumed
    final portal = _TrackingPortalClient(
      balanceRial: 850000,
      reservations: [
        Reservation(
          id: 'res-lunch-1',
          date: currentWeekDay,
          slot: MealSlot.lunch,
          hall: const Hall(id: 'h1', name: 'سلف مرکزی'),
          option: const MenuOption(id: 'd1', name: 'چلو قورمه سبزی', priceRial: 500000),
          state: ReservationState.consumed,
        ),
      ],
    );

    final bridge = _TrackingBridge();
    final services = AppServices(
      bridge: bridge,
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
      mealStore: services.mealStore.store,
      menuStore: services.menuStore.store,
    );

    await state.upsertAccount(studentId: '400123456', alias: 'دانشجو');
    final accountId = state.accounts.first.id;
    await state.load();

    // MealStore already has the unconsumed meal stored from earlier session
    services.mealStore.store.put(StoredMeal(
      accountId: accountId,
      date: currentWeekDay,
      slot: MealSlot.lunch,
      source: MealSource.weeklyReservation,
      capturedAt: currentWeekDay,
      dishName: 'چلو قورمه سبزی',
      hallName: 'سلف مرکزی',
      priceRial: 500000,
      isConsumed: false,
    ));

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

    await tester.pump();
    await tester.pumpAndSettle();

    // 1. Verify auto-refresh synced account balance and opened a session in memory
    expect(portal.balanceCalls, greaterThan(0));
    expect(state.balanceFor(accountId), equals(850000));
    expect(services.sessions.sessionFor(accountId), isNotNull,
        reason: 'Session must remain open in memory across app lifetime');

    // 2. Verify consumed meal status change notification was posted
    expect(bridge.postedNotifications, isNotEmpty);
    final consumedNotif = bridge.postedNotifications
        .firstWhere((n) => n['title'] == 'مصرف غذا', orElse: () => {});
    expect(consumedNotif['title'], equals('مصرف غذا'));
    expect(consumedNotif['body'], contains('مصرف شد'));
  });

  testWidgets('manual table refresh detects nextWeekPublished, shows notification and sets week 1', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final portal = _TrackingPortalClient(
      menus: [
        _createMenu(currentWeekDay, MealSlot.lunch),
        _createMenu(nextWeekSat, MealSlot.lunch),
      ],
    );

    final bridge = _TrackingBridge();
    final services = AppServices(
      bridge: bridge,
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

    // Store only has current week
    services.menuStore.store.put(_createMenu(currentWeekDay, MealSlot.lunch));

    final state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
      mealStore: services.mealStore.store,
      menuStore: services.menuStore.store,
    );

    await state.upsertAccount(studentId: '400123456', alias: 'دانشجو');
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

    await tester.pump();
    await tester.pumpAndSettle();

    // Navigate to reservations tab
    await tester.tap(find.text('رزروها'));
    await tester.pumpAndSettle();

    // Tap refresh button on reservations table
    final refreshButton = find.byType(RotatingRefreshButton);
    expect(refreshButton, findsOneWidget);
    await tester.tap(refreshButton);
    await tester.pump();
    await tester.pumpAndSettle();

    // Next week notification should be posted
    final nextWeekNotif = bridge.postedNotifications
        .firstWhere((n) => n['id'] == 4160, orElse: () => {});
    expect(nextWeekNotif['id'], equals(4160));
    expect(nextWeekNotif['body'], contains('برنامه غذایی هفته بعد در سامانه فعال شد'));

    // SnackBar should have action 'مشاهده'
    expect(find.text('برنامه غذایی هفته بعد در سامانه فعال شد.'), findsOneWidget);
    final viewAction = find.text('مشاهده');
    expect(viewAction, findsOneWidget);

    await tester.tap(viewAction);
    await tester.pumpAndSettle();

    // Reservations screen now displays next week
    expect(find.byType(ReservationsScreen), findsOneWidget);
    expect(find.text('هفته بعد'), findsOneWidget);
  });
}
