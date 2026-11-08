import 'dart:async';
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
import 'package:bahonar_nut/ui/widgets/receipt_loading_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/memory_stores.dart';
import '../helpers/portal_stubs.dart';

class _ControlledReceiptPortal extends FakePortalClient {
  _ControlledReceiptPortal({required this.menus});

  @override
  final List<MealMenu> menus;

  Completer<ForgotReceiptOutcome>? receiptCompleter;

  @override
  Future<BookableMenus> fetchBookableMenus(Session session, {int days = 7}) async {
    return BookableMenus(
      dates: menus.map((m) => m.date).toList(),
      menus: menus,
    );
  }

  @override
  Future<List<Reservation>> fetchReservations(Session session) async {
    return [
      Reservation(
        id: 'r1',
        date: DateTime.utc(2026, 11, 8),
        slot: MealSlot.lunch,
        hall: const Hall(id: 'h1', name: 'مرکزی'),
        option: const MenuOption(id: 'd1', name: 'زرشک پلو با مرغ', priceRial: 250000),
        state: ReservationState.active,
      ),
    ];
  }

  @override
  Future<ForgotReceiptOutcome> requestForgotReceipt(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType? reserveType,
  }) async {
    if (receiptCompleter != null) {
      return receiptCompleter!.future;
    }
    return ForgotReceiptSucceeded(
      date: date,
      slot: slot,
      code: '197060',
      quotaRemaining: 0,
    );
  }
}

void main() {
  group('ForgotReceiptLoadingDialog widget tests', () {
    testWidgets('renders icon, spinner, title, subtitle and is non-dismissible', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ForgotReceiptLoadingDialog(),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.receipt_long_rounded), findsOneWidget);
      expect(find.text('در حال صدور فیش فراموشی...'), findsOneWidget);
      expect(find.text('ارتباط امن با سامانه کالینان دانشگاه و دریافت ژتون موقت'), findsOneWidget);

      final popScope = tester.widget<PopScope>(find.byType(PopScope));
      expect(popScope.canPop, isFalse);
    });
  });

  group('HomeShell receipt loading dialog integration', () {
    testWidgets('shows loading dialog while waiting and presents 197060 with quota alert', (tester) async {
      final date = DateTime.utc(2026, 11, 8);
      final menu = MealMenu(
        date: date,
        slot: MealSlot.lunch,
        halls: [const Hall(id: 'h1', name: 'مرکزی')],
        dishes: [
          const MenuOption(id: 'd1', name: 'زرشک پلو با مرغ', priceRial: 250000),
        ],
        reservable: false,
      );

      final portal = _ControlledReceiptPortal(menus: [menu]);
      final clock = FixedServerClock.now(DateTime.utc(2026, 11, 8, 12));
      final bridge = PlatformBridge();

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
        huntConfigStore: InMemoryHuntConfigStore(),
        mealStore: services.mealStore.store,
      );

      await state.upsertAccount(studentId: '400111', alias: 'احمد');
      await state.load();
      final accountId = state.accounts.first.id;

      services.mealStore.store.put(StoredMeal(
        accountId: accountId,
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: DateTime.utc(2026, 11, 8),
        dishName: 'زرشک پلو با مرغ',
        hallName: 'مرکزی',
        priceRial: 250000,
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
      await tester.pumpAndSettle();

      // Navigate to Reservations tab and sync
      await tester.tap(find.text('رزروها'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('به‌روزرسانی از سامانه'));
      await tester.pumpAndSettle();

      // Configure completer to hold the request in-flight
      final completer = Completer<ForgotReceiptOutcome>();
      portal.receiptCompleter = completer;

      // Tap receipt button
      await tester.tap(find.byTooltip('دریافت فیش فراموشی'));
      await tester.pumpAndSettle();

      // Confirmation dialog is shown
      expect(find.text('دریافت فیش فراموشی کارت'), findsOneWidget);
      await tester.tap(find.text('دریافت فیش'));
      // Pump one frame to display loading dialog without settling
      await tester.pump();

      // Loading dialog is actively visible with animation and Persian title
      expect(find.byType(ForgotReceiptLoadingDialog), findsOneWidget);
      expect(find.text('در حال صدور فیش فراموشی...'), findsOneWidget);

      // Now complete the network request with 197060 and 0 remaining quota
      completer.complete(
        ForgotReceiptSucceeded(
          date: date,
          slot: MealSlot.lunch,
          code: '197060',
          quotaRemaining: 0,
        ),
      );

      // Let animation settle and dismiss dialog
      await tester.pumpAndSettle();

      // Loading dialog is dismissed
      expect(find.byType(ForgotReceiptLoadingDialog), findsNothing);

      // Receipt code dialog is shown with 197060 and quota exhaustion notification
      expect(find.text('فیش فراموشی صادر شد'), findsOneWidget);
      expect(find.text('197060'), findsOneWidget);
      expect(find.text('این آخرین فیش مجاز شما در این ماه برای این وعده بود (۲ از ۲ استفاده شد).'), findsOneWidget);
    });

    testWidgets('dismisses loading dialog and shows refusal dialog on refusal', (tester) async {
      final date = DateTime.utc(2026, 11, 8);
      final menu = MealMenu(
        date: date,
        slot: MealSlot.lunch,
        halls: [const Hall(id: 'h1', name: 'مرکزی')],
        dishes: [
          const MenuOption(id: 'd1', name: 'زرشک پلو با مرغ', priceRial: 250000),
        ],
        reservable: false,
      );

      final portal = _ControlledReceiptPortal(menus: [menu]);
      final clock = FixedServerClock.now(DateTime.utc(2026, 11, 8, 12));
      final bridge = PlatformBridge();

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
        huntConfigStore: InMemoryHuntConfigStore(),
        mealStore: services.mealStore.store,
      );

      await state.upsertAccount(studentId: '400111', alias: 'احمد');
      await state.load();
      final accountId = state.accounts.first.id;

      services.mealStore.store.put(StoredMeal(
        accountId: accountId,
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: DateTime.utc(2026, 11, 8),
        dishName: 'زرشک پلو با مرغ',
        hallName: 'مرکزی',
        priceRial: 250000,
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
      await tester.pumpAndSettle();

      // Navigate to Reservations tab and sync
      await tester.tap(find.text('رزروها'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('به‌روزرسانی از سامانه'));
      await tester.pumpAndSettle();

      final completer = Completer<ForgotReceiptOutcome>();
      portal.receiptCompleter = completer;

      await tester.tap(find.byTooltip('دریافت فیش فراموشی'));
      await tester.pumpAndSettle();

      expect(find.text('دریافت فیش فراموشی کارت'), findsOneWidget);
      await tester.tap(find.text('دریافت فیش'));
      await tester.pump();

      expect(find.byType(ForgotReceiptLoadingDialog), findsOneWidget);

      completer.complete(
        const ForgotReceiptRefused('شما دو فیش خود را دریافت کرده‌اید و سقف مجاز دریافت فیش به پایان رسیده است.'),
      );

      await tester.pumpAndSettle();

      expect(find.byType(ForgotReceiptLoadingDialog), findsNothing);
      expect(find.textContaining('شما دو فیش خود را دریافت کرده‌اید'), findsOneWidget);
    });
  });
}
