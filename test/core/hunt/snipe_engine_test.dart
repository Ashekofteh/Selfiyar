import 'dart:async';
import 'dart:math';

import 'package:bahonar_nut/core/shared/ledger.dart';
import 'package:bahonar_nut/core/hunt/hunt_config.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/portal/polling.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/core/portal/request_ledger.dart';
import 'package:bahonar_nut/core/hunt/priority.dart';
import 'package:bahonar_nut/core/auth/session.dart';
import 'package:bahonar_nut/core/auth/session_manager.dart';
import 'package:bahonar_nut/core/hunt/snipe.dart';
import 'package:bahonar_nut/core/hunt/snipe_engine.dart';
import 'package:bahonar_nut/core/shared/time.dart';

import '../../helpers/portal_stubs.dart' show FakePortalClient;

import 'package:test/test.dart';

const central = Hall(id: '1', name: 'مرکزی برادران');
final optA = const MenuOption(id: '62702', name: 'زرشک پلو', priceRial: 350000);
final optB = const MenuOption(
  id: '62714',
  name: 'جوجه کباب',
  priceRial: 500000,
);

Listing listing(
  String id, {
  MenuOption? option,
  MealSlot slot = MealSlot.lunch,
}) => Listing(
  id: id,
  date: DateTime.utc(2026, 10, 20),
  slot: slot,
  hall: central,
  option: option ?? optA,
);

SnipeRule buildRule({
  bool dryRun = false,
  int? maxPrice,
  int maxPurchases = 1,
  MealSlot slot = MealSlot.lunch,
}) => SnipeRule(
  id: 'r1',
  account: 'a1',
  dryRun: dryRun,
  maxPriceRial: maxPrice,
  maxPurchasesPerWindow: maxPurchases,
  slots: {slot},
  preferences: {
    slot: SlotPreference(
      slot: slot,
      ranked: const [
        PreferencePair(hallId: '1', optionId: '62702'),
        PreferencePair(hallId: '1', optionId: '62714'),
      ],
    ),
  },
);

/// A client whose basket and claim behaviour the test scripts.
class ScriptedClient extends FakePortalClient {
  ScriptedClient({
    List<List<Listing>>? basketPages,
    this.claimBehavior = ClaimBehavior.succeed,
    this.reconcileReservations = const [],
    this.reconcileHold,
    this.throwOnHoldRead = false,
  }) : _basketPages = basketPages ?? [];

  /// Successive basket responses; the last one repeats once exhausted.
  final List<List<Listing>> _basketPages;
  int basketCalls = 0;

  ClaimBehavior claimBehavior;
  List<Reservation> reconcileReservations;

  /// What the buy page says about the reconciled listing's row.
  ///
  /// The reconciler reads the **buy page**, not the weekly reservation grid:
  /// a basket purchase lands only in the ledger and on the buy page (F17), so
  /// a grid-reading reconciler would report every successful purchase as
  /// "not claimed" and invite a second, irreversible one.
  final BasketHoldStatus? reconcileHold;

  /// When true, the buy-page re-read throws, so reconciliation is
  /// indeterminate.
  final bool throwOnHoldRead;

  int claimCalls = 0;
  int reserveCalls = 0;
  int cancelCalls = 0;

  /// Called at the start of each basket read.
  ///
  /// Lets a test observe *when* a poll happened, which is the only honest way
  /// to assert the window invariant: a hunt outside its window must not poll
  /// at all.
  void Function()? onPoll;

  /// Called just before a basket read returns (or throws).
  ///
  /// A test advances a simulated device clock here to model a round trip, so
  /// it can prove that `lastPollAt` is the completion time rather than the
  /// start time.
  void Function()? onBasketReadComplete;

  /// When set, every basket read throws this instead of returning a page.
  Object? basketError;

  /// When set, each basket read is recorded here, the way the transport
  /// records every real request. Used to prove the advisory window limit does
  /// not silently throttle a run.
  RequestLedger? ledger;

