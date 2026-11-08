import 'package:bahonar_nut/core/account_store.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/platform/connectivity_service.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:bahonar_nut/platform/platform_services.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:bahonar_nut/ui/home_shell.dart';
import 'package:bahonar_nut/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/memory_stores.dart';
import '../helpers/portal_stubs.dart';

class _TrackingPortalClient extends FakePortalClient {
  _TrackingPortalClient({
    this.bookableResponse = const BookableMenus(dates: [], menus: []),
  });

  BookableMenus bookableResponse;
  int fetchBookableMenusCalls = 0;

  @override
  Future<BookableMenus> fetchBookableMenus(
    Session session, {
    int days = 7,
  }) async {
    fetchBookableMenusCalls++;
    return bookableResponse;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final baseDate = DateTime.utc(2026, 10, 24); // Saturday
  final clock = FixedServerClock.now(DateTime.utc(2026, 10, 20, 12));

  MealMenu testMenu(DateTime date, MealSlot slot, String dishName) => MealMenu(
        date: date,
        slot: slot,
        reservable: true,
        halls: const [Hall(id: 'h1', name: 'سلف برادران')],
        dishes: [
          MenuOption(id: 'd1', name: dishName, priceRial: 500000),
        ],
      );

  group('OfflineBanner Component Tests', () {
    testWidgets('displays offline message and icon when isOffline is true', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              body: OfflineBanner(isOffline: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(OfflineBanner), findsOneWidget);
      expect(find.byIcon(Icons.wifi_off_rounded), findsOneWidget);
      expect(
        find.textContaining('حالت آفلاین • به اینترنت متصل نیستید'),
        findsOneWidget,
      );
    });

    testWidgets('shows green restored message briefly when switching from offline to online', (tester) async {
      var isOffline = true;
      late StateSetter setStateCallback;

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            setStateCallback = setState;
            return MaterialApp(
              home: Directionality(
                textDirection: TextDirection.rtl,
                child: Scaffold(
                  body: OfflineBanner(isOffline: isOffline),
                ),
              ),
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.wifi_off_rounded), findsOneWidget);

      // Transition to online
      setStateCallback(() {
        isOffline = false;
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Should now show the restored message
      expect(find.byIcon(Icons.wifi_rounded), findsOneWidget);
      expect(find.text('اتصال به اینترنت برقرار شد'), findsOneWidget);

      // After 3 seconds, it should dismiss
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text('اتصال به اینترنت برقرار شد'), findsNothing);
    });
  });

