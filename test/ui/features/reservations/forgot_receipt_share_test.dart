import 'package:bahonar_nut/core/auth/account_store.dart';
import 'package:bahonar_nut/core/meal/local_meal_store.dart';
import 'package:bahonar_nut/core/meal/meal_invariant.dart';
import 'package:bahonar_nut/core/meal/models.dart';
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

class _ShareRecordingBridge extends PlatformBridge {
  String? sharedText;
  String? sharedTitle;
  String? smsText;

  @override
  Future<void> shareText({required String text, String? title}) async {
    sharedText = text;
    sharedTitle = title;
  }

  @override
  Future<void> sendSms({required String text}) async {
    smsText = text;
  }
}

class _ReceiptFakePortal extends FakePortalClient {
  // `menus` is the inherited field from FakePortalClient; the constructor only
  // seeds it, so the fake does not shadow the base class.
  _ReceiptFakePortal({required List<MealMenu> menus}) {
    this.menus = menus;
  }

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
        date: DateTime.utc(2026, 10, 22),
        slot: MealSlot.lunch,
        hall: const Hall(id: 'h1', name: 'مرکزی'),
        option: const MenuOption(id: 'd1', name: 'چلو قورمه سبزی', priceRial: 200000),
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
    return ForgotReceiptSucceeded(
      date: date,
      slot: slot,
      code: '987654',
    );
  }
}

void main() {
  testWidgets('Forgot receipt dialog provides sharing via messenger and SMS', (tester) async {
    final date = DateTime.utc(2026, 10, 22);
    final menu = MealMenu(
      date: date,
      slot: MealSlot.lunch,
      halls: [const Hall(id: 'h1', name: 'مرکزی')],
      dishes: [
        const MenuOption(id: 'd1', name: 'چلو قورمه سبزی', priceRial: 200000),
      ],
      reservable: false,
    );

    final portal = _ReceiptFakePortal(menus: [menu]);
    final clock = FixedServerClock.now(DateTime.utc(2026, 10, 22, 12));
    final bridge = _ShareRecordingBridge();

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

    await state.upsertAccount(studentId: '400111', alias: 'علی');
    await state.load();
    final accountId = state.accounts.first.id;

    // Put a held meal for this date & slot
    services.mealStore.store.put(StoredMeal(
      accountId: accountId,
      date: date,
      slot: MealSlot.lunch,
      source: MealSource.weeklyReservation,
      capturedAt: DateTime.utc(2026, 10, 20),
      dishName: 'چلو قورمه سبزی',
      hallName: 'مرکزی',
      priceRial: 200000,
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

    // Navigate to Reservations tab
    await tester.tap(find.text('رزروها'));
    await tester.pumpAndSettle();

    // Refresh table from portal to populate menu
    await tester.tap(find.byTooltip('به‌روزرسانی از سامانه'));
    await tester.pumpAndSettle();

    // The table shows the held meal with the receipt icon
    expect(find.byTooltip('دریافت فیش فراموشی'), findsOneWidget);

    // Tap to request receipt
    await tester.tap(find.byTooltip('دریافت فیش فراموشی'));
    await tester.pumpAndSettle();

    // Confirm dialog
    expect(find.text('دریافت فیش فراموشی کارت'), findsOneWidget);
    await tester.tap(find.text('دریافت فیش'));
    await tester.pumpAndSettle();

    // Success dialog
    expect(find.text('فیش فراموشی صادر شد'), findsOneWidget);
    expect(find.text('987654'), findsOneWidget);
    expect(find.text('ارسال با پیامک یا پیام‌رسان'), findsOneWidget);
    expect(find.text('ارسال مستقیم با پیامک (SMS)'), findsOneWidget);

    // 1. Test Share via messenger / general share
    await tester.tap(find.text('ارسال با پیامک یا پیام‌رسان'));
    await tester.pumpAndSettle();

    expect(bridge.sharedText, contains('987654'));
    expect(bridge.sharedText, contains('چلو قورمه سبزی'));
    expect(bridge.sharedText, contains('علی'));

    // 2. Test Direct SMS button
    await tester.tap(find.text('ارسال مستقیم با پیامک (SMS)'));
    await tester.pumpAndSettle();

    expect(bridge.smsText, contains('987654'));
    expect(bridge.smsText, contains('چلو قورمه سبزی'));
    expect(bridge.smsText, contains('علی'));
  });
}
