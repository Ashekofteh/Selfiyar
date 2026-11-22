import 'package:bahonar_nut/core/auth/account_store.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/shared/persian.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/core/auth/session_manager.dart';
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

class _BalanceTrackingPortalClient extends FakePortalClient {
  // `menus` is the inherited field from FakePortalClient; the constructor only
  // seeds it, so the fake does not shadow the base class.
  _BalanceTrackingPortalClient({
    required List<MealMenu> menus,
    required this.bookableDays,
  }) {
    this.menus = menus;
  }

  final Map<String, int> balances = {};
  final Map<String, List<Reservation>> heldReservations = {};
  final List<DateTime> bookableDays;

  /// How many times the portal was asked for the balance and the menus.
  int balanceReads = 0;
  int menuReads = 0;

  @override
  Future<Session> refresh(Session session) async => session;

  @override
  Future<void> logout(Session session) async {}

  @override
  Future<DateTime> fetchServerTime(Session session) async =>
      DateTime.utc(2026, 10, 20, 12);

  @override
  Future<Balance> fetchBalance(Session session) async {
    balanceReads++;
    final amount = balances[session.account] ?? 0;
    return Balance(
      amountRial: amount,
      fetchedAt: DateTime.utc(2026, 10, 20, 12),
    );
  }

  @override
  Future<BookableMenus> fetchBookableMenus(
    Session session, {
    int days = 7,
  }) async {
    menuReads++;
    return BookableMenus(dates: bookableDays, menus: menus);
  }

  @override
  Future<List<Reservation>> fetchReservations(Session session) async {
    return heldReservations[session.account] ?? const [];
  }

  @override
  Future<Reservation> reserve(Session session, MealOffering offering) async {
    final current = balances[session.account] ?? 0;
    balances[session.account] = current - offering.option.priceRial;
    final res = Reservation(
      id: 'res_${DateTime.now().millisecondsSinceEpoch}',
      date: offering.date,
      slot: offering.slot,
      hall: offering.hall,
      option: offering.option,
      state: ReservationState.active,
    );
    heldReservations.putIfAbsent(session.account, () => []).add(res);
    return res;
  }

  @override
  Future<CancelOutcome> cancel(Session session, MealRef ref) async {
    final current = balances[session.account] ?? 0;
    balances[session.account] = current + 150000;
    heldReservations[session.account]?.removeWhere(
      (r) =>
          r.date.year == ref.date.year &&
          r.date.month == ref.date.month &&
          r.date.day == ref.date.day &&
          r.slot == ref.slot,
    );
    return const CancelSucceeded();
  }
}

