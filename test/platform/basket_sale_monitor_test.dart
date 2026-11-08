import 'package:bahonar_nut/core/account.dart';
import 'package:bahonar_nut/core/account_store.dart';
import 'package:bahonar_nut/core/local_meal_store.dart';
import 'package:bahonar_nut/core/meal_invariant.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/session.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/platform/basket_sale_monitor.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:bahonar_nut/platform/portal_sync.dart';
import 'package:bahonar_nut/ui/app_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bahonar_nut/core/time.dart';
import '../helpers/memory_stores.dart';
import '../helpers/portal_stubs.dart' show FakePortalClient;

class _FakePortal extends FakePortalClient {
  List<Reservation> reservations = [];
  List<Transaction> transactions = [];

  @override
  Future<List<Reservation>> fetchReservations(Session session) async =>
      reservations;

  @override
  Future<List<Transaction>> fetchTransactions(
    Session session, {
    DateTime? from,
    DateTime? to,
  }) async =>
      transactions;

  @override
  Future<Balance> fetchBalance(Session session) async => Balance(
        amountRial: 100000,
        fetchedAt: DateTime.now(),
      );
}

class _TrackingPortalSync extends PortalSync {
  _TrackingPortalSync({
    required super.client,
    required super.sessions,
    required super.mealStore,
    super.onMealsChanged,
  });

  int concurrentCount = 0;
  int maxConcurrent = 0;
  final List<String> syncCalls = [];
  bool shouldThrowForAcc2 = false;