  /// An optional real delay per read.
  ///
  /// A test that wants to observe a run *while* it is still going needs the
  /// loop to yield to the event loop often enough; without this the engine can
  /// exhaust its whole budget between two 5ms checks.
  Duration readDelay = Duration.zero;

  @override
  Future<BasketPage> fetchBasket(Session session, {String? cursor}) async {
    onPoll?.call();
    ledger?.record(
      accountId: session.account,
      method: 'POST',
      path: '/FoodBasket/FoodBasketBuy.aspx',
    );
    if (readDelay > Duration.zero) {
      await Future<void>.delayed(readDelay);
    }
    final index = basketCalls < _basketPages.length
        ? basketCalls
        : (_basketPages.isEmpty ? -1 : _basketPages.length - 1);
    basketCalls++;
    onBasketReadComplete?.call();
    final error = basketError;
    if (error != null) throw error;
    if (index < 0) return const BasketPage(listings: []);
    return BasketPage(listings: _basketPages[index]);
  }

  @override
  Future<ClaimResult> claim(Session session, ListingId listingId) async {
    claimCalls++;
    switch (claimBehavior) {
      case ClaimBehavior.succeed:
        return ClaimSucceeded(
          Reservation(
            id: 'r-$listingId',
            date: DateTime.utc(2026, 10, 20),
            slot: MealSlot.lunch,
            hall: central,
            option: optA,
            state: ReservationState.active,
          ),
        );
      case ClaimBehavior.reject:
        return const ClaimRejected('کسی دیگر آن را خرید');
      case ClaimBehavior.ambiguous:
        return const ClaimAmbiguous('timeout');
      case ClaimBehavior.throw_:
        throw Exception('connection reset mid-request');
    }
  }

  @override
  Future<List<Reservation>> fetchReservations(Session session) async =>
      reconcileReservations;

  @override
  Future<BasketHoldStatus?> holdingsOnBuyPage(
    Session session, {
    required DateTime date,
    required String optionId,
  }) async {
    if (throwOnHoldRead) throw Exception('network down');
    return reconcileHold;
  }

  @override
  Future<Balance> fetchBalance(Session session) async =>
      Balance(amountRial: 1000000, fetchedAt: DateTime.utc(2026, 10, 18));

  @override
  Future<LoginChallenge?> beginLogin(String username) async => null;

