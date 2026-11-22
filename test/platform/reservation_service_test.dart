import 'package:bahonar_nut/core/meal/local_meal_store.dart';
import 'package:bahonar_nut/core/meal/meal_invariant.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/core/auth/session.dart';
import 'package:bahonar_nut/core/auth/session_manager.dart';
import 'package:bahonar_nut/core/shared/time.dart';
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

  /// The total the service asked the batch path to verify on the page.
  int? lastRequiredBalanceRial;

  /// How many times the portal was asked for the balance.
  int balanceReads = 0;

  /// Whether the reserve should fail.
  bool reserveFails = false;

  /// Whether the portal's page refuses the booking for lack of funds. This is
  /// how the real adapter reports a balance read from the write page.
  bool reserveThrowsInsufficient = false;

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
  }) async => Session(
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
  Future<Balance> fetchBalance(Session session) async {
    balanceReads++;
    return Balance(
      amountRial: balanceRial,
      fetchedAt: DateTime.utc(2026, 10, 20),
    );
  }

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
    if (reserveThrowsInsufficient) {
      throw InsufficientBalanceException(
        balanceRial: 400000,
        requiredRial: offering.option.priceRial,
      );
    }
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
    List<MealOffering> offerings, {
    int? requiredBalanceRial,
  }) async {
    lastRequiredBalanceRial = requiredBalanceRial;
    if (requiredBalanceRial != null && balanceRial < requiredBalanceRial) {
      throw InsufficientBalanceException(
        balanceRial: balanceRial,
        requiredRial: requiredBalanceRial,
      );
    }
    if (reserveAllHandler != null) {
      return reserveAllHandler!(session, offerings);
    }
    return super.reserveAll(
      session,
      offerings,
      requiredBalanceRial: requiredBalanceRial,
    );
  }

  @override
  Future<ClaimResult> claim(Session session, ListingId listingId) async =>
      throw UnimplementedError();

  @override
  Future<BasketHoldStatus?> holdingsOnBuyPage(
    Session session, {
    required DateTime date,
    required String optionId,
  }) async => null;

  @override
  Future<CancelOutcome> cancel(Session session, MealRef ref) async {
    cancelled.add(ref);
    return cancelOutcome;
  }

  @override
  Uri? topUpUrl(Session session) => null;
}

/// A client that leaves `reserveAll` to the interface's own default, so the
/// default's balance enforcement — not an override — is what a test exercises.
///
/// It **extends** the interface rather than implementing it: a class that only
/// implements `PortalClient` does not inherit the default `reserveAll` body,
/// so it would prove nothing about the shipped implementation. `noSuchMethod`
/// satisfies the members this test never calls.
class _DefaultReserveAllClient extends PortalClient {
  _DefaultReserveAllClient({required this.balanceRial});

  final int balanceRial;
  final reserved = <MealOffering>[];
  int balanceReads = 0;

  @override
  Future<Session> refresh(Session session) async => session;

  @override
  Future<Balance> fetchBalance(Session session) async {
    balanceReads++;
    return Balance(
      amountRial: balanceRial,
      fetchedAt: DateTime.utc(2026, 10, 22),
    );
  }

  @override
  Future<Reservation> reserve(Session session, MealOffering offering) async {
    reserved.add(offering);
    return Reservation(
      id: 'r-${reserved.length}',
      date: offering.date,
      slot: offering.slot,
      hall: offering.hall,
      option: offering.option,
      state: ReservationState.active,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
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
      expect(
        store.find('a1', day, MealSlot.lunch),
        isNotNull,
        reason: 'the mirror must follow the booking',
      );
    });

    test(
      'a slot the account already holds is refused, and nothing is sent',
      () async {
        // The portal does **not** enforce the one-meal rule (F22): it offers a
        // meal the account already holds and accepts a second booking without
        // complaint. So the app must refuse it — before the request, not after.
        store.put(
          StoredMeal(
            accountId: 'a1',
            date: day,
            slot: MealSlot.lunch,
            source: MealSource.weeklyReservation,
            capturedAt: day,
          ),
        );

        final outcome = await service.reserve(
          accountId: 'a1',
          offering: offering(),
        );

        expect(outcome.succeeded, isFalse);
        expect(outcome.failure, ReservationFailure.slotAlreadyHeld);
        expect(
          portal.reserved,
          isEmpty,
          reason: 'the refusal must happen before the money could move',
        );
      },
    );

    test('a meal bought from the basket also blocks a booking', () async {
      store.put(
        StoredMeal(
          accountId: 'a1',
          date: day,
          slot: MealSlot.lunch,
          source: MealSource.basketPurchase,
          capturedAt: day,
        ),
      );

      final outcome = await service.reserve(
        accountId: 'a1',
        offering: offering(),
      );

      expect(
        outcome.succeeded,
        isFalse,
        reason: 'one meal per slot per day, from either source',
      );
    });

