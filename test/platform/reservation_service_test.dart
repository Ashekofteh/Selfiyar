import 'package:bahonar_nut/core/local_meal_store.dart';
import 'package:bahonar_nut/core/meal_invariant.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/session.dart';
import 'package:bahonar_nut/core/session_manager.dart';
import 'package:bahonar_nut/core/time.dart';
import 'package:bahonar_nut/platform/reservation_service.dart';
import '../helpers/portal_stubs.dart' show FakePortalClient;
import 'package:test/test.dart';

/// A session store that always yields a usable session.
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

/// A portal that serves a fixed balance and records what it was asked to do.
class _FakePortal extends FakePortalClient {
  _FakePortal() : super(balanceRial: 500000);

  /// The offerings the portal was asked to reserve.
  final reserved = <MealOffering>[];

  /// Whether the reserve should fail.
  bool reserveFails = false;

  /// What the portal answers a cancel with.
  CancelOutcome cancelOutcome = const CancelSucceeded();

  /// The meals the cancel was asked for.
  final cancelled = <MealRef>[];

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
      Balance(amountRial: balanceRial, fetchedAt: DateTime.utc(2026, 10, 20));

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

  Future<List<Reservation>> Function(Session, List<MealOffering>)?
      reserveAllHandler;

  @override
  Future<Reservation> reserve(Session session, MealOffering offering) async {
    if (reserveFails) throw StateError('the portal refused');
    reserved.add(offering);
    return Reservation(
      id: 'r1',
      date: offering.date,
      slot: offering.slot,
      hall: offering.hall,
      option: offering.option,
      state: ReservationState.active,
    );
  }

  @override
  Future<List<Reservation>> reserveAll(
    Session session,
    List<MealOffering> offerings,
  ) async {
    if (reserveAllHandler != null) {
      return reserveAllHandler!(session, offerings);
    }
    return super.reserveAll(session, offerings);
  }

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
  Future<CancelOutcome> cancel(Session session, MealRef ref) async {
    cancelled.add(ref);
    return cancelOutcome;
  }

  @override
  Uri? topUpUrl(Session session) => null;
}

