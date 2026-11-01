import 'package:bahonar_nut/core/account_store.dart';
import 'package:bahonar_nut/core/local_meal_store.dart';
import 'package:bahonar_nut/core/meal_invariant.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/reminder.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:bahonar_nut/platform/platform_services.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/home_shell.dart';
import 'package:bahonar_nut/ui/screens/meal_reminder_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/memory_stores.dart';
import '../helpers/portal_stubs.dart';

class _FakeBridge extends PlatformBridge {
  String? sharedText;
  String? initialDeepLinkValue;
  void Function(String? payload)? huntHandler;

  @override
  Future<String?> getInitialDeepLink() async => initialDeepLinkValue;

  @override
  Future<void> shareText({required String text, String? title}) async {
    sharedText = text;
  }

  @override
  void onHuntRequested(void Function(String? payload) handler) {
    huntHandler = handler;
    super.onHuntRequested(handler);
  }
}

void main() {
  late FixedServerClock clock;
  late _FakeBridge bridge;
  late FakePortalClient portal;
  late AppServices services;
  late AppState state;

  final today = DateTime.utc(2026, 10, 20); // 1405-07-28
  final tomorrow = DateTime.utc(2026, 10, 21);

  setUp(() async {
    // 12:00 UTC == 15:30 Iran time (within lunch window)
    clock = FixedServerClock.now(DateTime.utc(2026, 10, 20, 10, 0));
    bridge = _FakeBridge();
    portal = FakePortalClient();

    services = AppServices(
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

    state = AppState(
      accountStore: InMemoryAccountStore(),
      reminderConfigStore: InMemoryReminderConfigStore(),
      huntConfigStore: InMemoryHuntConfigStore(),
      mealStore: services.mealStore.store,
    );

    await state.upsertAccount(studentId: '400123456', alias: 'پوریا');
    await state.load();
  });

  Widget wrap(Widget child) {
    return MaterialApp(
      locale: const Locale('fa', 'IR'),
      supportedLocales: const [Locale('fa', 'IR')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    );
  }

  group('MealReminderScreen unit & widget rendering', () {
    testWidgets('renders lunch meals for today with dish and hall names', (tester) async {
      final accountId = state.accounts.first.id;

      services.mealStore.store.put(StoredMeal(
        accountId: accountId,
        date: today,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: DateTime.utc(2026, 10, 18),
        dishName: 'چلو جوجه کباب',
        hallName: 'سلف مرکزی',
        priceRial: 250000,
      ));

      await tester.pumpWidget(
        wrap(
          MealReminderScreen(
            slot: ReminderSlot.lunch,
            state: state,
            services: services,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('وعده‌های ناهار امروز'), findsOneWidget);
      expect(find.text('چلو جوجه کباب'), findsOneWidget);
      expect(find.text('سلف مرکزی'), findsOneWidget);
      expect(find.text('پوریا'), findsOneWidget);
      expect(find.text('آماده تحویل در سلف'), findsOneWidget);
      expect(find.text('۲۵٬۰۰۰ تومان'), findsOneWidget);
    });

    testWidgets('renders evening meals including today dinner and tomorrow breakfast', (tester) async {
      final accountId = state.accounts.first.id;

      services.mealStore.store.put(StoredMeal(
        accountId: accountId,
        date: today,
        slot: MealSlot.dinner,
        source: MealSource.weeklyReservation,
        capturedAt: DateTime.utc(2026, 10, 18),
        dishName: 'خوراک شنیسل مرغ',
        hallName: 'سلف کوثر',
        priceRial: 200000,
      ));

      services.mealStore.store.put(StoredMeal(
        accountId: accountId,
        date: tomorrow,
        slot: MealSlot.breakfast,
        source: MealSource.weeklyReservation,
        capturedAt: DateTime.utc(2026, 10, 18),
        dishName: 'شیر و عسل',
        hallName: 'سلف کوثر',
        priceRial: 80000,
      ));

      await tester.pumpWidget(
        wrap(
          MealReminderScreen(
            slot: ReminderSlot.evening,
            state: state,
            services: services,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('وعده‌های شام و صبحانه'), findsOneWidget);
      expect(find.text('خوراک شنیسل مرغ'), findsOneWidget);
      expect(find.text('شیر و عسل'), findsOneWidget);
      expect(find.text('صبحانه فردا'), findsOneWidget);
      expect(find.text('شام'), findsOneWidget);
    });

    testWidgets('displays empty state when no meals reserved and allows hunting', (tester) async {
      bool huntOpened = false;

      await tester.pumpWidget(
        wrap(
          MealReminderScreen(
            slot: ReminderSlot.lunch,
            state: state,
            services: services,
            onOpenHunt: (slot, date) {
              huntOpened = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('غذایی برای ناهار امروز رزرو نشده است'), findsOneWidget);
      expect(find.text('خرید از سبد غذا (شکار)'), findsOneWidget);

      await tester.tap(find.text('خرید از سبد غذا (شکار)'));
      await tester.pumpAndSettle();

      expect(huntOpened, isTrue);
    });

    testWidgets('displays cached forgot receipt code directly with copy and share', (tester) async {
      final accountId = state.accounts.first.id;

      services.mealStore.store.put(StoredMeal(
        accountId: accountId,
        date: today,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: DateTime.utc(2026, 10, 18),
        dishName: 'زرشک پلو با مرغ',
        hallName: 'سلف مرکزی',
        priceRial: 220000,
      ));

      // Record a cached receipt
      state.recordReceipt(accountId, today, MealSlot.lunch, '982341');

      await tester.pumpWidget(
        wrap(
          MealReminderScreen(
            slot: ReminderSlot.lunch,
            state: state,
            services: services,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('کد فیش فراموشی کارت شما:'), findsOneWidget);
      expect(find.text('982341'), findsOneWidget);
      expect(find.byIcon(Icons.copy), findsOneWidget);
      expect(find.byIcon(Icons.share), findsOneWidget);

      // Tap share
      await tester.tap(find.byIcon(Icons.share));
      await tester.pumpAndSettle();

      expect(bridge.sharedText, contains('982341'));
      expect(bridge.sharedText, contains('زرشک پلو با مرغ'));
    });

    testWidgets('calls onForgotReceipt and onSellMeal when buttons pressed', (tester) async {
      final accountId = state.accounts.first.id;
      bool receiptRequested = false;
      bool sellRequested = false;

      services.mealStore.store.put(StoredMeal(
        accountId: accountId,
        date: today,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: DateTime.utc(2026, 10, 18),
        dishName: 'ماکارونی با گوشت',
        hallName: 'سلف مرکزی',
        priceRial: 180000,
      ));

      await tester.pumpWidget(
        wrap(
          MealReminderScreen(
            slot: ReminderSlot.lunch,
            state: state,
            services: services,
            onForgotReceipt: (d, s, dish, type, {targetAccount}) async {
              receiptRequested = true;
            },
            onSellMeal: (d, s, dish, {targetAccount}) async {
              sellRequested = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('دریافت فیش فراموشی'), findsOneWidget);
      expect(find.text('فروش به سبد غذا'), findsOneWidget);

      await tester.tap(find.text('دریافت فیش فراموشی'));
      await tester.pumpAndSettle();
      expect(receiptRequested, isTrue);

      await tester.tap(find.text('فروش به سبد غذا'));
      await tester.pumpAndSettle();
      expect(sellRequested, isTrue);
    });
  });

  group('Deep Link Routing to MealReminderScreen in HomeShell', () {
    testWidgets('incoming deep link reminder/lunch opens MealReminderScreen', (tester) async {
      await tester.pumpWidget(
        wrap(
          HomeShell(
            services: services,
            state: state,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Trigger the deep link via the platform bridge
      expect(bridge.huntHandler, isNotNull);
      bridge.huntHandler!('reminder/lunch');
      await tester.pumpAndSettle();

      expect(find.byType(MealReminderScreen), findsOneWidget);
      expect(find.text('وعده‌های ناهار امروز'), findsOneWidget);
    });

    testWidgets('incoming deep link reminder://evening opens MealReminderScreen', (tester) async {
      await tester.pumpWidget(
        wrap(
          HomeShell(
            services: services,
            state: state,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Trigger the evening deep link
      bridge.huntHandler!('reminder://evening');
      await tester.pumpAndSettle();

      expect(find.byType(MealReminderScreen), findsOneWidget);
      expect(find.text('وعده‌های شام و صبحانه'), findsOneWidget);
    });
  });
}