  @override
  Future<Session> completeLogin({
    required String username,
    required String password,
    LoginChallengeResponse? challenge,
  }) async => Session(
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
      DateTime.utc(2026, 10, 18);

  @override
  Future<List<MealOffering>> fetchOfferings(Session s, DateTime date) async =>
      const [];

  @override
  Future<List<MealMenu>> fetchMenu(Session session, DateTime date) async =>
      const [];

  @override
  Future<BookableMenus> fetchBookableMenus(
    Session session, {
    int days = 7,
  }) async => const BookableMenus(dates: [], menus: []);

  @override
  Future<Reservation> reserve(Session session, MealOffering offering) async {
    reserveCalls++;
    throw UnimplementedError();
  }

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async =>
      const <Transaction>[];

  @override
  Future<CancelOutcome> cancel(Session session, MealRef ref) async {
    cancelCalls++;
    return const CancelSucceeded();
  }

  @override
  Uri? topUpUrl(Session session) => null;
}

enum ClaimBehavior { succeed, reject, ambiguous, throw_ }

/// A session store that always has credentials, so preflight passes.
class AlwaysStore implements SessionStore {
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

class NoopSolver implements ChallengeSolver {
  @override
  Future<String?> solve(LoginChallenge challenge) async => '1234';
}

/// Builds an engine whose sleep resolves immediately, so the poll loop runs
/// synchronously in tests instead of waiting real jittered seconds.
///
/// The clock is movable so a test can move the server time and watch the
/// hunt's window behaviour: a hunt waits for its window rather than ending,
/// and ends when the window closes.
DefaultSnipeEngine buildEngine(
  ScriptedClient client, {
  MovableServerClock? clock,
  DateTime Function()? deviceNow,
  RequestLedger? requests,
}) {
  final theClock =
      clock ?? MovableServerClock(DateTime.utc(2026, 10, 18, 7, 0));
  final sessions = SessionManager(
    client: client,
    store: AlwaysStore(),
    solver: NoopSolver(),
    clock: theClock,
  );
  return DefaultSnipeEngine(
    client: client,
    sessions: sessions,
    clock: theClock,
    // Poll fast and deterministically: no real delay, no jitter surprises.
    defaultPolicy: const PollingPolicy(
      baseInterval: Duration.zero,
      jitterMin: 1.0,
      jitterMax: 1.0,
    ),
    random: Random(1),
    // The sleep advances the server clock, because the engine's behaviour
    // over time — waiting for a window, ending when it closes — is read off
    // the clock. A sleep that did not advance it would leave the engine
    // waiting forever.
    sleep: (d) async => theClock.advance(d),
    deviceNow: deviceNow,
    requests: requests,
    // A short wait slice, so a test that waits for a window does not need
    // a real minute per check. It is an hour, because the fake sleep advances
    // the clock by the whole slice: a one-second slice would race the clock
    // through the entire window in a few milliseconds of real time.
    waitSlice: const Duration(hours: 1),
  );
}

/// Waits until [condition] holds, or fails after [timeout].
Future<void> waitFor(bool Function() condition, {Duration? timeout}) async {
  final limit = timeout ?? const Duration(seconds: 5);
  final deadline = DateTime.now().add(limit);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition not met within $limit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('winning a listing', () {
    test('polls, matches, claims, and terminates claimed', () async {
      final client = ScriptedClient(
        basketPages: [
          [], // first poll: nothing
          [listing('L1')], // second poll: a match
        ],
      );
      final engine = buildEngine(client);
      await engine.start(buildRule());

      await waitFor(() => !engine.isRunning('r1'));

      final ledger = engine.ledgerFor('r1')!;
      expect(client.claimCalls, 1);
      expect(ledger.purchaseCount, 1);
      expect(
        ledger.entries.any((e) => e.kind == LedgerEventKind.claimSucceeded),
        isTrue,
      );
    });

    test('status reports the claimed listing', () async {
      final client = ScriptedClient(
        basketPages: [
          [listing('L1')],
        ],
      );
      final engine = buildEngine(client);
      final statuses = <SnipeRunStatus>[];
      await engine.start(buildRule());
      engine.watch('r1').listen(statuses.add);

      await waitFor(() => !engine.isRunning('r1'));

      expect(statuses.last.state, SnipeState.claimed);
      expect(statuses.last.claimedListingId, 'L1');
    });

    test('prefers the higher-ranked listing', () async {
      final client = ScriptedClient(
        basketPages: [
          [listing('L2', option: optB), listing('L1', option: optA)],
        ],
      );
      final engine = buildEngine(client);
      await engine.start(buildRule());
      await waitFor(() => !engine.isRunning('r1'));

      final ledger = engine.ledgerFor('r1')!;
      final match = ledger.entries.firstWhere(
        (e) => e.kind == LedgerEventKind.matched,
      );
      expect(match.listingId, 'L1', reason: 'optA outranks optB');
    });

    test('a price ceiling prevents buying an over-budget listing', () async {
      final client = ScriptedClient(
        basketPages: [
          [listing('L2', option: optB)], // 500000, over the 400000 ceiling
        ],
      );
      final engine = buildEngine(client);
      await engine.start(buildRule(maxPrice: 400000));

      // Give it a few cycles to find nothing.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await engine.stop('r1');

      expect(client.claimCalls, 0, reason: 'nothing was affordable');
      final ledger = engine.ledgerFor('r1')!;
      expect(
        ledger.entries.any((e) => e.kind == LedgerEventKind.skipped),
        isTrue,
      );
    });
  });

  group('dry run', () {
    test('never issues a claim, but records what it would have done', () async {
      final client = ScriptedClient(
        basketPages: [
          [listing('L1')],
        ],
      );
      final engine = buildEngine(client);
      await engine.start(buildRule(dryRun: true));
      await waitFor(() => !engine.isRunning('r1'));

      expect(client.claimCalls, 0, reason: 'dry run must not write');
      final ledger = engine.ledgerFor('r1')!;
      expect(ledger.simulatedPurchaseCount, 1);
      expect(ledger.purchaseCount, 0, reason: 'no real purchase in a dry run');
    });

    test('a dry run never calls reserve or cancel either', () async {
      final client = ScriptedClient(
        basketPages: [
          [listing('L1')],
        ],
      );
      final engine = buildEngine(client);
      await engine.start(buildRule(dryRun: true));
      await waitFor(() => !engine.isRunning('r1'));

      expect(client.reserveCalls, 0);
      expect(client.cancelCalls, 0);
    });
  });

  group('losing a race', () {
    test(
      'a rejected claim tombstones the listing and never re-claims it',
      () async {
        final client = ScriptedClient(
          basketPages: [
            [listing('L1')],
          ],
          claimBehavior: ClaimBehavior.reject,
        );
        final engine = buildEngine(client);
        await engine.start(buildRule());

        // Let it run several cycles against the same dead listing.
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await engine.stop('r1');

        expect(
          client.claimCalls,
          1,
          reason:
              'the dead listing must be tombstoned after the first rejection',
        );
      },
    );

    test('it keeps hunting after losing, if the window is open', () async {
      final client = ScriptedClient(
        basketPages: [
          [listing('L1')],
          [listing('L2')],
        ],
        claimBehavior: ClaimBehavior.reject,
      );
      final engine = buildEngine(client);
      await engine.start(buildRule());
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await engine.stop('r1');

      // Two distinct listings, two attempts: custody of the tombstone is per
      // listing, so a fresh listing is still claimable.
      expect(client.claimCalls, 2);
    });
  });

  group('ambiguous claim — the double-purchase guard', () {
    test('an ambiguous claim is NEVER retried', () async {
      final client = ScriptedClient(
        basketPages: [
          [listing('L1')],
        ],
        claimBehavior: ClaimBehavior.ambiguous,
      );
      final engine = buildEngine(client);
      await engine.start(buildRule());
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await engine.stop('r1');

      expect(
        client.claimCalls,
        1,
        reason: 'a blind retry could buy two meals and charge twice',
      );
    });

    test('a thrown claim is treated as ambiguous, and not retried', () async {
      final client = ScriptedClient(
        basketPages: [
          [listing('L1')],
        ],
        claimBehavior: ClaimBehavior.throw_,
      );
      final engine = buildEngine(client);
      await engine.start(buildRule());
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await engine.stop('r1');

      expect(client.claimCalls, 1);
      final ledger = engine.ledgerFor('r1')!;
      expect(
        ledger.entries.any((e) => e.kind == LedgerEventKind.claimAmbiguous),
        isTrue,
      );
    });

    test('reconcile finds the claim landed -> claimed, and stops', () async {
      final client = ScriptedClient(
        basketPages: [
          [listing('L1')],
        ],
        claimBehavior: ClaimBehavior.ambiguous,
        // The buy page now shows the row as held: the purchase landed.
        reconcileHold: const BasketHoldStatus(
          checked: true,
          amountRial: 350000,
        ),
      );

      final engine = buildEngine(client);
      await engine.start(buildRule());
      await waitFor(() => !engine.isRunning('r1'));

      final ledger = engine.ledgerFor('r1')!;
      expect(ledger.purchaseCount, 1);
      expect(
        ledger.entries.any((e) => e.kind == LedgerEventKind.reconciled),
        isTrue,
      );
    });

    test(
      'reconcile finds nothing landed -> keeps hunting, no re-claim of L1',
      () async {
        final client = ScriptedClient(
          basketPages: [
            [listing('L1')],
          ],
          claimBehavior: ClaimBehavior.ambiguous,
          // The row is still offered and not held: the purchase did not land.
          reconcileHold: const BasketHoldStatus(checked: false, amountRial: 0),
        );

        final engine = buildEngine(client);
        await engine.start(buildRule());
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await engine.stop('r1');

        expect(
          client.claimCalls,
          1,
          reason: 'L1 is tombstoned after reconciliation',
        );
      },
    );

    test(
      'indeterminate reconciliation still tombstones (never a second attempt)',
      () async {
        final client = ScriptedClient(
          basketPages: [
            [listing('L1')],
          ],
          claimBehavior: ClaimBehavior.ambiguous,
          // The buy-page re-read throws -> indeterminate.
          throwOnHoldRead: true,
        );
        final engine = DefaultSnipeEngine(
          client: client,
          sessions: SessionManager(
            client: client,
            store: AlwaysStore(),
            solver: NoopSolver(),
            clock: FixedServerClock.now(DateTime.utc(2026, 10, 18, 7, 0)),
          ),
          clock: FixedServerClock.now(DateTime.utc(2026, 10, 18, 7, 0)),
          defaultPolicy: const PollingPolicy(
            baseInterval: Duration.zero,
            jitterMin: 1.0,
            jitterMax: 1.0,
          ),
          random: Random(1),
          sleep: (_) async {},
        );

        await engine.start(buildRule());
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await engine.stop('r1');

        expect(
          client.claimCalls,
          1,
          reason: 'indeterminate must still forbid a retry',
        );
      },
    );
  });

  group('preflight gating', () {
    test('an unsynced clock aborts before hunting', () async {
      final client = ScriptedClient(
        basketPages: [
          [listing('L1')],
        ],
      );
      final engine = DefaultSnipeEngine(
        client: client,
        sessions: SessionManager(
          client: client,
          store: AlwaysStore(),
          solver: NoopSolver(),
          clock: _UnsyncedClock(),
        ),
        clock: _UnsyncedClock(),
        defaultPolicy: const PollingPolicy(
          baseInterval: Duration.zero,
          jitterMin: 1.0,
          jitterMax: 1.0,
        ),
        random: Random(1),
        sleep: (_) async {},
      );

      await engine.start(buildRule());
      await waitFor(() => !engine.isRunning('r1'));

      expect(client.basketCalls, 0, reason: 'must not hunt without a clock');
      final ledger = engine.ledgerFor('r1')!;
      expect(
        ledger.entries.any((e) => e.kind == LedgerEventKind.preflightFailed),
        isTrue,
      );
    });

    test('a window that is closed waits rather than hunting', () async {
      final client = ScriptedClient(
        basketPages: [
          [listing('L1')],
        ],
      );
      // Portal-local 10:30 — half an hour before the 11:00-12:00 window.
      final clock = MovableServerClock(DateTime.utc(2026, 10, 18, 7, 0));
      final engine = buildEngine(client, clock: clock);
      final rule = SnipeRule(
        id: 'r1',
        account: 'a1',
        slots: const {MealSlot.lunch},
        windowStart: const ClockTime(11, 0),
        windowEnd: const ClockTime(12, 0),
        preferences: {
          MealSlot.lunch: SlotPreference(
            slot: MealSlot.lunch,
            ranked: const [PreferencePair(hallId: '1', optionId: '62702')],
          ),
        },
      );

      // The time of every poll, as the clock saw it. The invariant is about
      // *when* the hunt asked, not how many times: a hunt outside its window
      // must not poll at all.
      final pollTimes = <ClockTime>[];
      client.onPoll = () => pollTimes.add(
        ClockTime(clock.portalNow.hour, clock.portalNow.minute),
      );

      await engine.start(rule);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        pollTimes.every(
          (t) => t >= const ClockTime(11, 0) && t <= const ClockTime(12, 0),
        ),
        isTrue,
        reason:
            'a closed window must not be polled at all. Polls at: '
            '$pollTimes',
      );

      await engine.stop('r1');
    });

    test(
      'the run ends when the window closes after the hunt has run',
      () async {
        final client = ScriptedClient(
          basketPages: [
            [listing('L1')],
          ],
        );
        // Portal-local 08:30 — inside an 08:00-09:00 window.
        final clock = MovableServerClock(DateTime.utc(2026, 10, 18, 5, 0));
        final engine = buildEngine(client, clock: clock);
        final rule = SnipeRule(
          id: 'r1',
          account: 'a1',
          slots: const {MealSlot.lunch},
          windowStart: const ClockTime(8, 0),
          windowEnd: const ClockTime(9, 0),
          preferences: {
            MealSlot.lunch: SlotPreference(
              slot: MealSlot.lunch,
              ranked: const [PreferencePair(hallId: '1', optionId: '62702')],
            ),
          },
        );

        await engine.start(rule);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(client.basketCalls, greaterThan(0));

        // The window closes: the hunt is over.
        clock.set(DateTime.utc(2026, 10, 18, 6, 0)); // 09:30 portal-local.
        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(engine.isRunning('r1'), isFalse);
      },
    );
  });