void main() {
  testWidgets(
    'ReservationsScreen and AccountsScreen update balance in real-time after reserve and cancel',
    (tester) async {
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 20, 12));
      final testDate = DateTime.utc(2026, 10, 22);

      final lunchMenu = MealMenu(
        date: testDate,
        slot: MealSlot.lunch,
        halls: const [Hall(id: '1', name: 'مرکزی')],
        dishes: const [
          MenuOption(
            id: '101',
            name: 'چلو قرمه سبزی',
            priceRial: 150000,
          ), // 15,000 Toman
        ],
        reservable: true,
      );

      final portal = _BalanceTrackingPortalClient(
        menus: [lunchMenu],
        bookableDays: [testDate],
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

      await state.upsertAccount(studentId: '400111', alias: 'علی');
      await state.upsertAccount(studentId: '400222', alias: 'رضا');
      await state.load();

      final accAli = state.accounts[0].id;
      final accReza = state.accounts[1].id;

      portal.balances[accAli] = 500000; // Ali: 50,000 Toman
      portal.balances[accReza] = 800000; // Reza: 80,000 Toman

      state.setBalance(accAli, 500000);
      state.setBalance(accReza, 800000);

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

      // 1. Check Accounts tab: Ali shows 50,000 Toman, Reza shows 80,000 Toman
      expect(
        find.text('اعتبار: ${formatTomanPersian(500000)}'),
        findsOneWidget,
      );
      expect(
        find.text('اعتبار: ${formatTomanPersian(800000)}'),
        findsOneWidget,
      );

      // 2. Navigate to Reservations tab
      await tester.tap(find.text('رزروها'));
      await tester.pumpAndSettle();

      // Initial check in Reservations top bar:
      // Ali: 50,000 Toman, Reza: 80,000 Toman
      expect(find.text('رزرو برای حساب:'), findsOneWidget);
      expect(find.text('علی • ${formatTomanPersian(500000)}'), findsOneWidget);
      expect(find.text('رضا • ${formatTomanPersian(800000)}'), findsOneWidget);

      // Refresh table from portal to populate menu
      await tester.tap(find.byTooltip('به‌روزرسانی از سامانه'));
      await tester.pumpAndSettle();

      // Verify row is bookable
      expect(find.byTooltip('رزرو این وعده'), findsOneWidget);

      // Tap to book the meal for Ali
      await tester.tap(find.byTooltip('رزرو این وعده'));
      await tester.pumpAndSettle();

      // Tap on dish option to select it
      await tester.tap(find.text('چلو قرمه سبزی'));
      await tester.pumpAndSettle();

      // Tap confirm in the booking sheet
      expect(find.text('ثبت رزرو'), findsOneWidget);
      portal.balanceReads = 0;
      portal.menuReads = 0;
      await tester.tap(find.text('ثبت رزرو'));
      await tester.pumpAndSettle();

      // A booking cannot change the menu, and the service already holds a
      // fresh balance; the single quiet sync is all the portal work that is
      // left after the write.
      expect(
        portal.menuReads,
        0,
        reason: 'a booking must not re-read the bookable menus',
      );
      expect(
        portal.balanceReads,
        1,
        reason:
            'the quiet sync reads the balance once; fetching it separately '
            'before the sync would be a second request for the same figure',
      );

      // 3. VERIFY REAL-TIME BALANCE UPDATE AFTER BOOKING:
      // Ali's balance was 50,000 Toman - 15,000 Toman = 35,000 Toman (350,000 Rial)
      expect(find.text('علی • ${formatTomanPersian(350000)}'), findsOneWidget);
      expect(find.text('رضا • ${formatTomanPersian(800000)}'), findsOneWidget);
      expect(state.balanceFor(accAli), 350000);

      // Check Accounts tab to confirm real-time synchronization
      await tester.tap(find.text('حساب‌ها'));
      await tester.pumpAndSettle();
      expect(
        find.text('اعتبار: ${formatTomanPersian(350000)}'),
        findsOneWidget,
      );
      expect(
        find.text('اعتبار: ${formatTomanPersian(800000)}'),
        findsOneWidget,
      );

      // 4. Return to Reservations tab and cancel the reservation
      await tester.tap(find.text('رزروها'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('لغو رزرو'), findsOneWidget);
      portal.balanceReads = 0;
      portal.menuReads = 0;
      await tester.tap(find.byTooltip('لغو رزرو'));
      await tester.pumpAndSettle();

      // The cancel path gets the same treatment as the booking path: the
      // service read the portal back and removed the meal from the mirror,
      // and a cancel cannot change the menu either.
      expect(
        portal.menuReads,
        0,
        reason: 'a cancel must not re-read the bookable menus',
      );
      expect(
        portal.balanceReads,
        1,
        reason:
            'the quiet sync reads the balance once; fetching it separately '
            'before the sync would be a second request for the same figure',
      );

      // 5. VERIFY REAL-TIME BALANCE UPDATE AFTER CANCELLATION:
      // Ali's balance was refunded: 35,000 Toman + 15,000 Toman = 50,000 Toman (500,000 Rial)
      expect(find.text('علی • ${formatTomanPersian(500000)}'), findsOneWidget);
      expect(find.text('رضا • ${formatTomanPersian(800000)}'), findsOneWidget);
      expect(state.balanceFor(accAli), 500000);

      // Check Accounts tab to confirm refund is updated there too
      await tester.tap(find.text('حساب‌ها'));
      await tester.pumpAndSettle();
      expect(
        find.text('اعتبار: ${formatTomanPersian(500000)}'),
        findsOneWidget,
      );
      expect(
        find.text('اعتبار: ${formatTomanPersian(800000)}'),
        findsOneWidget,
      );
    },
  );
}