  group('HomeShell Offline & Cache Integration Tests', () {
    late _TrackingPortalClient portal;
    late AppState state;
    late ConnectivityService connectivity;
    late AppServices services;

    Future<void> setupShell(
      WidgetTester tester, {
      bool initialOnline = true,
      List<MealMenu> initialCachedMenus = const [],
      BookableMenus? serverBookableMenus,
    }) async {
      portal = _TrackingPortalClient(
        bookableResponse: serverBookableMenus ??
            const BookableMenus(dates: [], menus: []),
      );
      connectivity = ConnectivityService(
        checkHost: () async => connectivity.isOnline,
        initialOnline: initialOnline,
      );

      final plainStore = MemoryPlainStore();
      final secureStore = MemorySecureStore();

      services = AppServices(
        bridge: PlatformBridge(),
        client: portal,
        sessions: SessionManager(
          client: portal,
          store: MemorySessionStore(),
          solver: NoSolver(),
          clock: clock,
        ),
        credentialStore: secureStore,
        plainStore: plainStore,
        clock: clock,
        connectivity: connectivity,
      );
      addTearDown(() => services.dispose());

      // Pre-fill local menu cache
      for (final menu in initialCachedMenus) {
        services.menuStore.store.put(menu);
      }
      if (initialCachedMenus.isNotEmpty) {
        await services.menuStore.persist();
      }

      state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
        huntConfigStore: InMemoryHuntConfigStore(),
        credentialStore: secureStore,
        plainStore: plainStore,
        clock: clock,
        mealStore: services.mealStore.store,
        menuStore: services.menuStore.store,
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

    testWidgets('Instant load: cached menu displays in reservations table immediately', (tester) async {
      final cachedMenu = testMenu(baseDate, MealSlot.lunch, 'چلو قیمه بادمجان سنتی');
      await setupShell(
        tester,
        initialOnline: true,
        initialCachedMenus: [cachedMenu],
      );

      // Navigate to reservations tab
      await tester.tap(find.text('رزروها'));
      await tester.pumpAndSettle();

      // Dish name from cache should be immediately visible
      expect(find.textContaining('چلو قیمه بادمجان سنتی'), findsOneWidget);
    });

    testWidgets('Offline startup: does not make network calls and displays offline banner', (tester) async {
      final cachedMenu = testMenu(baseDate, MealSlot.lunch, 'کباب بختیاری ذخیره');
      await setupShell(
        tester,
        initialOnline: false,
        initialCachedMenus: [cachedMenu],
      );

      // Startup auto-refresh should NOT call portal fetchBookableMenus
      expect(portal.fetchBookableMenusCalls, 0);

      // Check offline banner is shown
      expect(find.byType(OfflineBanner), findsWidgets);
      expect(find.byIcon(Icons.wifi_off_rounded), findsWidgets);

      // Navigate to reservations tab
      await tester.tap(find.text('رزروها'));
      await tester.pumpAndSettle();

      // Cached dish is displayed even while offline
      expect(find.textContaining('کباب بختیاری ذخیره'), findsOneWidget);
    });

    testWidgets('Manual refresh while offline shows informative Persian SnackBar', (tester) async {
      await setupShell(tester, initialOnline: false);

      // Tap the refresh button
      final refreshButton = find.byType(RotatingRefreshButton);
      expect(refreshButton, findsOneWidget);
      await tester.tap(refreshButton);
      await tester.pump();

      // Verify polite Persian offline message
      expect(
        find.text('اتصال به اینترنت برقرار نیست. آخرین اطلاعات ذخیره‌شده نمایش داده می‌شوند.'),
        findsOneWidget,
      );
    });

    testWidgets('Refresh revalidates menu and notifies user with SnackBar when changes occur', (tester) async {
      final cachedMenu = testMenu(baseDate, MealSlot.lunch, 'غذای قبلی در حافظه');
      final newServerMenu = testMenu(baseDate, MealSlot.lunch, 'غذای سرور تازه');

      await setupShell(
        tester,
        initialOnline: true,
        initialCachedMenus: [cachedMenu],
        serverBookableMenus: BookableMenus(
          dates: [baseDate],
          menus: [newServerMenu],
        ),
      );

      // Navigate to reservations tab - initial cached menu displayed immediately
      await tester.tap(find.text('رزروها'));
      await tester.pumpAndSettle();
      expect(find.textContaining('غذای قبلی در حافظه'), findsOneWidget);

      // Trigger refresh
      final refreshButton = find.byType(RotatingRefreshButton);
      expect(refreshButton, findsOneWidget);
      await tester.tap(refreshButton);
      await tester.pump();
      await tester.pumpAndSettle();

      // Verify portal fetchBookableMenus was invoked
      expect(portal.fetchBookableMenusCalls, greaterThanOrEqualTo(1));

      // SnackBar notifying user of meal schedule update is shown
      expect(find.text('برنامه غذایی به‌روزرسانی شد.'), findsOneWidget);

      // Updated dish is visible
      expect(find.textContaining('غذای سرور تازه'), findsOneWidget);
    });

    testWidgets('Refresh does not show SnackBar when menu is unchanged', (tester) async {
      final identicalMenu = testMenu(baseDate, MealSlot.lunch, 'غذای بدون تغییر');

      await setupShell(
        tester,
        initialOnline: true,
        initialCachedMenus: [identicalMenu],
        serverBookableMenus: BookableMenus(
          dates: [baseDate],
          menus: [identicalMenu],
        ),
      );

      // Navigate to reservations tab
      await tester.tap(find.text('رزروها'));
      await tester.pumpAndSettle();

      // Trigger refresh
      final refreshButton = find.byType(RotatingRefreshButton);
      await tester.tap(refreshButton);
      await tester.pump();
      await tester.pumpAndSettle();

      // Menu fetch occurred
      expect(portal.fetchBookableMenusCalls, greaterThanOrEqualTo(1));

      // No spurious SnackBar since nothing changed
      expect(find.text('برنامه غذایی به‌روزرسانی شد.'), findsNothing);
    });

    testWidgets('Manual refresh while offline performs active check and recovers if connection restored', (tester) async {
      var simulatedOnline = false;
      portal = _TrackingPortalClient(
        bookableResponse: const BookableMenus(dates: [], menus: []),
      );
      connectivity = ConnectivityService(
        checkHost: () async => simulatedOnline,
        initialOnline: false,
      );

      final plainStore = MemoryPlainStore();
      final secureStore = MemorySecureStore();

      services = AppServices(
        bridge: PlatformBridge(),
        client: portal,
        sessions: SessionManager(
          client: portal,
          store: MemorySessionStore(),
          solver: NoSolver(),
          clock: clock,
        ),
        credentialStore: secureStore,
        plainStore: plainStore,
        clock: clock,
        connectivity: connectivity,
      );
      addTearDown(() => services.dispose());

      state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
        huntConfigStore: InMemoryHuntConfigStore(),
        credentialStore: secureStore,
        plainStore: plainStore,
        clock: clock,
        mealStore: services.mealStore.store,
        menuStore: services.menuStore.store,
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

      expect(services.connectivity.isOffline, isTrue);

      // Connection restored in real life (e.g. Wi-Fi reconnected)
      simulatedOnline = true;

      // User taps refresh button
      final refreshButton = find.byType(RotatingRefreshButton);
      expect(refreshButton, findsOneWidget);
      await tester.tap(refreshButton);
      await tester.pump();
      await tester.pumpAndSettle();

      // State automatically recovered to online and refresh completed
      expect(services.connectivity.isOnline, isTrue);
      expect(portal.fetchBookableMenusCalls, greaterThanOrEqualTo(1));
    });

    testWidgets('Restoring connectivity triggers background revalidation and updates menuStore', (tester) async {
      final oldMenu = testMenu(baseDate, MealSlot.lunch, 'غذای قدیمی');
      final newMenu = testMenu(baseDate, MealSlot.lunch, 'غذای تازه به‌روزشده');

      await setupShell(
        tester,
        initialOnline: false,
        initialCachedMenus: [oldMenu],
        serverBookableMenus: BookableMenus(
          dates: [baseDate],
          menus: [newMenu],
        ),
      );

      // Start on reservations tab
      await tester.tap(find.text('رزروها'));
      await tester.pumpAndSettle();
      expect(find.textContaining('غذای قدیمی'), findsOneWidget);

      // Bring connectivity back online
      connectivity.markOnline();
      await tester.pump();
      await tester.pumpAndSettle();

      // Background revalidation was triggered
      expect(portal.fetchBookableMenusCalls, greaterThanOrEqualTo(1));

      // UI should now reflect the updated dish name smoothly
      expect(find.textContaining('غذای تازه به‌روزشده'), findsOneWidget);

      // Local store has also updated and persisted
      expect(
        services.menuStore.store.find(baseDate, MealSlot.lunch)!.dishes.first.name,
        'غذای تازه به‌روزشده',
      );
    });
  });
}
