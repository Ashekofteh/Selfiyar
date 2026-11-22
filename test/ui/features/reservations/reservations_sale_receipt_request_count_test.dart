import 'package:bahonar_nut/core/auth/account_store.dart';
import 'package:bahonar_nut/core/auth/session_manager.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/core/shared/time.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:bahonar_nut/platform/platform_services.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/shell/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/memory_stores.dart';
import '../../../helpers/portal_stubs.dart';

/// The Food Basket actions, with the portal's read counters exposed.
///
/// Listing a meal for sale and taking it back off sale change neither the
/// balance nor the reservation mirror. The portal's own page is the
/// confirmation, so the shell must not spend a full account sync (four
/// requests) before or after the action.
class _SaleTrackingPortalClient extends FakePortalClient {
  _SaleTrackingPortalClient({required List<MealMenu> menus}) {
    this.menus = menus;
  }

  final Map<String, int> balances = {};
  final Map<String, List<Reservation>> heldReservations = {};

  int balanceReads = 0;
  int menuReads = 0;
  int reservationReads = 0;

  /// What [removeFromSale] reports. A test that models a meal bought by
  /// someone else sets this to a refusal before unlisting.
  SaleListingResult removeFromSaleResult = const SaleListingSucceeded();

  @override
  Future<Session> refresh(Session session) async => session;

  @override
  Future<void> logout(Session session) async {}

  @override
  Future<DateTime> fetchServerTime(Session session) async =>
      DateTime.utc(2026, 10, 20, 10);

  @override
  Future<Balance> fetchBalance(Session session) async {
    balanceReads++;
    return Balance(
      amountRial: balances[session.account] ?? 0,
      fetchedAt: DateTime.utc(2026, 10, 20, 10),
    );
  }

  @override
  Future<BookableMenus> fetchBookableMenus(
    Session session, {
    int days = 7,
  }) async {
    menuReads++;
    return BookableMenus(
      dates: menus.map((menu) => menu.date).toSet().toList()..sort(),
      menus: menus,
    );
  }

  @override
  Future<List<Reservation>> fetchReservations(Session session) async {
    reservationReads++;
    return heldReservations[session.account] ?? const [];
  }

  @override
  Future<SaleListingResult> listMealForSale(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  }) async => const SaleListingSucceeded();

  @override
  Future<SaleListingResult> removeFromSale(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  }) async => removeFromSaleResult;

  @override
  Future<ForgotReceiptOutcome> requestForgotReceipt(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  }) async => ForgotReceiptSucceeded(
    date: date,
    slot: slot,
    code: 'F-123',
    message: 'فیش فراموشی با موفقیت صادر شد.',
  );
}

void main() {
  testWidgets(
    'sale, unlisting, and forgot receipt do not re-read the account',
    (tester) async {
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 20, 10));
      final testDate = DateTime.utc(2026, 10, 20);

      final lunchMenu = MealMenu(
        date: testDate,
        slot: MealSlot.lunch,
        halls: const [Hall(id: '1', name: 'مرکزی')],
        dishes: const [
          MenuOption(id: '101', name: 'چلو قرمه سبزی', priceRial: 150000),
        ],
        reservable: true,
      );

      final portal = _SaleTrackingPortalClient(menus: [lunchMenu]);

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

      await state.upsertAccount(studentId: '400111', alias: 'علی');
      await state.load();

      final accountId = state.accounts.single.id;
      portal.balances[accountId] = 500000;
      portal.heldReservations[accountId] = [
        Reservation(
          id: 'held-1',
          date: testDate,
          slot: MealSlot.lunch,
          hall: const Hall(id: '1', name: 'مرکزی'),
          option: lunchMenu.dishes.first,
          state: ReservationState.active,
        ),
      ];
      state.setBalance(accountId, 500000);

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

      await tester.tap(find.text('رزروها'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('به‌روزرسانی از سامانه'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('فروش در سبد غذایی'), findsOneWidget);
      expect(find.byTooltip('دریافت فیش فراموشی'), findsOneWidget);

      // 1. List for sale: the portal's page is the confirmation, so neither
      // the balance nor the reservation mirror is read again.
      portal.balanceReads = 0;
      portal.menuReads = 0;
      portal.reservationReads = 0;

      await tester.tap(find.byTooltip('فروش در سبد غذایی'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('فروش در سبد'));
      await tester.pumpAndSettle();

      expect(
        state.isListedInBasket(accountId, testDate, MealSlot.lunch),
        isTrue,
      );
      expect(portal.balanceReads, 0);
      expect(portal.menuReads, 0);
      expect(portal.reservationReads, 0);

      // Let the success snackbar expire so it cannot cover the next action.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      // 2. Take it back off sale: the reload post reports the state, so the
      // pre-read that used to run before the call is gone.
      portal.balanceReads = 0;
      portal.menuReads = 0;
      portal.reservationReads = 0;

      await tester.tap(find.byTooltip('در سبد فروش (حذف از سبد)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('حذف از سبد'));
      await tester.pumpAndSettle();

      expect(
        state.isListedInBasket(accountId, testDate, MealSlot.lunch),
        isFalse,
      );
      expect(portal.balanceReads, 0);
      expect(portal.menuReads, 0);
      expect(portal.reservationReads, 0);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      // 2b. Sold while the screen was open: the unlist is refused with the
      // sold reason. The sale credits the account and removes the meal, so the
      // shell must re-read the account — but a sale cannot change the menu, so
      // the menu read stays at zero.
      await tester.tap(find.byTooltip('فروش در سبد غذایی'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('فروش در سبد'));
      await tester.pumpAndSettle();

      portal.removeFromSaleResult = const SaleListingRefused(
        'غذا به فروش رفته است.',
      );
      portal.balanceReads = 0;
      portal.menuReads = 0;
      portal.reservationReads = 0;

      await tester.tap(find.byTooltip('در سبد فروش (حذف از سبد)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('حذف از سبد'));
      await tester.pumpAndSettle();

      expect(find.text('غذا به فروش رفته است'), findsOneWidget);
      await tester.tap(find.text('متوجه شدم'));
      await tester.pumpAndSettle();

      expect(portal.balanceReads, greaterThan(0));
      expect(portal.reservationReads, greaterThan(0));
      expect(
        portal.menuReads,
        0,
        reason: 'a sale changes the account, not the university menu',
      );

      // 3. Forgot receipt: issuing a slip changes neither the balance nor the
      // reservations, so the dialog is the whole result.
      portal.balanceReads = 0;
      portal.menuReads = 0;
      portal.reservationReads = 0;

      await tester.tap(find.byTooltip('دریافت فیش فراموشی'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('دریافت فیش'));
      await tester.pumpAndSettle();

      expect(find.text('فیش فراموشی صادر شد'), findsOneWidget);
      expect(portal.balanceReads, 0);
      expect(portal.menuReads, 0);
      expect(portal.reservationReads, 0);

      await tester.tap(find.text('بستن'));
      await tester.pumpAndSettle();
    },
  );
}
