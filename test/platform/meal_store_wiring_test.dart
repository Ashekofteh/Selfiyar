import 'package:bahonar_nut/core/local_meal_store.dart';
import 'package:bahonar_nut/core/meal_invariant.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/platform_stores.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/session.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/platform/platform_bridge.dart';
import 'package:bahonar_nut/platform/platform_services.dart';
import '../helpers/portal_stubs.dart' show FakePortalClient;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-memory [PlainStore].
class _MemoryPlainStore implements PlainStore {
  final Map<String, Object> values = {};

  @override
  Future<String?> readString(String key) async => values[key] as String?;

  @override
  Future<void> writeString(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<int?> readInt(String key) async => values[key] as int?;

  @override
  Future<void> writeInt(String key, int value) async => values[key] = value;

  @override
  Future<bool?> readBool(String key) async => values[key] as bool?;

  @override
  Future<void> writeBool(String key, bool value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);

  @override
  Future<Set<String>> keys() async => values.keys.toSet();
}

/// A [SecureCredentialStore] that stores nothing.
class _EmptySecureStore implements SecureCredentialStore {
  @override
  Future<Credentials?> read(AccountId accountId) async => null;

  @override
  Future<void> write(AccountId accountId, Credentials credentials) async {}

  @override
  Future<void> delete(AccountId accountId) async {}

  @override
  Future<List<AccountId>> listAccountIds() async => const [];
}

/// A [SessionStore] that always yields a usable session.
class _AlwaysStore implements SessionStore {
  @override
  Future<Credentials?> readCredentials(AccountId accountId) async =>
      const Credentials(studentId: '400123456', password: 'pw');

  @override
  Future<void> writeCredentials(AccountId a, Credentials c) async {}

  @override
  Future<StoredSession?> readSession(AccountId accountId) async =>
      StoredSession(
        accountId: accountId,
        cookies: const {'ASP.NET_SessionId': 'live'},
        establishedAt: DateTime.now().toUtc(),
      );

  @override
  Future<void> writeSession(StoredSession session) async {}

  @override
  Future<void> deleteSession(AccountId accountId) async {}

  @override
  Future<void> purge(AccountId accountId) async {}
}

class _NoopSolver implements ChallengeSolver {
  @override
  Future<String?> solve(LoginChallenge challenge) async => '1234';
}

/// A portal that serves nothing. The wiring test never reads it.
class _EmptyClient extends FakePortalClient {
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
  Future<List<MealMenu>> fetchMenu(Session s, DateTime date) async => const [];

  @override
  Future<BookableMenus> fetchBookableMenus(Session s, {int days = 7}) async =>
      const BookableMenus(dates: [], menus: []);

  @override
  Future<List<Reservation>> fetchReservations(Session session) async =>
      const [];

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async =>
      const [];

  @override
  Future<BasketPage> fetchBasket(Session session, {String? cursor}) async =>
      const BasketPage(listings: []);

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
  }) async =>
      null;

  @override
  Future<CancelOutcome> cancel(Session session, MealRef ref) async =>
      const CancelSucceeded();

  @override
  Uri? topUpUrl(Session session) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ir.ac.uk.bahonar_nut/platform');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
  });

  group('the one shared store', () {
    test('the services hand out the same store every time', () {
      // The defect this guards against: the holder was a **getter**, so every
      // call built a fresh store. The sync filled one and the screens read
      // another, and everything was permanently empty.
      final client = _EmptyClient();
      final services = AppServices(
        bridge: PlatformBridge(channel: channel),
        client: client,
        sessions: SessionManager(
          client: client,
          store: _AlwaysStore(),
          solver: _NoopSolver(),
          clock: FixedServerClock.now(DateTime.utc(2026, 10, 20, 12)),
        ),
        credentialStore: _EmptySecureStore(),
        plainStore: _MemoryPlainStore(),
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 20, 12)),
      );

      expect(
        identical(services.mealStore.store, services.mealStore.store),
        isTrue,
        reason: 'two reads of the services must reach the same store',
      );
    });

    test('the reminder service reads the same store the services own', () {
      // The digest is built from the store, so a separate instance here would
      // make every digest empty however full the mirror is.
      final client = _EmptyClient();
      final services = AppServices(
        bridge: PlatformBridge(channel: channel),
        client: client,
        sessions: SessionManager(
          client: client,
          store: _AlwaysStore(),
          solver: _NoopSolver(),
          clock: FixedServerClock.now(DateTime.utc(2026, 10, 20, 12)),
        ),
        credentialStore: _EmptySecureStore(),
        plainStore: _MemoryPlainStore(),
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 20, 12)),
      );

      services.mealStore.store.put(StoredMeal(
        accountId: 'a1',
        date: DateTime.utc(2026, 10, 20),
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: DateTime.utc(2026, 10, 20),
        dishName: 'چلو اکبرجوجه',
      ));

      expect(services.reminders.mealStore.count, 1,
          reason: 'the digest reads the very store the app fills');
    });

    test('the store survives a restart', () async {
      // The offline-first promise: a reminder must fire with no network, so
      // the mirror has to be on disk.
      final plain = _MemoryPlainStore();
      final holder = LocalMealStoreHolder(plain);
      final testDate = DateTime.now().toUtc().add(const Duration(days: 7));

      holder.store.put(StoredMeal(
        accountId: 'a1',
        date: testDate,
        slot: MealSlot.lunch,
        source: MealSource.basketPurchase,
        capturedAt: DateTime.now().toUtc(),
        dishName: 'چلو اکبرجوجه',
      ));
      await holder.persist();

      // A fresh holder over the same disk is what a restart looks like.
      final afterRestart = LocalMealStoreHolder(plain);
      expect(afterRestart.store.count, 0,
          reason: 'nothing is loaded until the mirror is restored');
      await afterRestart.restore();

      expect(afterRestart.store.count, 1);
      final meal = afterRestart.store.find(
          'a1', testDate, MealSlot.lunch);
      expect(meal, isNotNull);
      expect(meal!.dishName, 'چلو اکبرجوجه');
      expect(meal.source, MealSource.basketPurchase,
          reason: 'the source survives the round trip');
    });

    test('an empty disk leaves the store empty, and does not fail', () async {
      final holder = LocalMealStoreHolder(_MemoryPlainStore());
      await holder.restore();
      expect(holder.store.count, 0);
    });

    test('a corrupt cache is ignored rather than fatal', () async {
      final plain = _MemoryPlainStore();
      plain.values['meals.held'] = 'not json at all';

      final holder = LocalMealStoreHolder(plain);
      await holder.restore();

      expect(holder.store.count, 0,
          reason: 'a corrupt cache is refilled by the next sync');
    });
  });
}
