import 'dart:async';
import 'dart:math';

import 'package:bahonar_nut/core/hunt/hunt_config.dart';
import 'package:bahonar_nut/core/shared/ledger.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/portal/polling.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/core/auth/session.dart';
import 'package:bahonar_nut/core/auth/session_manager.dart';
import 'package:bahonar_nut/core/hunt/snipe.dart';
import 'package:bahonar_nut/core/hunt/snipe_engine.dart';
import 'package:bahonar_nut/core/shared/time.dart';

import '../../helpers/portal_stubs.dart' show FakePortalClient;

import 'package:test/test.dart';

const central = Hall(id: '1', name: 'مرکزی برادران');

/// The portal-local instant of [utc] plus the offset, as a [ClockTime].
ClockTime portalTime(DateTime utc) {
  final local = utc.add(ServerClock.portalUtcOffset);
  return ClockTime(local.hour, local.minute);
}

/// A market listing, with the id the *market* uses rather than the official
/// menu's — the market renumbers ids, so the hunt must match on the name.
Listing marketListing({
  required String optionId,
  required String name,
  int priceRial = 350000,
  Hall hall = central,
  MealSlot slot = MealSlot.dinner,
}) => Listing.composite(
  date: DateTime.utc(2026, 10, 28),
  slot: slot,
  hall: hall,
  option: MenuOption(id: optionId, name: name, priceRial: priceRial),
);

HuntConfig huntConfig({
  List<HuntDish>? dishes,
  List<HuntHall>? halls,
  MealSlot slot = MealSlot.dinner,
  HuntRate? rate,
  DateTime? targetDate,
  int requestBudget = 400,
  ClockTime? windowStart,
  ClockTime? windowEnd,
}) => HuntConfig(
  targetSlot: slot,
  dishPriority:
      dishes ??
      [HuntDish(optionId: '62742', name: 'لوبیا پلو', priceRial: 350000)],
  hallPriority: halls ?? const [],
  rate:
      rate ??
      HuntRate(
        peakInterval: const Duration(seconds: 10),
        offPeakInterval: const Duration(minutes: 15),
      ),
  targetDate: targetDate ?? DateTime.utc(2026, 10, 28),
  requestBudget: requestBudget,
  windowStart: windowStart ?? const ClockTime(16, 30),
  windowEnd: windowEnd ?? const ClockTime(20, 30),
  // A hunt is opt-in, so the fixture switches it on: these tests are
  // about the engine's behaviour, not about the switch.
  enabled: true,
);

SnipeRule ruleFor(HuntConfig config) => config.toRule(id: 'r1', account: 'a1');

/// A client that records when each basket read started and finished.
class TimelineClient extends FakePortalClient {
  TimelineClient({
    this.pages = const [],
    this.claimBehavior = ClaimBehavior.succeed,
  });

  /// Successive basket pages; the last repeats once exhausted.
  final List<List<Listing>> pages;
  final ClaimBehavior claimBehavior;

  /// The moment each poll started, on the injected timeline.
  final List<int> pollStarts = [];

  /// The moment each poll finished.
  final List<int> pollEnds = [];

  /// The waits the engine asked for.
  final List<Duration> sleeps = [];

  /// The date filter each poll was given, null for the page's default.
  final List<String?> cursors = [];

  /// The portal-local time of each poll, as the clock saw it.
  ///
  /// Recorded because the window invariant is about *when* a poll happened:
  /// a hunt outside its window must not poll at all, and the only honest way
  /// to assert that is to check the time of every poll.
  final List<ClockTime> pollTimes = [];

  /// Called at the start of each poll, so a test can observe the clock.
  void Function()? onPoll;

  /// How many times the menu was read for the run's setup.
  int setupReads = 0;

  /// The date the setup read was for.
  DateTime? setupDate;

  /// The length of each simulated response.
  Duration responseDuration = Duration.zero;

  /// The official menu the *setup* read sees.
  ///
  /// The engine reads the official menu once at the start of a run, to rebuild
  /// the priority list with live prices, and then polls the marketplace. The
  /// two are different requests, on different pages, and a test that scripted
  /// only the polls would find the setup read consuming the first page.
  List<MealMenu> menu = const [];

