import 'package:bahonar_nut/core/local_meal_store.dart';
import 'package:bahonar_nut/core/meal_invariant.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/session.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/platform/portal_sync.dart';
import '../helpers/portal_stubs.dart' show FakePortalClient;
import 'package:test/test.dart';

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

/// A portal that serves a fixed set of reservations and transactions.
class _FakePortal extends FakePortalClient {
  List<Reservation> reservations = const [];
  List<Transaction> transactions = const [];

  /// Whether the ledger read should fail, as it does when the portal serves
  /// the grid but not the transaction page.
  bool ledgerFails = false;

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
        cookies: const {'ASP.NET_SessionId': 'x'},
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
      Balance(amountRial: 500000, fetchedAt: DateTime.utc(2026, 10, 20));

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
      reservations;

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async {
    if (ledgerFails) throw StateError('the ledger could not be read');
    return transactions;
  }

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

/// A reservation the weekly grid would report.
Reservation _reservation({
  required DateTime date,
  required MealSlot slot,
  String hall = 'مرکزی برادران',
}) =>
    Reservation(
      id: 'row-${slot.name}-${date.toIso8601String()}',
      date: date,
      slot: slot,
      hall: Hall(id: '1', name: hall),
      option: MenuOption(id: '62738', name: 'چلو اکبرجوجه', priceRial: 500000),
      state: ReservationState.active,
    );

/// A ledger row.
Transaction _tx({
  required String date,
  required MealSlot slot,
  String type = 'رزرو غذا',
  String food = 'چلو اکبرجوجه,دوغ',
  int amount = 500000,
}) =>
    Transaction(
      accountId: 'a1',
      type: type,
      foodName: food,
      slot: slot,
      weekday: 'سه شنبه',
      date: date,
      count: 1,
      amountRial: amount,
    );

void main() {
  // 1405/07/28 = 2026-10-20
  final theDay = DateTime.utc(2026, 10, 20);

  late _FakePortal portal;
  late LocalMealStore store;
  late SessionManager sessions;

  setUp(() {
    portal = _FakePortal();
    store = LocalMealStore();
    sessions = SessionManager(
      client: portal,
      store: _AlwaysStore(),
      solver: _NoopSolver(),
      clock: FixedServerClock.now(DateTime.utc(2026, 10, 20, 12)),
    );
  });

  PortalSync buildSync({Future<void> Function()? persist, void Function()? onChanged}) =>
      PortalSync(
        client: portal,
        sessions: sessions,
        mealStore: store,
        persist: persist,
        onMealsChanged: onChanged,
      );

  group('the mirror', () {
    test('a weekly reservation reaches the store', () async {
      portal.reservations = [
        _reservation(date: theDay, slot: MealSlot.lunch),
      ];

      final result = await buildSync().sync('a1');

      expect(result.ok, isTrue);
      expect(store.count, 1);
      final meal = store.find('a1', theDay, MealSlot.lunch);
      expect(meal, isNotNull);
      expect(meal!.source, MealSource.weeklyReservation);
      expect(meal.dishName, 'چلو اکبرجوجه');
      expect(meal.hallName, 'مرکزی برادران');
    });

    test('a basket purchase reaches the store, because the grid never '
        'shows it', () async {
      // The verified live case: the grids were byte-for-byte identical before
      // and after the purchase, and the meal existed only as a ledger row.
      portal.reservations = const [];
      portal.transactions = [
        _tx(date: '1405/07/28', slot: MealSlot.lunch),
      ];

      await buildSync().sync('a1');

      final meal = store.find('a1', theDay, MealSlot.lunch);
      expect(meal, isNotNull,
          reason: 'a basket purchase is invisible to the reservation grid, so '
              'the ledger is the only place it can come from');
      expect(meal!.source, MealSource.basketPurchase);
      expect(meal.dishName, 'چلو اکبرجوجه,دوغ');
      expect(meal.priceRial, 500000);
    });

    test('a released meal is not held', () async {
      // The newest event for a (date, slot) wins, and a withdrawal means the
      // meal was given up.
      portal.transactions = [
        _tx(date: '1405/07/28', slot: MealSlot.lunch,
            type: 'انصراف از رزرو غذا'),
        _tx(date: '1405/07/28', slot: MealSlot.lunch),
      ];

      await buildSync().sync('a1');

      expect(store.find('a1', theDay, MealSlot.lunch), isNull);
    });

    test('a meal booked, released and booked again is held once', () async {
      portal.transactions = [
        _tx(date: '1405/07/28', slot: MealSlot.lunch),
        _tx(date: '1405/07/28', slot: MealSlot.lunch,
            type: 'انصراف از رزرو غذا'),
        _tx(date: '1405/07/28', slot: MealSlot.lunch),
      ];

      await buildSync().sync('a1');

      expect(store.count, 1);
      expect(store.find('a1', theDay, MealSlot.lunch), isNotNull);
    });

    test('a meal in both sources is not counted twice', () async {
      // The grid's version wins: it carries the hall and the option id.
      portal.reservations = [
        _reservation(date: theDay, slot: MealSlot.lunch),
      ];
      portal.transactions = [
        _tx(date: '1405/07/28', slot: MealSlot.lunch),
      ];

      await buildSync().sync('a1');

      expect(store.count, 1, reason: 'one meal, one slot');
      final meal = store.find('a1', theDay, MealSlot.lunch)!;
      expect(meal.source, MealSource.weeklyReservation);
      expect(meal.hallName, 'مرکزی برادران',
          reason: 'the grid knows the hall; the ledger does not');
    });

    test('a meal the grid reports keeps its source, even from the ledger',
        () async {
      // The live defect (2026-10-21): the account holds a breakfast on
      // 1405/08/03 — a **next-week** date. A read that stopped at the
      // current week did not see it, so the mirror fell back to the ledger.
      //
      // And the ledger cannot tell the two sources apart: it records a
      // weekly reservation and a Food Basket purchase the same way. So the
      // meal was filed as an **irreversible basket purchase**, and the table
      // showed «خریداری شده» with no cancel button on a meal the portal would
      // have let the student give back.
      //
      // The grid is the authority on what a meal **is**, and the ledger is
      // only the authority on meals the grid does not show (F16).
      portal.reservations = [
        _reservation(date: DateTime.utc(2026, 10, 25), slot: MealSlot.breakfast),
      ];
      portal.transactions = [
        _tx(date: '1405/08/03', slot: MealSlot.breakfast, amount: 150000),
      ];

      await buildSync().sync('a1');

      final meal = store.find('a1', DateTime.utc(2026, 10, 25), MealSlot.breakfast);
      expect(meal, isNotNull);
      expect(meal!.source, MealSource.weeklyReservation,
          reason: 'the grid says this is a weekly reservation, so it is one '
              '— and it can be cancelled');
      expect(meal.hallName, 'مرکزی برادران');
    });

    test('a ledger that cannot be read does not fail the sync', () async {
      // The ledger is a bonus source. A portal that serves the grid but not
      // the transaction page is still worth mirroring.
      portal.ledgerFails = true;
      portal.reservations = [
        _reservation(date: theDay, slot: MealSlot.lunch),
      ];

      final result = await buildSync().sync('a1');

      expect(result.ok, isTrue);
      expect(store.count, 1);
    });

    test('the mirror is persisted after a sync', () async {
      portal.reservations = [
        _reservation(date: theDay, slot: MealSlot.lunch),
      ];
      var persisted = false;

      await buildSync(persist: () async => persisted = true).sync('a1');

      expect(persisted, isTrue,
          reason: 'the mirror must survive a restart, or the offline '
              'reminders have nothing to read');
    });

    test('the change is announced, so the screens redraw', () async {
      portal.reservations = [
        _reservation(date: theDay, slot: MealSlot.lunch),
      ];
      var announced = false;

      await buildSync(onChanged: () => announced = true).sync('a1');

      expect(announced, isTrue);
    });

    test('the transactions are returned for the dashboard', () async {
      portal.transactions = [
        _tx(date: '1405/07/28', slot: MealSlot.lunch),
      ];

      final result = await buildSync().sync('a1');

      expect(result.transactions, hasLength(1),
          reason: 'the spend metric is computed from the ledger');
    });

    test('a meal that is already behind is not mirrored', () async {
      // The ledger is the account's whole history. Mirroring all of it would
      // put every lunch the student has had since the semester began into
      // the reminder — which is what the device run showed: a digest
      // listing 17 lunches.
      //
      // 1405/07/20 = 2026-10-11, ten days before the clock's today.
      portal.transactions = [
        _tx(date: '1405/07/20', slot: MealSlot.lunch),
        _tx(date: '1405/08/05', slot: MealSlot.lunch),
      ];

      await buildSync().sync('a1');

      expect(store.count, 1, reason: 'only the meal that is still ahead');
      expect(store.find('a1', DateTime.utc(2026, 10, 27), MealSlot.lunch),
          isNotNull);
      expect(store.find('a1', DateTime.utc(2026, 10, 11), MealSlot.lunch),
          isNull);
    });

    test('initial sync with empty meal store emits no status changes', () async {
      portal.reservations = [
        _reservation(date: theDay, slot: MealSlot.lunch),
      ];

      final result = await buildSync().sync('a1');
      expect(result.statusChanges, isEmpty);
    });

    test('detects consumed meal status change', () async {
      // 1. Initial sync stores active unconsumed meal
      portal.reservations = [
        _reservation(date: theDay, slot: MealSlot.lunch),
      ];
      await buildSync().sync('a1');

      // 2. Next sync: the reservation is now marked consumed
      portal.reservations = [
        Reservation(
          id: 'row-lunch-${theDay.toIso8601String()}',
          date: theDay,
          slot: MealSlot.lunch,
          hall: const Hall(id: '1', name: 'مرکزی برادران'),
          option: const MenuOption(id: '62738', name: 'چلو اکبرجوجه', priceRial: 500000),
          state: ReservationState.consumed,
        ),
      ];

      final result = await buildSync().sync('a1');
      expect(result.statusChanges, hasLength(1));
      expect(result.statusChanges.first.type, MealChangeType.consumed);
      expect(result.statusChanges.first.slot, MealSlot.lunch);
      expect(result.statusChanges.first.date, theDay);
    });

    test('detects cancelled meal status change for upcoming meal', () async {
      // 1. Initial sync has upcoming meal
      final futureDay = theDay.add(const Duration(days: 2));
      portal.reservations = [
        _reservation(date: futureDay, slot: MealSlot.lunch),
      ];
      await buildSync().sync('a1');

      // 2. Portal no longer has that reservation
      portal.reservations = const [];
      final result = await buildSync().sync('a1');

      expect(result.statusChanges, hasLength(1));
      expect(result.statusChanges.first.type, MealChangeType.cancelled);
      expect(result.statusChanges.first.slot, MealSlot.lunch);
      expect(result.statusChanges.first.date, futureDay);
    });

    test('detects newly booked meal status change', () async {
      // 1. Initial sync with meal A
      portal.reservations = [
        _reservation(date: theDay, slot: MealSlot.lunch),
      ];
      await buildSync().sync('a1');

      // 2. Next sync has meal A and meal B
      final futureDay = theDay.add(const Duration(days: 2));
      portal.reservations = [
        _reservation(date: theDay, slot: MealSlot.lunch),
        _reservation(date: futureDay, slot: MealSlot.dinner),
      ];
      final result = await buildSync().sync('a1');

      expect(result.statusChanges, hasLength(1));
      expect(result.statusChanges.first.type, MealChangeType.booked);
      expect(result.statusChanges.first.slot, MealSlot.dinner);
      expect(result.statusChanges.first.date, futureDay);
    });
  });
}
