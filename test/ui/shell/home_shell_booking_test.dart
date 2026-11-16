import 'package:bahonar_nut/core/auth/account_store.dart';
import 'package:bahonar_nut/core/hunt/hunt_config.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/core/auth/session_manager.dart';
import 'package:bahonar_nut/core/shared/time.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:bahonar_nut/platform/platform_services.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/shell/home_shell.dart';
import 'package:bahonar_nut/ui/features/reservations/booking_sheet.dart';

import '../../helpers/portal_stubs.dart' show FakePortalClient;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/memory_stores.dart';

/// The booking flow, from the reservations tab to a booked meal.
///
/// ## Why these tests exist
///
/// The booking flow used to be reached by a path that failed silently: the
/// button was tapped, nothing happened, and the reason was reported on a
/// *different* tab. A failure the user cannot see is a failure they will
/// read as "the app is broken".
///
/// So two things are asserted here: the table is filled by one read of the
/// week, and the reason a read failed is stated where the student was when
/// they asked.
void main() {
  late _FakePortalClient portal;
  late AppState state;

  /// A clock that reads as synced.
  final syncedClock = FixedServerClock.now(DateTime.utc(2026, 10, 20, 12));

  /// The days the portal can still serve, two days after its today.
  final bookableDays = List.generate(7, (i) => DateTime.utc(2026, 10, 22 + i));

  /// A menu for the first bookable day.
  final lunchMenu = MealMenu(
    date: DateTime.utc(2026, 10, 22),
    slot: MealSlot.lunch,
    halls: const [Hall(id: '1', name: 'مرکزی برادران')],
    dishes: const [
      MenuOption(id: '62759', name: 'شوید پلو', priceRial: 500000),
    ],
    reservable: true,
  );

  Future<void> pumpShell(
    WidgetTester tester, {
    required ServerClock clock,
    List<MealMenu> menus = const [],
    Object? failure,
  }) async {
    portal = _FakePortalClient(
      menus: menus,
      failure: failure,
      bookableDays: bookableDays,
    );

    state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
      huntConfigStore: InMemoryHuntConfigStore(),
    );
    await state.upsertAccount(studentId: '400123456');
    await state.load();
    state.selectHuntAccount(state.accounts.first.id);
    await state.saveHuntConfig(
      HuntConfig(
        targetDate: DateTime.utc(2026, 10, 22),
        targetSlot: MealSlot.lunch,
      ),
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

  /// Opens the reservations tab and refreshes the table from the portal.
  Future<void> openTable(WidgetTester tester) async {
    await tester.tap(find.text('رزروها'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('به‌روزرسانی از سامانه'));
    await tester.pumpAndSettle();
  }

  testWidgets('the table is filled, and the week is read in one go', (
    tester,
  ) async {
    await pumpShell(tester, clock: syncedClock, menus: [lunchMenu]);

    await openTable(tester);

    // The week comes from **one** read. Reading a page per date would mean
    // seven reads — and fourteen once the week boundary is crossed — for a
    // question one read answers.
    expect(portal.menuReads, 1);
    expect(
      portal.menuDateRequests,
      0,
      reason: 'the menu must not be read one date at a time',
    );

    expect(
      find.text('قابل رزرو'),
      findsOneWidget,
      reason: 'the bookable meal must appear in the table',
    );
  });

  testWidgets('the table covers the next seven days', (tester) async {
    await pumpShell(tester, clock: syncedClock);

    await openTable(tester);

    expect(
      portal.requestedDays,
      7,
      reason: 'the table covers the next seven days',
    );
    expect(portal.bookableDays, hasLength(7));
    expect(
      portal.bookableDays.first,
      DateTime.utc(2026, 10, 22),
      reason: 'the first reservable date is two days after the portal today',
    );
  });

  testWidgets('a failed read says why, on the screen the student is on', (
    tester,
  ) async {
    await pumpShell(tester, clock: syncedClock, failure: StateError('offline'));

    await openTable(tester);

    // The reason is stated where the student was when they asked — not on
    // the hunt tab, which they may never open.
    expect(
      find.descendant(
        of: find.byType(Scaffold),
        matching: find.textContaining('ارتباط با سامانه برقرار نشد'),
      ),
      findsOneWidget,
      reason:
          'a failed read is the portal being unreachable, and it must '
          'not be reported as "no dates left"',
    );
  });

  testWidgets('tapping a bookable row opens the sheet for that meal', (
    tester,
  ) async {
    await pumpShell(tester, clock: syncedClock, menus: [lunchMenu]);

    await openTable(tester);

    await tester.tap(find.byTooltip('رزرو این وعده'));
    await tester.pumpAndSettle();

    expect(
      find.byType(BookingSheet),
      findsOneWidget,
      reason: 'the sheet must open for the meal the student tapped',
    );
    expect(
      find.text('شوید پلو'),
      findsOneWidget,
      reason: 'the sheet must name the dish on offer',
    );
  });
}

/// A portal that serves a fixed menu, and counts the reads.
class _FakePortalClient extends FakePortalClient {
  // `menus` is the inherited field from FakePortalClient; the constructor only
  // seeds it, so the fake does not shadow the base class.
  _FakePortalClient({
    required List<MealMenu> menus,
    required this.bookableDays,
    this.failure,
  }) {
    this.menus = menus;
  }

  /// The days the fake reports as still bookable.
  final List<DateTime> bookableDays;

  final Object? failure;

  /// How many times the menu was read, in any form.
  int menuReads = 0;

  /// How many times the menu was read **one date at a time**.
  int menuDateRequests = 0;

  /// How many days the last read asked for.
  int requestedDays = 0;

  @override
  Future<List<MealMenu>> fetchMenu(Session session, DateTime date) async {
    menuReads++;
    menuDateRequests++;
    if (failure != null) throw failure!;
    return menus;
  }

  @override
  Future<BookableMenus> fetchBookableMenus(
    Session session, {
    int days = 7,
  }) async {
    menuReads++;
    requestedDays = days;
    if (failure != null) throw failure!;
    return BookableMenus(dates: bookableDays, menus: menus);
  }

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
      DateTime.utc(2026, 10, 20, 12);

  @override
  Future<Balance> fetchBalance(Session session) async =>
      Balance(amountRial: 0, fetchedAt: DateTime.utc(2026, 10, 20));

  @override
  Future<List<MealOffering>> fetchOfferings(Session s, DateTime date) async =>
      const [];

  @override
  Future<List<Reservation>> fetchReservations(Session session) async =>
      const [];

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async =>
      const [];

  @override
  Future<BasketPage> fetchBasket(Session session, {String? cursor}) async =>
      BasketPage(listings: []);

  @override
  Future<Reservation> reserve(Session session, MealOffering offering) async =>
      throw UnimplementedError();

  @override
  Future<ClaimResult> claim(Session session, ListingId listingId) async =>
      throw UnimplementedError();

  @override
  Future<BasketHoldStatus?> holdingsOnBuyPage(
    Session session, {
    required DateTime date,
    required String optionId,
  }) async => null;

  @override
  Future<CancelOutcome> cancel(Session session, MealRef ref) async =>
      const CancelSucceeded();

  @override
  Uri? topUpUrl(Session session) => null;
}