  int claimCalls = 0;
  int clock = 0;

  void advance(Duration d) => clock += d.inMilliseconds;

  @override
  Future<List<MealMenu>> fetchMenu(Session session, DateTime date) async {
    setupReads++;
    setupDate = date;
    return menu;
  }

  @override
  Future<BookableMenus> fetchBookableMenus(
    Session session, {
    int days = 7,
  }) async {
    setupReads++;
    return BookableMenus(dates: const [], menus: menu);
  }

  @override
  Future<BasketPage> fetchBasket(Session session, {String? cursor}) async {
    pollStarts.add(clock);
    cursors.add(cursor);
    onPoll?.call();

    final index = pages.isEmpty
        ? -1
        : (pollStarts.length <= pages.length
              ? pollStarts.length - 1
              : pages.length - 1);

    await Future<void>.delayed(Duration.zero);
    advance(responseDuration);
    pollEnds.add(clock);

    if (index < 0) return const BasketPage(listings: []);
    return BasketPage(listings: pages[index]);
  }

  @override
  Future<ClaimResult> claim(Session session, ListingId listingId) async {
    claimCalls++;
    switch (claimBehavior) {
      case ClaimBehavior.succeed:
        return ClaimSucceeded(
          Reservation(
            id: 'r-$listingId',
            date: DateTime.utc(2026, 10, 28),
            slot: MealSlot.dinner,
            hall: central,
            option: const MenuOption(
              id: 'o1',
              name: 'لوبیا پلو',
              priceRial: 350000,
            ),
            state: ReservationState.active,
          ),
        );
      case ClaimBehavior.reject:
        return const ClaimRejected('taken');
      case ClaimBehavior.ambiguous:
        return const ClaimAmbiguous('timeout');
      case ClaimBehavior.throw_:
        throw Exception('reset');
    }
  }

  @override
  Future<Balance> fetchBalance(Session session) async =>
      Balance(amountRial: 5000000, fetchedAt: DateTime.utc(2026, 10, 18));

  @override
  Future<List<Reservation>> fetchReservations(Session session) async =>
      const [];

  @override
  Future<BasketHoldStatus?> holdingsOnBuyPage(
    Session session, {
    required DateTime date,
    required String optionId,
  }) async => null;

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
    establishedAt: DateTime.utc(2026, 10, 18),
  );

  @override
  Future<Session> refresh(Session session) async => session;

  @override
  Future<void> logout(Session session) async {}

  @override
  Future<DateTime> fetchServerTime(Session session) async =>
      DateTime.utc(2026, 10, 18, 7, 0);

  @override
  Future<List<MealOffering>> fetchOfferings(Session s, DateTime date) async =>
      const [];

  @override
  Future<Reservation> reserve(Session session, MealOffering offering) async =>
      throw UnimplementedError();

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async =>
      const [];

  @override
  Future<CancelOutcome> cancel(Session session, MealRef ref) async =>
      const CancelSucceeded();

  @override
  Uri? topUpUrl(Session session) => null;
}

enum ClaimBehavior { succeed, reject, ambiguous, throw_ }

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

/// Records what the engine reported.
class RecordingListener implements HuntOutcomeListener {
  final List<String> claims = [];
  final List<String> ends = [];

  @override
  Future<void> onClaimed({
    required String ruleId,
    required Listing listing,
    required Reservation reservation,
  }) async {
    claims.add('${reservation.option.name}@${listing.hall.name}');
  }

  @override
  Future<void> onEnded({
    required String ruleId,
    required SnipeState state,
    required String reason,
  }) async {
    ends.add('$state:$reason');
  }
}