void main() {
  final day = DateTime.utc(2026, 10, 22);

  late _FakePortal portal;
  late LocalMealStore store;
  late ReservationService service;

  setUp(() {
    portal = _FakePortal();
    store = LocalMealStore();
    service = ReservationService(
      client: portal,
      sessions: SessionManager(
        client: portal,
        store: _AlwaysStore(),
        solver: _NoopSolver(),
        clock: FixedServerClock.now(DateTime.utc(2026, 10, 20, 12)),
      ),
      mealStore: store,
    );
  });

  MealOffering offering({int price = 150000, bool reservable = true}) =>
      MealOffering(
        date: day,
        slot: MealSlot.lunch,
        hall: const Hall(id: '1', name: 'مرکزی برادران'),
        option: MenuOption(id: '62738', name: 'چلو اکبرجوجه', priceRial: price),
        reservable: reservable,
      );

  group('booking a meal', () {
    test('a booking reaches the portal and the mirror', () async {
      final outcome = await service.reserve(
        accountId: 'a1',
        offering: offering(),
      );

      expect(outcome.succeeded, isTrue, reason: outcome.message ?? '');
      expect(portal.reserved, hasLength(1));
      expect(store.find('a1', day, MealSlot.lunch), isNotNull,
          reason: 'the mirror must follow the booking');
    });

    test('a slot the account already holds is refused, and nothing is sent',
        () async {
      // The portal does **not** enforce the one-meal rule (F22): it offers a
      // meal the account already holds and accepts a second booking without
      // complaint. So the app must refuse it — before the request, not after.
      store.put(StoredMeal(
        accountId: 'a1',
        date: day,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: day,
      ));

      final outcome = await service.reserve(
        accountId: 'a1',
        offering: offering(),
      );

      expect(outcome.succeeded, isFalse);
      expect(outcome.failure, ReservationFailure.slotAlreadyHeld);
      expect(portal.reserved, isEmpty,
          reason: 'the refusal must happen before the money could move');
    });

    test('a meal bought from the basket also blocks a booking', () async {
      store.put(StoredMeal(
        accountId: 'a1',
        date: day,
        slot: MealSlot.lunch,
        source: MealSource.basketPurchase,
        capturedAt: day,
      ));

      final outcome = await service.reserve(
        accountId: 'a1',
        offering: offering(),
      );

      expect(outcome.succeeded, isFalse,
          reason: 'one meal per slot per day, from either source');
    });

    test('a locked date is refused, and nothing is sent', () async {
      final outcome = await service.reserve(
        accountId: 'a1',
        offering: offering(reservable: false),
      );

      expect(outcome.succeeded, isFalse);
      expect(outcome.failure, ReservationFailure.locked);
      expect(portal.reserved, isEmpty,
          reason: 'a locked row is ignored by the portal, so the refusal is '
              'cheaper and clearer than a silent no-op');
    });

    test('a balance that cannot cover the meal is refused', () async {
      portal.balanceRial = 100000;

      final outcome = await service.reserve(
        accountId: 'a1',
        offering: offering(price: 500000),
      );

      expect(outcome.succeeded, isFalse);
      expect(outcome.failure, ReservationFailure.insufficientFunds);
      expect(portal.reserved, isEmpty);
    });

    test('a booking the portal refuses is reported, not swallowed', () async {
      portal.reserveFails = true;

      final outcome = await service.reserve(
        accountId: 'a1',
        offering: offering(),
      );

      expect(outcome.succeeded, isFalse);
      expect(outcome.message, isNotNull);
      expect(store.find('a1', day, MealSlot.lunch), isNull,
          reason: 'a failed booking must not appear in the mirror');
    });
  });

  group('cancelling', () {
    /// Puts a held meal in the mirror, so a cancel has something to remove.
    void holdMeal() {
      store.put(StoredMeal(
        accountId: 'a1',
        date: day,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: day,
      ));
    }

    test('a cancel the portal confirms removes the meal from the mirror',
        () async {
      holdMeal();

      final outcome = await service.cancel(
        accountId: 'a1',
        date: day,
        slot: MealSlot.lunch,
      );

      expect(outcome, isA<CancelSucceeded>());
      expect(store.find('a1', day, MealSlot.lunch), isNull);
    });

    test('a refused cancel leaves the meal in the mirror', () async {
      // A locked date is refused **silently** (F14): the portal discards the
      // post and answers 200, so the request cannot tell success from
      // refusal. If the mirror were updated on the strength of the request,
      // the app would hide a meal the student still holds (F63).
      holdMeal();
      portal.cancelOutcome =
          const CancelRefused('مهلت رزرو این تاریخ به پایان رسیده است.');

      final outcome = await service.cancel(
        accountId: 'a1',
        date: day,
        slot: MealSlot.lunch,
      );

      expect(outcome, isA<CancelRefused>());
      expect(store.find('a1', day, MealSlot.lunch), isNotNull,
          reason: 'the portal still holds the meal, so the mirror must too');
    });

    test('an ambiguous cancel leaves the meal in the mirror', () async {
      // The portal could not be read back, so it is not known whether the
      // meal was released. Removing it would be a guess.
      holdMeal();
      portal.cancelOutcome = const CancelAmbiguous('unreadable');

      final outcome = await service.cancel(
        accountId: 'a1',
        date: day,
        slot: MealSlot.lunch,
      );

      expect(outcome, isA<CancelAmbiguous>());
      expect(store.find('a1', day, MealSlot.lunch), isNotNull);
    });

    test('a cancel that could not be sent leaves the meal in the mirror',
        () async {
      holdMeal();
      portal.cancelOutcome = const CancelAmbiguous('offline');

      final outcome = await service.cancel(
        accountId: 'a1',
        date: day,
        slot: MealSlot.lunch,
      );

      expect(outcome, isA<CancelAmbiguous>());
      expect(store.find('a1', day, MealSlot.lunch), isNotNull);
    });
  });

  group('modifying a reservation', () {
    void holdMeal({int price = 150000, String dish = 'چلو جوجه'}) {
      store.put(StoredMeal(
        accountId: 'a1',
        date: day,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: DateTime.now().toUtc(),
        dishName: dish,
        priceRial: price,
      ));
    }

    test('replaces existing reservation even when slot is already held', () async {
      holdMeal();

      final updatedOffering = MealOffering(
        date: day,
        slot: MealSlot.lunch,
        hall: const Hall(id: '2', name: 'سلف زیتون'),
        option: const MenuOption(id: '999', name: 'چلو ماهی', priceRial: 180000),
        reservable: true,
      );

      final outcome = await service.modifyReservation(
        accountId: 'a1',
        offering: updatedOffering,
      );

      expect(outcome.succeeded, isTrue);
      expect(portal.reserved, contains(updatedOffering));
      final held = store.find('a1', day, MealSlot.lunch);
      expect(held?.dishName, 'چلو ماهی');
      expect(held?.hallName, 'سلف زیتون');
    });

    test('refuses modification if offering is locked', () async {
      holdMeal();

      final outcome = await service.modifyReservation(
        accountId: 'a1',
        offering: offering(reservable: false),
      );

      expect(outcome.succeeded, isFalse);
      expect(outcome.failure, ReservationFailure.locked);
      expect(portal.reserved, isEmpty);
    });

    test('refuses modification if balance cannot cover positive price difference', () async {
      holdMeal(price: 100000);
      portal.balanceRial = 20000;

      final outcome = await service.modifyReservation(
        accountId: 'a1',
        offering: offering(price: 150000),
      );

      expect(outcome.succeeded, isFalse);
      expect(outcome.failure, ReservationFailure.insufficientFunds);
      expect(outcome.deficitRial, 30000);
      expect(portal.reserved, isEmpty);
    });

    test('allows modification without balance check if price difference is non-positive', () async {
      holdMeal(price: 200000);
      portal.balanceRial = 0;

      final targetOffering = offering(price: 150000);
      final outcome = await service.modifyReservation(
        accountId: 'a1',
        offering: targetOffering,
      );

      expect(outcome.succeeded, isTrue);
      expect(portal.reserved, contains(targetOffering));
    });
  });

  group('batchReserve', () {
    MealOffering makeOffering({
      MealSlot slot = MealSlot.lunch,
      int price = 150000,
      bool reservable = true,
      DateTime? date,
    }) =>
        MealOffering(
          date: date ?? day,
          slot: slot,
          hall: const Hall(id: '1', name: 'مرکزی برادران'),
          option:
              MenuOption(id: '62738', name: 'چلو اکبرجوجه', priceRial: price),
          reservable: reservable,
        );

    test('returns empty outcome when offerings list is empty', () async {
      final outcome = await service.batchReserve(
        accountId: 'a1',
        offerings: const [],
      );
      expect(outcome.isFullSuccess, isTrue);
      expect(outcome.succeeded, isEmpty);
      expect(outcome.failed, isEmpty);
      expect(portal.reserved, isEmpty);
    });

    test(
        'refuses entire batch upfront if balance is less than total sum (no partial reservation)',
        () async {
      portal.balanceRial = 60000; // 60,000 Rial
      final off1 = makeOffering(slot: MealSlot.lunch, price: 50000);
      final off2 = makeOffering(slot: MealSlot.dinner, price: 50000); // total 100,000 > 60,000

      final outcome = await service.batchReserve(
        accountId: 'a1',
        offerings: [off1, off2],
      );

      expect(outcome.isFullSuccess, isFalse);
      expect(outcome.failure, ReservationFailure.insufficientFunds);
      expect(outcome.deficitRial, 40000);
      expect(outcome.succeeded, isEmpty);
      // Zero calls made to the portal — atomic refusal prevents partial debit and unexpected popups!
      expect(portal.reserved, isEmpty);
      expect(store.find('a1', day, MealSlot.lunch), isNull);
      expect(store.find('a1', day, MealSlot.dinner), isNull);
    });

    test('refuses batch if all offerings conflict with already held slots',
        () async {
      store.put(StoredMeal(
        accountId: 'a1',
        date: day,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        capturedAt: DateTime.now().toUtc(),
        dishName: 'چلو جوجه',
        priceRial: 150000,
      ));

      final off1 = makeOffering(slot: MealSlot.lunch);
      final outcome = await service.batchReserve(
        accountId: 'a1',
        offerings: [off1],
      );

      expect(outcome.isFullSuccess, isFalse);
      expect(outcome.failure, ReservationFailure.slotAlreadyHeld);
      expect(portal.reserved, isEmpty);
    });

    test(
        'successfully reserves all offerings and updates meal store when balance is sufficient',
        () async {
      portal.balanceRial = 500000;
      final off1 = makeOffering(slot: MealSlot.lunch, price: 100000);
      final off2 = makeOffering(slot: MealSlot.dinner, price: 150000);

      final outcome = await service.batchReserve(
        accountId: 'a1',
        offerings: [off1, off2],
      );

      expect(outcome.isFullSuccess, isTrue);
      expect(outcome.succeeded.length, 2);
      expect(portal.reserved, containsAll([off1, off2]));

      final heldLunch = store.find('a1', day, MealSlot.lunch);
      final heldDinner = store.find('a1', day, MealSlot.dinner);
      expect(heldLunch, isNotNull);
      expect(heldDinner, isNotNull);
      expect(heldLunch?.priceRial, 100000);
      expect(heldDinner?.priceRial, 150000);
    });

    test(
        'records succeeded meals in meal store and reports failed when partial reservation occurs',
        () async {
      portal.balanceRial = 500000;
      final off1 = makeOffering(slot: MealSlot.lunch, price: 100000);
      final off2 = makeOffering(slot: MealSlot.dinner, price: 150000);

      portal.reserveAllHandler = (session, offerings) async {
        portal.reserved.add(off1);
        return [
          Reservation(
            id: 'r1',
            date: off1.date,
            slot: off1.slot,
            hall: off1.hall,
            option: off1.option,
            state: ReservationState.active,
          ),
        ];
      };

      final outcome = await service.batchReserve(
        accountId: 'a1',
        offerings: [off1, off2],
      );

      expect(outcome.isFullSuccess, isFalse);
      expect(outcome.succeeded.length, 1);
      expect(outcome.failed.length, 1);
      expect(outcome.failed.first, off2);

      // off1 MUST be recorded in the store!
      final heldLunch = store.find('a1', day, MealSlot.lunch);
      final heldDinner = store.find('a1', day, MealSlot.dinner);
      expect(heldLunch, isNotNull);
      expect(heldDinner, isNull);
    });
  });
}