  group('idempotence and control', () {
    test('starting the same rule twice does not create two hunts', () async {
      final client = ScriptedClient(
        basketPages: [
          [listing('L1')],
        ],
      );
      final engine = buildEngine(client);

      await engine.start(buildRule());
      await engine.start(buildRule()); // idempotent

      await waitFor(() => !engine.isRunning('r1'));
      expect(client.claimCalls, 1, reason: 'one hunt, one claim');
    });

    test('stop ends a running hunt', () async {
      final client = ScriptedClient(
        basketPages: [
          [], // never matches, so it keeps hunting
        ],
      );
      final engine = buildEngine(client);
      await engine.start(buildRule());

      // Immediately after start the run must be registered. (No delay here: the
      // loop burns its 400-request budget in milliseconds with instant sleep,
      // so a delay would let it finish on its own — which is the budget working,
      // not a broken stop.)
      expect(engine.isRunning('r1'), isTrue);
      await engine.stop('r1');
      expect(engine.isRunning('r1'), isFalse);
    });

    test('watch on an unknown rule yields an empty stream', () {
      final client = ScriptedClient();
      final engine = buildEngine(client);
      expect(engine.watch('nope'), emitsDone);
    });
  });

  group('the last-attempt timestamp', () {
    test(
      'is stamped when a successful read completes, on the device clock',
      () async {
        var device = DateTime.utc(2026, 10, 18, 7, 0);
        final client = ScriptedClient(basketPages: [[]]);
        client.onBasketReadComplete = () {
          // Model a two-second round trip.
          device = device.add(const Duration(seconds: 2));
        };
        final engine = buildEngine(client, deviceNow: () => device);
        final statuses = <SnipeRunStatus>[];
        final started = engine.start(buildRule());
        engine.watch('r1').listen(statuses.add);
        await started;

        await waitFor(() => statuses.any((s) => s.lastPollAt != null));
        await engine.stop('r1');

        final first = statuses.firstWhere((s) => s.lastPollAt != null);
        expect(
          first.lastPollAt,
          DateTime.utc(2026, 10, 18, 7, 0, 2),
          reason: 'the stamp is the completion time, not the start time',
        );

        // The ledger keeps the server instant, because it explains the hunt
        // rather than the screen. The two clocks are deliberately separate.
        final polled = engine
            .ledgerFor('r1')!
            .entries
            .firstWhere((e) => e.kind == LedgerEventKind.polled);
        expect(polled.at, DateTime.utc(2026, 10, 18, 7, 0));
      },
    );

    test('is stamped when a failed read completes too', () async {
      var device = DateTime.utc(2026, 10, 18, 7, 0);
      final client = ScriptedClient(basketPages: [[]]);
      client.onBasketReadComplete = () {
        device = device.add(const Duration(seconds: 2));
      };
      client.basketError = Exception('connection reset');
      final engine = buildEngine(client, deviceNow: () => device);
      final statuses = <SnipeRunStatus>[];
      final started = engine.start(buildRule());
      engine.watch('r1').listen(statuses.add);
      await started;

      await waitFor(() => statuses.any((s) => s.lastPollAt != null));
      await engine.stop('r1');

      final first = statuses.firstWhere((s) => s.lastPollAt != null);
      expect(first.lastPollAt, DateTime.utc(2026, 10, 18, 7, 0, 2));
      expect(first.lastError, isNotNull);
    });
  });