    test('a locked date is refused, and nothing is sent', () async {
      final outcome = await service.reserve(
        accountId: 'a1',
        offering: offering(reservable: false),
      );

      expect(outcome.succeeded, isFalse);
      expect(outcome.failure, ReservationFailure.locked);
      expect(
        portal.reserved,
        isEmpty,
        reason:
            'a locked row is ignored by the portal, so the refusal is '
            'cheaper and clearer than a silent no-op',
      );
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

    test('a fresh balance from the caller skips the balance read', () async {
      // The reservations header already read the balance moments ago. The
      // write path reads `Reservation.aspx` anyway, so fetching the same
      // figure again before the write is a round trip that buys nothing.
      final outcome = await service.reserve(
        accountId: 'a1',
        offering: offering(),
        knownBalanceRial: 500000,
      );

      expect(outcome.succeeded, isTrue, reason: outcome.message ?? '');
      expect(
        portal.balanceReads,
        0,
        reason: 'a fresh balance must not be fetched a second time',
      );
      expect(portal.reserved, hasLength(1));
    });

    test('a known balance is still checked before the write', () async {
      // Skipping the read must not skip the check: a known balance that
      // cannot cover the meal is refused exactly as a fetched one is.
      final outcome = await service.reserve(
        accountId: 'a1',
        offering: offering(price: 500000),
        knownBalanceRial: 100000,
      );

      expect(outcome.succeeded, isFalse);
      expect(outcome.failure, ReservationFailure.insufficientFunds);
      expect(portal.balanceReads, 0);
      expect(portal.reserved, isEmpty);
    });

    test('a page-balance refusal is reported as insufficient funds', () async {
      // The adapter reads the balance from the write page and refuses before
      // the POST. A cached figure that looked sufficient must not turn that
      // into a generic failure or a success.
      portal.reserveThrowsInsufficient = true;

      final outcome = await service.reserve(
        accountId: 'a1',
        offering: offering(price: 500000),
        knownBalanceRial: 600000,
      );

      expect(outcome.succeeded, isFalse);
      expect(outcome.failure, ReservationFailure.insufficientFunds);
      expect(outcome.deficitRial, 100000);
      expect(portal.reserved, isEmpty);
      expect(store.find('a1', day, MealSlot.lunch), isNull);
    });

    test('a booking the portal refuses is reported, not swallowed', () async {
      portal.reserveFails = true;

      final outcome = await service.reserve(
        accountId: 'a1',
        offering: offering(),
      );

      expect(outcome.succeeded, isFalse);
      expect(outcome.message, isNotNull);
      expect(
        store.find('a1', day, MealSlot.lunch),
        isNull,
        reason: 'a failed booking must not appear in the mirror',
      );
    });
  });