  @override
  Future<AccountSyncResult> sync(AccountId accountId) async {
    syncCalls.add(accountId);
    concurrentCount++;
    if (concurrentCount > maxConcurrent) {
      maxConcurrent = concurrentCount;
    }
    try {
      if (shouldThrowForAcc2 && accountId == 'acc2') {
        throw Exception('Simulated network failure for acc2');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return await super.sync(accountId);
    } finally {
      concurrentCount--;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ir.ac.uk.bahonar_nut/platform');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  List<(int, String?)> scheduledAlarms() => [
        for (final call in calls)
          if (call.method == 'scheduleAlarm')
            (
              (call.arguments as Map)['requestCode'] as int,
              (call.arguments as Map)['payload'] as String?,
            ),
      ];

  List<int> cancelledAlarms() => [
        for (final call in calls)
          if (call.method == 'cancelAlarm')
            (call.arguments as Map)['requestCode'] as int,
      ];

  List<Map<String, dynamic>> notifications() => [
        for (final call in calls)
          if (call.method == 'postNotification')
            Map<String, dynamic>.from(call.arguments as Map),
      ];

  group('BasketSaleMonitor', () {
    late _FakePortal portal;
    late SessionManager sessions;
    late LocalMealStore mealStore;
    late PortalSync sync;
    late AppState state;
    late PlatformBridge bridge;
    late MemorySessionStore sessionStore;

    setUp(() async {
      portal = _FakePortal();
      sessionStore = MemorySessionStore();
      await sessionStore.writeSession(
        StoredSession(
          accountId: 'acc1',
          cookies: const {'ASP.NET_SessionId': 'live'},
          establishedAt: DateTime.now().toUtc(),
        ),
      );
      sessions = SessionManager(
        client: portal,
        store: sessionStore,
        solver: NoSolver(),
        clock: SyncedServerClock(),
      );
      mealStore = LocalMealStore();
      state = AppState(
        accountStore: InMemoryAccountStore(),
        reminderConfigStore: InMemoryReminderConfigStore(),
        plainStore: MemoryPlainStore(),
        mealStore: mealStore,
      );
      await state.accountStore.save(
        const SavedAccount(
          id: 'acc1',
          studentId: '401157013',
          alias: 'رضا شریفی',
        ),
      );
      await state.load();

      sync = PortalSync(
        client: portal,
        sessions: sessions,
        mealStore: mealStore,
        onMealsChanged: state.mealsChanged,
      );

      bridge = PlatformBridge(channel: channel);
    });

    test('stays inactive and schedules no alarms when basket is empty',
        () async {
      final monitor = BasketSaleMonitor(
        bridge: bridge,
        state: state,
        sync: sync,
      );

      await monitor.startOrUpdate();

      expect(monitor.isActive, isFalse);
      expect(scheduledAlarms(), isEmpty);
      expect(cancelledAlarms(), contains(BasketSaleMonitor.alarmRequestCode));
    });

    test('starts timer and schedules alarm when meal is listed', () async {
      final futureDate = DateTime.now().add(const Duration(days: 2));
      mealStore.put(
        StoredMeal(
          accountId: 'acc1',
          date: futureDate,
          slot: MealSlot.dinner,
          source: MealSource.weeklyReservation,
          dishName: 'شوید پلو با گوشت چرخی',
          priceRial: 350000,
          capturedAt: DateTime.now(),
        ),
      );

      state.markListedInBasket(
        'acc1',
        futureDate,
        MealSlot.dinner,
        dishName: 'شوید پلو با گوشت چرخی',
        priceRial: 350000,
      );

      final monitor = BasketSaleMonitor(
        bridge: bridge,
        state: state,
        sync: sync,
      );

      await monitor.startOrUpdate();

      expect(monitor.isActive, isTrue);
      expect(scheduledAlarms(), hasLength(1));
      expect(scheduledAlarms().first.$1, BasketSaleMonitor.alarmRequestCode);
      expect(scheduledAlarms().first.$2, BasketSaleMonitor.payload);

      await monitor.stop();
      expect(monitor.isActive, isFalse);
    });

    test('prunes expired meals without network sync and stops if empty',
        () async {
      // Past meal whose distribution cutoff has passed
      final pastDate = DateTime(2020, 1, 1);
      state.markListedInBasket('acc1', pastDate, MealSlot.lunch);

      final monitor = BasketSaleMonitor(
        bridge: bridge,
        state: state,
        sync: sync,
      );

      await monitor.startOrUpdate();

      expect(state.basketSales, isEmpty);
      expect(monitor.isActive, isFalse);
      expect(scheduledAlarms(), isEmpty);
    });

    test('detects sold meal, posts Persian notification with price, and stops',
        () async {
      final futureDate = DateTime.now().add(const Duration(days: 2));

      mealStore.put(
        StoredMeal(
          accountId: 'acc1',
          date: futureDate,
          slot: MealSlot.dinner,
          source: MealSource.weeklyReservation,
          dishName: 'شوید پلو با گوشت چرخی',
          priceRial: 350000,
          capturedAt: DateTime.now(),
        ),
      );

      state.markListedInBasket(
        'acc1',
        futureDate,
        MealSlot.dinner,
        dishName: 'شوید پلو با گوشت چرخی',
        priceRial: 350000,
      );

      final monitor = BasketSaleMonitor(
        bridge: bridge,
        state: state,
        sync: sync,
      );

      state.onBasketSalesChanged = () => monitor.startOrUpdate();
      state.onBasketMealSold =
          (key, accId, date, slot, dishName, priceRial) async {
        await monitor.notifySold(
          dishName: dishName,
          priceRial: priceRial,
        );
      };

      await monitor.startOrUpdate();
      expect(monitor.isActive, isTrue);

      // Now the meal is sold on portal: portal returns 0 reservations for acc1
      portal.reservations = [];

      // Run checkNow
      await monitor.checkNow();

      // Meal was pruned and sold
      expect(state.basketSales, isEmpty);
      expect(monitor.isActive, isFalse);

      // Notification was posted
      final notifs = notifications();
      expect(notifs, isNotEmpty);
      final notif = notifs.first;
      expect(notif['id'], BasketSaleMonitor.notificationId);
      expect(notif['title'], contains('فروش موفق در سبد غذا'));
      expect(notif['body'], contains('شوید پلو با گوشت چرخی'));
      expect(notif['body'], contains('۳۵٬۰۰۰ تومان'));
      expect(notif['deepLink'], 'transactions');

      // Platform alarm was cancelled
      expect(cancelledAlarms(), contains(BasketSaleMonitor.alarmRequestCode));
    });

    test('re-arms alarm when meal remains unsold after checkNow', () async {
      final futureDate = DateTime.now().add(const Duration(days: 2));

      mealStore.put(
        StoredMeal(
          accountId: 'acc1',
          date: futureDate,
          slot: MealSlot.dinner,
          source: MealSource.weeklyReservation,
          dishName: 'شوید پلو با گوشت چرخی',
          priceRial: 350000,
          capturedAt: DateTime.now(),
        ),
      );

      state.markListedInBasket(
        'acc1',
        futureDate,
        MealSlot.dinner,
        dishName: 'شوید پلو با گوشت چرخی',
        priceRial: 350000,
      );

      // Portal still returns the meal
      portal.reservations = [
        Reservation(
          id: 'm1',
          date: futureDate,
          slot: MealSlot.dinner,
          hall: const Hall(id: 'h1', name: 'سلف برادران'),
          option: const MenuOption(
            id: 'o1',
            name: 'شوید پلو با گوشت چرخی',
            priceRial: 350000,
          ),
          state: ReservationState.active,
        ),
      ];

      final monitor = BasketSaleMonitor(
        bridge: bridge,
        state: state,
        sync: sync,
      );

      await monitor.startOrUpdate();
      calls.clear();

      await monitor.checkNow();

      expect(state.basketSales, isNotEmpty);
      expect(monitor.isActive, isTrue);
      expect(notifications(), isEmpty);
      expect(scheduledAlarms(), hasLength(1));

      await monitor.stop();
    });

    test('stopping monitor cancels periodic timer and platform alarm',
        () async {
      final futureDate = DateTime.now().add(const Duration(days: 2));
      state.markListedInBasket('acc1', futureDate, MealSlot.lunch);

      final monitor = BasketSaleMonitor(
        bridge: bridge,
        state: state,
        sync: sync,
      );

      await monitor.startOrUpdate();
      expect(monitor.isActive, isTrue);

      await monitor.stop();
      expect(monitor.isActive, isFalse);
      expect(cancelledAlarms(), contains(BasketSaleMonitor.alarmRequestCode));
    });

    test('checkNow syncs multiple accounts concurrently', () async {
      await sessionStore.writeSession(
        StoredSession(
          accountId: 'acc2',
          cookies: const {'ASP.NET_SessionId': 'live2'},
          establishedAt: DateTime.now().toUtc(),
        ),
      );
      await state.accountStore.save(
        const SavedAccount(
          id: 'acc2',
          studentId: '401157014',
          alias: 'علی حسینی',
        ),
      );
      await state.load();

      final futureDate = DateTime.now().add(const Duration(days: 2));
      state.markListedInBasket('acc1', futureDate, MealSlot.lunch);
      state.markListedInBasket('acc2', futureDate, MealSlot.dinner);

      final trackingSync = _TrackingPortalSync(
        client: portal,
        sessions: sessions,
        mealStore: mealStore,
        onMealsChanged: state.mealsChanged,
      );

      final monitor = BasketSaleMonitor(
        bridge: bridge,
        state: state,
        sync: trackingSync,
      );

      await monitor.checkNow();

      expect(trackingSync.syncCalls, containsAll(['acc1', 'acc2']));
      expect(trackingSync.maxConcurrent, 2,
          reason: 'Both accounts should be synced in parallel');
    });

    test(
        'checkNow isolates errors so failure in one account does not stop others',
        () async {
      await sessionStore.writeSession(
        StoredSession(
          accountId: 'acc2',
          cookies: const {'ASP.NET_SessionId': 'live2'},
          establishedAt: DateTime.now().toUtc(),
        ),
      );
      await state.accountStore.save(
        const SavedAccount(
          id: 'acc2',
          studentId: '401157014',
          alias: 'علی حسینی',
        ),
      );
      await state.load();

      final futureDate = DateTime.now().add(const Duration(days: 2));
      state.markListedInBasket('acc1', futureDate, MealSlot.lunch);
      state.markListedInBasket('acc2', futureDate, MealSlot.dinner);

      final trackingSync = _TrackingPortalSync(
        client: portal,
        sessions: sessions,
        mealStore: mealStore,
        onMealsChanged: state.mealsChanged,
      )..shouldThrowForAcc2 = true;

      final monitor = BasketSaleMonitor(
        bridge: bridge,
        state: state,
        sync: trackingSync,
      );

      // checkNow must complete normally without throwing uncaught exception
      await monitor.checkNow();

      expect(trackingSync.syncCalls, containsAll(['acc1', 'acc2']));
    });
  });
}