/// Builds an engine on a controllable timeline.
class Harness {
  Harness({
    required this.client,
    required this.config,
    required this.listener,
    DateTime? now,
    List<MealMenu>? menu,
    double jitterMax = 1.2,
  }) : clock = MovableServerClock(now ?? DateTime.utc(2026, 10, 28, 12, 0)) {
    // The setup read sees the same food the polls will.
    //
    // A hunt's priority list is rebuilt from the live official menu, so the
    // food a test scripts must be available to both reads. The menu is every
    // listing the test scripted, grouped into one menu per meal slot and
    // deduplicated by name — a test that scripts "the portal serves this
    // dish" means the same thing whether the listing appears on the first
    // poll or the second.
    //
    // A test that needs the menu to say something the marketplace cannot
    // passes [menu] explicitly, and it is used as it is.
    if (menu != null) {
      client.menu = menu;
    } else {
      final bySlot = <MealSlot, Map<String, MenuOption>>{};
      for (final page in client.pages) {
        for (final listing in page) {
          bySlot
              .putIfAbsent(listing.slot, () => <String, MenuOption>{})
              .putIfAbsent(listing.option.dishKey, () => listing.option);
        }
      }

      client.menu = [
        for (final entry in bySlot.entries)
          MealMenu(
            date: config.targetDate ?? DateTime.utc(2026, 10, 28),
            slot: entry.key,
            halls: const [central],
            dishes: entry.value.values.toList(),
            reservable: true,
          ),
      ];
    }

    engine = DefaultSnipeEngine(
      client: client,
      sessions: SessionManager(
        client: client,
        store: AlwaysStore(),
        solver: NoopSolver(),
        clock: clock,
      ),
      clock: clock,
      listener: listener,
      random: Random(1),
      // Pacing is measured on the same simulated timeline the polls use, so a
      // test can assert the cadence exactly instead of racing the wall clock.
      deviceNow: () =>
          DateTime.utc(2026, 10, 28).add(Duration(milliseconds: client.clock)),
      defaultPolicy: PollingPolicy(jitterMax: jitterMax),
      sleep: (d) async {
        client.sleeps.add(d);
        client.advance(d);
        // The server clock moves with the timeline: a hunt that waits for its
        // window has to see the window open on the *clock*, not just on the
        // client timeline.
        clock.advance(d);
      },
      // A short wait slice, so a test that waits for a window does not need
      // a real minute per check.
      waitSlice: const Duration(seconds: 1),
    );
  }

  final TimelineClient client;
  final HuntConfig config;
  final RecordingListener listener;
  final MovableServerClock clock;
  late final DefaultSnipeEngine engine;
}