  group('cancelling', () {
    /// Puts a held meal in the mirror, so a cancel has something to remove.
    void holdMeal() {
      store.put(
        StoredMeal(
          accountId: 'a1',
          date: day,
          slot: MealSlot.lunch,
          source: MealSource.weeklyReservation,
          capturedAt: day,
        ),
      );
    }

    test(
      'a cancel the portal confirms removes the meal from the mirror',
      () async {
        holdMeal();

        final outcome = await service.cancel(
          accountId: 'a1',
          date: day,
          slot: MealSlot.lunch,
        );

        expect(outcome, isA<CancelSucceeded>());
        expect(store.find('a1', day, MealSlot.lunch), isNull);
      },
    );

    test('a refused cancel leaves the meal in the mirror', () async {
      // A locked date is refused **silently** (F14): the portal discards the
      // post and answers 200, so the request cannot tell success from
      // refusal. If the mirror were updated on the strength of the request,
      // the app would hide a meal the student still holds (F63).
      holdMeal();
      portal.cancelOutcome = const CancelRefused(
        'مهلت رزرو این تاریخ به پایان رسیده است.',
      );

      final outcome = await service.cancel(
        accountId: 'a1',
        date: day,
        slot: MealSlot.lunch,
      );

      expect(outcome, isA<CancelRefused>());
      expect(
        store.find('a1', day, MealSlot.lunch),
        isNotNull,
        reason: 'the portal still holds the meal, so the mirror must too',
      );
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

    test(
      'a cancel that could not be sent leaves the meal in the mirror',
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
      },
    );
  });

  group('modifying a reservation', () {
    void holdMeal({int price = 150000, String dish = 'چلو جوجه'}) {
      store.put(
        StoredMeal(
          accountId: 'a1',
          date: day,
          slot: MealSlot.lunch,
          source: MealSource.weeklyReservation,
          capturedAt: DateTime.now().toUtc(),
          dishName: dish,
          priceRial: price,
        ),
      );
    }

    test(
      'replaces existing reservation even when slot is already held',
      () async {
        holdMeal();

        final updatedOffering = MealOffering(
          date: day,
          slot: MealSlot.lunch,
          hall: const Hall(id: '2', name: 'سلف زیتون'),
          option: const MenuOption(
            id: '999',
            name: 'چلو ماهی',
            priceRial: 180000,
          ),
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
      },
    );

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

    test(
      'refuses modification if balance cannot cover positive price difference',
      () async {
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
      },
    );

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
    }) => MealOffering(
      date: date ?? day,
      slot: slot,
      hall: const Hall(id: '1', name: 'مرکزی برادران'),
      option: MenuOption(id: '62738', name: 'چلو اکبرجوجه', priceRial: price),
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
      'skips the pre-write balance read when a fresh balance is given',
      () async {
        portal.balanceRial = 500000;
        final off = makeOffering(price: 100000);

        final outcome = await service.batchReserve(
          accountId: 'a1',
          offerings: [off],
          knownBalanceRial: 500000,
        );

        expect(outcome.isFullSuccess, isTrue);
        expect(
          portal.balanceReads,
          0,
          reason:
              'the caller already read the balance; the write path confirms '
              'the result against the portal',
        );
        expect(portal.reserved, contains(off));
      },
    );

    test('does not read the balance separately when no known balance is given', () async {
      portal.balanceRial = 500000;
      final off = makeOffering(price: 100000);

      final outcome = await service.batchReserve(
        accountId: 'a1',
        offerings: [off],
      );

      expect(outcome.isFullSuccess, isTrue);
      expect(
        portal.balanceReads,
        0,
        reason:
            'the reservation page the batch must fetch to post carries the '
            'balance; a separate read of the same page is a wasted round trip',
      );
      expect(portal.lastRequiredBalanceRial, 100000);
      expect(portal.reserved, contains(off));
    });

    test('still refuses a batch the known balance cannot cover', () async {
      final off = makeOffering(price: 150000);

      final outcome = await service.batchReserve(
        accountId: 'a1',
        offerings: [off],
        knownBalanceRial: 100000,
      );

      expect(outcome.isFullSuccess, isFalse);
      expect(outcome.failure, ReservationFailure.insufficientFunds);
      expect(outcome.deficitRial, 50000);
      expect(outcome.refusedBeforeRequest, isTrue);
      expect(portal.balanceReads, 0);
      expect(portal.reserved, isEmpty);
    });

    test(
      'the interface default still refuses a batch the balance cannot cover',
      () async {
        // A client that does not override `reserveAll` must not lose the
        // atomic guarantee: the default reads the balance and refuses before
        // calling `reserve` at all.
        final client = _DefaultReserveAllClient(balanceRial: 100000);
        final guarded = ReservationService(
          client: client,
          sessions: SessionManager(
            client: client,
            store: _AlwaysStore(),
            solver: _NoopSolver(),
            clock: FixedServerClock.now(DateTime.utc(2026, 10, 20, 12)),
          ),
          mealStore: LocalMealStore(),
        );

        final outcome = await guarded.batchReserve(
          accountId: 'a1',
          offerings: [makeOffering(price: 500000)],
        );

        expect(outcome.isFullSuccess, isFalse, reason: outcome.message);
        expect(
          outcome.failure,
          ReservationFailure.insufficientFunds,
          reason: outcome.message,
        );
        expect(outcome.deficitRial, 400000);
        expect(client.balanceReads, 1);
        expect(client.reserved, isEmpty);
      },
    );

    test('refuses entire batch upfront if balance is less than total sum (no partial reservation)', () async {
      portal.balanceRial = 60000; // 60,000 Rial
      final off1 = makeOffering(slot: MealSlot.lunch, price: 50000);
      final off2 = makeOffering(
        slot: MealSlot.dinner,
        price: 50000,
      ); // total 100,000 > 60,000

      final outcome = await service.batchReserve(
        accountId: 'a1',
        offerings: [off1, off2],
      );

      expect(outcome.isFullSuccess, isFalse);
      expect(outcome.failure, ReservationFailure.insufficientFunds);
      expect(outcome.deficitRial, 40000);
      expect(outcome.succeeded, isEmpty);
      // The page's balance refuses the whole batch before the first write, so
      // no partial debit can happen.
      expect(portal.reserved, isEmpty);
      expect(portal.balanceReads, 0);
      expect(portal.lastRequiredBalanceRial, 100000);
      expect(store.find('a1', day, MealSlot.lunch), isNull);
      expect(store.find('a1', day, MealSlot.dinner), isNull);
    });

    test(
      'refuses batch if all offerings conflict with already held slots',
      () async {
        store.put(
          StoredMeal(
            accountId: 'a1',
            date: day,
            slot: MealSlot.lunch,
            source: MealSource.weeklyReservation,
            capturedAt: DateTime.now().toUtc(),
            dishName: 'چلو جوجه',
            priceRial: 150000,
          ),
        );

        final off1 = makeOffering(slot: MealSlot.lunch);
        final outcome = await service.batchReserve(
          accountId: 'a1',
          offerings: [off1],
        );

        expect(outcome.isFullSuccess, isFalse);
        expect(outcome.failure, ReservationFailure.slotAlreadyHeld);
        expect(portal.reserved, isEmpty);
      },
    );

    test('successfully reserves all offerings and updates meal store when balance is sufficient', () async {
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

    test('records succeeded meals in meal store and reports failed when partial reservation occurs', () async {
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