  group('the request ledger', () {
    test(
      'its advisory 400/hour window does not stop a user-approved run',
      () async {
        final ledger = RequestLedger(
          limit: 400,
          now: () => DateTime.utc(2026, 10, 18, 7, 0),
        );
        final client = ScriptedClient(basketPages: [[]])..ledger = ledger;
        // Let the test observe the run between polls; without it the loop can
        // finish the whole budget before a 5ms check gets a turn.
        client.readDelay = const Duration(milliseconds: 2);
        final config = HuntConfig(
          windowStart: const ClockTime(9, 0),
          windowEnd: const ClockTime(15, 30),
          targetSlot: MealSlot.lunch,
          targetDate: DateTime.utc(2026, 10, 18),
          dishPriority: [
            HuntDish(optionId: '62702', name: 'زرشک پلو', priceRial: 350000),
          ],
          rate: HuntRate(
            peakInterval: const Duration(seconds: 2),
            offPeakInterval: const Duration(minutes: 15),
          ),
          enabled: true,
          riskAcknowledged: true,
          requestBudget: 600,
        );
        final engine = buildEngine(
          client,
          clock: MovableServerClock(DateTime.utc(2026, 10, 18, 7, 0)),
          requests: ledger,
        );

        await engine.start(
          config.toRule(id: 'r1', account: 'a1'),
          hunt: config,
        );
        // The wait is generous on purpose: 400 delayed reads take a couple of
        // seconds on an idle machine, and a full `test/core` run shares the
        // event loop with every other suite. The condition is monotonic (the
        // ledger outlives the run), so a slow check can never turn a pass into
        // a fail — only a five-second deadline can.
        await waitFor(
          () => ledger.totalFor('a1') > 400,
          timeout: const Duration(seconds: 30),
        );

        expect(
          engine.isRunning('r1'),
          isTrue,
          reason:
              'the advisory window limit must not halt a user-approved hunt',
        );
        await engine.stop('r1');
        expect(ledger.totalFor('a1'), greaterThan(400));
      },
    );
  });

  group('ledger hygiene', () {
    test('the ledger is bounded', () async {
      final client = ScriptedClient(basketPages: [[]]);
      final engine = buildEngine(client);
      await engine.start(buildRule());
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await engine.stop('r1');

      final ledger = engine.ledgerFor('r1')!;
      expect(ledger.entries.length, lessThanOrEqualTo(SnipeLedger.maxEntries));
    });

    test('poll count advances', () async {
      final client = ScriptedClient(basketPages: [[]]);
      final engine = buildEngine(client);
      await engine.start(buildRule());
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await engine.stop('r1');

      final ledger = engine.ledgerFor('r1')!;
      expect(ledger.ofKind(LedgerEventKind.polled).length, greaterThan(1));
    });
  });
}

class _UnsyncedClock implements ServerClock {
  @override
  DateTime get nowUtc => DateTime.utc(2026, 10, 18, 7, 0);

  @override
  bool get isSynced => false;

  @override
  Duration get staleness => Duration.zero;
}