void main() {
  group('the timing rule', () {
    test('the interval is measured from the start of one poll to the start '
        'of the next, not from the end of the response', () async {
      // The important test: it is easy to write an engine that respects the
      // interval when responses are instant and violates it when a response
      // is slow. So the response here is deliberately slow.
      final client = TimelineClient(pages: [[]]);
      client.responseDuration = const Duration(milliseconds: 1500);

      final harness = Harness(
        client: client,
        config: huntConfig(
          rate: HuntRate(
            peakInterval: const Duration(seconds: 10),
            offPeakInterval: const Duration(minutes: 15),
          ),
        ),
        listener: RecordingListener(),
        jitterMax: 1.0,
        // 18:00 portal-local is inside the dinner distribution window, so the
        // hunt polls at the peak rate.
        now: DateTime.utc(2026, 10, 28, 14, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await harness.engine.stop('r1');

      expect(client.pollStarts.length, greaterThanOrEqualTo(2));

      // The gap between the starts is the interval itself. Measuring from the
      // end of the response would make the same gap 11.5 seconds.
      for (var i = 1; i < client.pollStarts.length; i++) {
        final gap = client.pollStarts[i] - client.pollStarts[i - 1];
        expect(
          gap,
          equals(10000),
          reason: 'request $i started $gap ms after the previous one started',
        );
      }
    });

    test('a slow response is subtracted from the wait, not added to it', () async {
      final client = TimelineClient(pages: [[]]);
      client.responseDuration = const Duration(milliseconds: 1500);

      final harness = Harness(
        client: client,
        config: huntConfig(),
        listener: RecordingListener(),
        jitterMax: 1.0,
        now: DateTime.utc(2026, 10, 28, 14, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await harness.engine.stop('r1');

      expect(client.pollStarts.length, greaterThanOrEqualTo(2));

      // The interval is 10s and the response takes 1.5s, so the engine must
      // sleep 8.5s. Adding the response time instead would sleep 10s and start
      // the next request 11.5s after the previous one.
      expect(client.sleeps.first, const Duration(milliseconds: 8500));
      final total = client.pollStarts[1] - client.pollStarts[0];
      expect(total, equals(10000));
    });

    test(
      'a fast user-chosen interval is used exactly, with no upward jitter',
      () async {
        final client = TimelineClient(pages: [[]]);
        client.responseDuration = const Duration(milliseconds: 1500);

        final harness = Harness(
          client: client,
          config: huntConfig(
            rate: HuntRate(
              peakInterval: const Duration(seconds: 2),
              offPeakInterval: const Duration(minutes: 15),
            ),
          ),
          listener: RecordingListener(),
          // The jitter would apply to slower rates; a two-second hunt must not
          // become 2.4 seconds on a random draw.
          jitterMax: 1.2,
          now: DateTime.utc(2026, 10, 28, 14, 30),
        );

        await harness.engine.start(
          ruleFor(harness.config),
          hunt: harness.config,
        );
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await harness.engine.stop('r1');

        expect(client.sleeps, isNotEmpty);
        expect(client.sleeps.first, const Duration(milliseconds: 500));
        for (var i = 1; i < client.pollStarts.length; i++) {
          expect(
            client.pollStarts[i] - client.pollStarts[i - 1],
            equals(2000),
            reason: 'the configured two-second cadence must not stretch',
          );
        }
      },
    );
  });

  group('the peak and off-peak rate', () {
    test(
      'inside the distribution window the hunt polls at the peak rate',
      () async {
        final client = TimelineClient(pages: [[]]);
        final harness = Harness(
          client: client,
          config: huntConfig(
            rate: HuntRate(
              peakInterval: const Duration(seconds: 10),
              offPeakInterval: const Duration(minutes: 15),
            ),
          ),
          listener: RecordingListener(),
          // 18:00 portal-local: inside the 16:30-20:30 dinner window.
          now: DateTime.utc(2026, 10, 28, 14, 30),
        );

        await harness.engine.start(
          ruleFor(harness.config),
          hunt: harness.config,
        );
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await harness.engine.stop('r1');

        expect(client.sleeps, isNotEmpty);
        // The jitter only ever lengthens the wait: the interval is a floor the
        // user set, so the wait is between 10s and 12s.
        expect(
          client.sleeps.first.inMilliseconds,
          inInclusiveRange(10000, 12000),
        );
      },
    );

    test('outside it, the hunt polls at the off-peak rate', () async {
      final client = TimelineClient(pages: [[]]);
      final harness = Harness(
        client: client,
        config: huntConfig(
          // A window wide enough to contain the off-peak hour under test.
          windowStart: const ClockTime(9, 0),
          windowEnd: const ClockTime(23, 0),
          rate: HuntRate(
            peakInterval: const Duration(seconds: 10),
            offPeakInterval: const Duration(minutes: 15),
          ),
        ),
        listener: RecordingListener(),
        // 12:00 portal-local: outside the dinner distribution window.
        now: DateTime.utc(2026, 10, 28, 8, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await harness.engine.stop('r1');

      expect(client.sleeps, isNotEmpty);
      final wait = client.sleeps.first.inMilliseconds;
      expect(wait, inInclusiveRange(12 * 60 * 1000, 18 * 60 * 1000));
    });

    test('a lunch hunt peaks in the morning, not in the evening', () async {
      final client = TimelineClient(pages: [[]]);
      final harness = Harness(
        client: client,
        config: huntConfig(
          slot: MealSlot.lunch,
          // A window covering the morning, and not the dinner peak.
          windowStart: const ClockTime(9, 0),
          windowEnd: const ClockTime(15, 30),
          rate: HuntRate(
            peakInterval: const Duration(seconds: 10),
            offPeakInterval: const Duration(minutes: 15),
          ),
        ),
        listener: RecordingListener(),
        // 12:00 portal-local: inside the 09:00-15:30 lunch window.
        now: DateTime.utc(2026, 10, 28, 8, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await harness.engine.stop('r1');

      expect(
        client.sleeps.first.inMilliseconds,
        inInclusiveRange(10000, 12000),
      );
    });

    test('a lunch hunt is off-peak in the evening', () async {
      final client = TimelineClient(pages: [[]]);
      final harness = Harness(
        client: client,
        config: huntConfig(
          slot: MealSlot.lunch,
          windowStart: const ClockTime(9, 0),
          windowEnd: const ClockTime(20, 0),
          rate: HuntRate(
            peakInterval: const Duration(seconds: 10),
            offPeakInterval: const Duration(minutes: 15),
          ),
        ),
        listener: RecordingListener(),
        // 18:00 portal-local: outside the lunch distribution window, so a
        // lunch hunt must be quiet even though a dinner hunt would be hot.
        now: DateTime.utc(2026, 10, 28, 14, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await harness.engine.stop('r1');

      expect(client.sleeps, isNotEmpty);
      expect(
        client.sleeps.first.inMilliseconds,
        inInclusiveRange(12 * 60 * 1000, 18 * 60 * 1000),
      );
    });
  });

  group('terminate on success', () {
    test(
      'a successful purchase stops the hunt, and it never polls again',
      () async {
        final client = TimelineClient(
          pages: [
            [marketListing(optionId: '99999', name: 'لوبیا پلو')],
          ],
        );
        final listener = RecordingListener();
        final harness = Harness(
          client: client,
          config: huntConfig(),
          listener: listener,
          now: DateTime.utc(2026, 10, 28, 14, 30),
        );

        await harness.engine.start(
          ruleFor(harness.config),
          hunt: harness.config,
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));

        expect(client.claimCalls, 1);
        expect(
          client.pollStarts.length,
          1,
          reason: 'a second poll could buy a second, unwanted meal',
        );
        expect(listener.claims, hasLength(1));
        expect(listener.claims.single, contains('لوبیا پلو'));
      },
    );

    test('a dry run also stops the hunt', () async {
      final client = TimelineClient(
        pages: [
          [marketListing(optionId: '99999', name: 'لوبیا پلو')],
        ],
      );
      final harness = Harness(
        client: client,
        config: huntConfig(),
        listener: RecordingListener(),
        now: DateTime.utc(2026, 10, 28, 14, 30),
      );

      final rule = harness.config.toRule(id: 'r1', account: 'a1', dryRun: true);
      await harness.engine.start(rule, hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(
        client.claimCalls,
        0,
        reason: 'a dry run never calls the write path',
      );
      expect(client.pollStarts.length, 1);

      final ledger = harness.engine.ledgerFor('r1')!;
      expect(ledger.simulatedPurchaseCount, 1);
      expect(ledger.purchaseCount, 0);
    });

    test('a rejected claim does not stop the hunt', () async {
      final client = TimelineClient(
        pages: [
          [marketListing(optionId: '99999', name: 'لوبیا پلو')],
        ],
        claimBehavior: ClaimBehavior.reject,
      );
      final harness = Harness(
        client: client,
        config: huntConfig(),
        listener: RecordingListener(),
        now: DateTime.utc(2026, 10, 28, 14, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await harness.engine.stop('r1');

      expect(
        client.pollStarts.length,
        greaterThan(1),
        reason: 'the hunt continues until the window closes',
      );
    });
  });

  group('the live offering', () {
    test('the priority list is rebuilt with the live price', () async {
      // The setup screen quoted 350,000 for this dish; the market now says
      // 500,000. A hunt that started hours later must use the current
      // figure, both to cap what it pays and to demand the right credit.
      final client = TimelineClient(
        pages: [
          [
            marketListing(
              optionId: '99999',
              name: 'لوبیا پلو',
              priceRial: 500000,
            ),
          ],
        ],
      );
      final harness = Harness(
        client: client,
        config: huntConfig(
          dishes: [
            HuntDish(optionId: '62742', name: 'لوبیا پلو', priceRial: 350000),
          ],
        ),
        listener: RecordingListener(),
        now: DateTime.utc(2026, 10, 28, 14, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await harness.engine.stop('r1');

      expect(
        client.setupReads,
        1,
        reason: 'the hunt reads the offering once, to rebuild the list',
      );

      // The hunt bought the listing at 500,000 — the live price — not the
      // 350,000 the setup screen quoted. The rebuild is what made it.
      expect(client.claimCalls, 1);
      final ledger = harness.engine.ledgerFor('r1')!;
      expect(
        ledger.entries.any((e) => e.message.contains('قیمت')),
        isTrue,
        reason:
            'the rebuild must be recorded, so the price used is explainable',
      );
    });

    test('a dish the market is not offering yet stays on the list', () async {
      // The market offers a different dish. The hunt must keep waiting for
      // the one the user named: a listing that is not there *yet* is exactly
      // what a hunt waits for, and the market fills up during the window.
      final client = TimelineClient(
        pages: [
          [
            marketListing(
              optionId: '99999',
              name: 'چلو گوشت',
              priceRial: 400000,
            ),
          ],
        ],
      );
      final harness = Harness(
        client: client,
        config: huntConfig(
          dishes: [
            HuntDish(optionId: '62742', name: 'لوبیا پلو', priceRial: 350000),
          ],
        ),
        listener: RecordingListener(),
        now: DateTime.utc(2026, 10, 28, 14, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await harness.engine.stop('r1');

      expect(
        client.claimCalls,
        0,
        reason: 'a hunt must never buy a dish the user did not name',
      );
      expect(
        client.pollStarts,
        isNotEmpty,
        reason: 'the hunt must keep waiting for the dish it was asked for',
      );
    });

    test('a dish the portal serves for another meal is dropped', () async {
      // The market offers a lunch dish and the hunt is for breakfast. The
      // lunch dish is not "not on offer yet" — it is a leftover from an
      // earlier target — and the pre-flight demands the credit for the *sum*
      // of the priority list, so keeping it would refuse a hunt that the
      // balance could easily pay for.
      final client = TimelineClient(
        pages: [
          [
            marketListing(
              optionId: '99999',
              name: 'شوید پلو با تن ماهی',
              priceRial: 500000,
              slot: MealSlot.lunch,
            ),
            marketListing(
              optionId: '88888',
              name: 'تخم مرغ2عدد',
              priceRial: 150000,
              slot: MealSlot.breakfast,
            ),
          ],
        ],
      );
      final harness = Harness(
        client: client,
        config: huntConfig(
          slot: MealSlot.breakfast,
          dishes: [
            HuntDish(
              optionId: '99999',
              name: 'شوید پلو با تن ماهی',
              priceRial: 500000,
            ),
            HuntDish(optionId: '88888', name: 'تخم مرغ2عدد', priceRial: 150000),
          ],
        ),
        listener: RecordingListener(),
        // The breakfast of 2026-10-28 is collected with that Tuesday's
        // dinner, so its window opens on the **27th** — and the clock has to
        // be inside it. This is the change F83 made: a hunt's window belongs
        // to the day the meal is taken, not to the day it is dated.
        now: DateTime.utc(2026, 10, 27, 14, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await harness.engine.stop('r1');

      // The breakfast dish was bought, and only that one. The lunch dish was
      // dropped rather than paid for.
      expect(client.claimCalls, 1);
      final ledger = harness.engine.ledgerFor('r1')!;
      expect(
        ledger.entries.any((e) => e.message.contains('حذف شد')),
        isTrue,
        reason: 'the removal must be recorded, so the list is explainable',
      );
    });

    test('the setup read is for the target date', () async {
      final client = TimelineClient(pages: [[]]);
      final harness = Harness(
        client: client,
        config: huntConfig(),
        listener: RecordingListener(),
        now: DateTime.utc(2026, 10, 28, 14, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await harness.engine.stop('r1');

      expect(
        client.setupDate,
        DateTime.utc(2026, 10, 28),
        reason: 'the menu is per date, so the read is for that date',
      );
    });

    test('the rebuild reads the official menu, not the marketplace', () async {
      // The setup screen quoted 350,000; the **menu** says 500,000; the
      // marketplace has the dish for 400,000.
      //
      // The ceiling the hunt enforces is the price on the rebuilt list, so
      // the two outcomes differ and only one of them buys:
      //
      //  * rebuilt from the menu → ceiling 500,000 → the 400,000 listing is
      //    within it, and the hunt buys;
      //  * left at the setup screen's figure → ceiling 350,000 → the
      //    400,000 listing is above it, and the hunt skips it.
      //
      // So "the hunt bought it" is the assertion that the rebuild read the
      // menu. The marketplace could not have produced this answer: it never
      // carries the official price for a (date, slot).
      final client = TimelineClient(
        pages: [
          [
            marketListing(
              optionId: '99999',
              name: 'لوبیا پلو',
              priceRial: 400000,
            ),
          ],
        ],
      );
      final harness = Harness(
        client: client,
        config: huntConfig(
          dishes: [
            HuntDish(optionId: '62742', name: 'لوبیا پلو', priceRial: 350000),
          ],
        ),
        listener: RecordingListener(),
        now: DateTime.utc(2026, 10, 28, 14, 30),
        // The menu names the dish, at the price the setup screen did not know.
        menu: [
          MealMenu(
            date: DateTime.utc(2026, 10, 28),
            slot: MealSlot.dinner,
            halls: const [central],
            dishes: const [
              MenuOption(id: '62742', name: 'لوبیا پلو', priceRial: 500000),
            ],
            reservable: true,
          ),
        ],
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await harness.engine.stop('r1');

      expect(
        client.claimCalls,
        1,
        reason: 'the hunt must buy at the price the official menu quotes',
      );
    });
  });

  group('the hunt polls the target date', () {
    test('the basket is read with the target date as its filter', () async {
      final client = TimelineClient(pages: [[]]);
      final harness = Harness(
        client: client,
        config: huntConfig(),
        listener: RecordingListener(),
        now: DateTime.utc(2026, 10, 28, 14, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await harness.engine.stop('r1');

      expect(client.cursors, isNotEmpty);
      expect(client.cursors.first, '1405/08/06');
    });
  });

  group('waiting for the window', () {
    test('a hunt never polls outside its window', () async {
      final client = TimelineClient(pages: [[]]);
      final harness = Harness(
        client: client,
        config: huntConfig(
          windowStart: const ClockTime(16, 30),
          windowEnd: const ClockTime(20, 30),
        ),
        listener: RecordingListener(),
        // 08:00 portal-local: well before the evening window opens.
        now: DateTime.utc(2026, 10, 28, 4, 30),
      );

      // The clock is observed at every poll, so the assertion is about the
      // *time* of each request rather than about how many there were.
      client.onPoll = () =>
          client.pollTimes.add(portalTime(harness.clock.nowUtc));

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await harness.engine.stop('r1');

      expect(
        client.pollTimes.every(
          (t) => t >= const ClockTime(16, 30) && t <= const ClockTime(20, 30),
        ),
        isTrue,
        reason:
            'outside the window the hunt must not poll at all — that is '
            'what keeps the request count near zero. Polls at: '
            '${client.pollTimes}',
      );
    });

    test('the hunt starts polling once its window opens', () async {
      final client = TimelineClient(pages: [[]]);
      final harness = Harness(
        client: client,
        config: huntConfig(
          windowStart: const ClockTime(16, 30),
          windowEnd: const ClockTime(20, 30),
        ),
        listener: RecordingListener(),
        // 16:29 portal-local: one minute before the window opens.
        now: DateTime.utc(2026, 10, 28, 12, 59),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await harness.engine.stop('r1');

      expect(
        client.pollStarts,
        isNotEmpty,
        reason: 'the hunt must start polling once its window opens',
      );
    });

    test('the hunt ends when the window closes', () async {
      final client = TimelineClient(pages: [[]]);
      final harness = Harness(
        client: client,
        config: huntConfig(
          windowStart: const ClockTime(16, 30),
          windowEnd: const ClockTime(20, 30),
        ),
        listener: RecordingListener(),
        // 20:29 portal-local: inside the window, one minute before it closes.
        now: DateTime.utc(2026, 10, 28, 16, 59),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        harness.engine.isRunning('r1'),
        isFalse,
        reason: 'the window closed, so the hunt is over',
      );
      expect(harness.listener.ends, isNotEmpty);
    });

    test('a hunt for tomorrow does not poll on today', () async {
      // The defect F83 fixed: a hunt's window was a bare time of day, so a
      // hunt for tomorrow's dinner, started this afternoon, found its window
      // open *today* and hunted today's market — a market it can never buy
      // from — burning the request budget against it.
      final client = TimelineClient(pages: [[]]);
      final harness = Harness(
        client: client,
        config: huntConfig(
          slot: MealSlot.dinner,
          targetDate: DateTime.utc(2026, 10, 29),
          windowStart: const ClockTime(16, 30),
          windowEnd: const ClockTime(20, 30),
        ),
        listener: RecordingListener(),
        // 18:00 portal-local on the 28th: inside the *time* of day, but a
        // day early.
        now: DateTime.utc(2026, 10, 28, 14, 30),
      );

      // The day each poll happened on, in the portal's frame.
      final pollDays = <int>[];
      client.onPoll = () => pollDays.add(
        harness.clock.portalNow
            .toUtc()
            .difference(DateTime.utc(2026, 10, 28))
            .inDays,
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await harness.engine.stop('r1');

      expect(
        pollDays.every((d) => d == 1),
        isTrue,
        reason:
            'the hunt is for the 29th, so every poll must land on the '
            '29th. Polls landed on day offsets: $pollDays',
      );
    });

    test('a hunt for tomorrow polls once its day arrives', () async {
      final client = TimelineClient(pages: [[]]);
      final harness = Harness(
        client: client,
        config: huntConfig(
          slot: MealSlot.dinner,
          targetDate: DateTime.utc(2026, 10, 29),
          windowStart: const ClockTime(16, 30),
          windowEnd: const ClockTime(20, 30),
        ),
        listener: RecordingListener(),
        // 18:00 portal-local on the 29th: the hunt's own day.
        now: DateTime.utc(2026, 10, 29, 14, 30),
      );

      await harness.engine.start(ruleFor(harness.config), hunt: harness.config);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await harness.engine.stop('r1');

      expect(
        client.pollStarts,
        isNotEmpty,
        reason: 'the hunt is for the 29th, and this is the 29th',
      );
    });
  });

  group('the pre-flight refusals', () {
    test('a hunt for a slot the account already holds never starts', () async {
      final client = TimelineClient(pages: [[]]);
      final config = huntConfig();
      final harness = Harness(
        client: client,
        config: config,
        listener: RecordingListener(),
        now: DateTime.utc(2026, 10, 28, 14, 30),
      );

      // The account already holds this meal.
      final listener = RecordingListener();
      final engine = DefaultSnipeEngine(
        client: _HoldingClient(),
        sessions: SessionManager(
          client: _HoldingClient(),
          store: AlwaysStore(),
          solver: NoopSolver(),
          clock: harness.clock,
        ),
        clock: harness.clock,
        listener: listener,
        random: Random(1),
        sleep: (_) async {},
      );

      await engine.start(ruleFor(config), hunt: config);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final ledger = engine.ledgerFor('r1')!;
      expect(
        ledger.entries.any((e) => e.kind == LedgerEventKind.preflightFailed),
        isTrue,
      );
      expect(listener.claims, isEmpty);
    });
  });
}

/// A client whose account already holds a dinner on the target date.
class _HoldingClient extends TimelineClient {
  @override
  Future<List<Reservation>> fetchReservations(Session session) async => [
    Reservation(
      id: 'r1',
      date: DateTime.utc(2026, 10, 28),
      slot: MealSlot.dinner,
      hall: central,
      option: const MenuOption(id: 'o1', name: 'x', priceRial: 350000),
      state: ReservationState.active,
    ),
  ];
}
