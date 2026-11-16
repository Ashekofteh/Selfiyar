import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/core/portal/preflight.dart';
import 'package:bahonar_nut/core/hunt/priority.dart';
import 'package:bahonar_nut/core/auth/session.dart';
import 'package:bahonar_nut/core/hunt/snipe.dart';
import 'package:bahonar_nut/core/hunt/snipe_reconciler.dart';
import 'package:bahonar_nut/core/shared/time.dart';
import 'package:test/test.dart';

const central = Hall(id: '1', name: 'مرکزی برادران');

SlotPreference lunchPref() => SlotPreference(
  slot: MealSlot.lunch,
  ranked: const [PreferencePair(hallId: '1', optionId: '62702')],
);

SnipeRule ruleWith({
  Map<MealSlot, SlotPreference>? prefs,
  ClockTime start = const ClockTime(0, 0),
  ClockTime end = const ClockTime(23, 59),
  Set<MealSlot>? slots,
}) => SnipeRule(
  id: 'r1',
  account: 'a1',
  preferences: prefs ?? {MealSlot.lunch: lunchPref()},
  slots: slots ?? {MealSlot.lunch},
  windowStart: start,
  windowEnd: end,
);

SessionReady readySession() => SessionReady(
  session: Session(
    account: 'a1',
    cookies: const {'ASP.NET_SessionId': 'x'},
    establishedAt: DateTime.utc(2026, 10, 18),
  ),
  wasReused: true,
);

void main() {
  const checker = PreflightChecker();
  // Pre-deadline, mid-morning portal-local.
  final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 7, 0));

  group('happy path', () {
    test('passes with a synced clock, a session, preferences and funds', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: clock,
        session: readySession(),
        balance: Balance(
          amountRial: 500000,
          fetchedAt: DateTime.utc(2026, 10, 18),
        ),
        requiredCredit: 350000,
      );
      expect(result.passed, isTrue);
    });

    test('passes when no price ceiling means funds cannot be judged', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: clock,
        session: readySession(),
        balance: null,
        requiredCredit: null,
      );
      expect(result.passed, isTrue);
    });
  });

  group('each precondition fails distinctly', () {
    test('unsynced clock', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: _UnsyncedClock(),
        session: readySession(),
      );
      expect(result.passed, isFalse);
      expect(result.failures, contains(PreflightFailure.clockUnsynced));
    });

    test('no session', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: clock,
        session: const SessionUnavailable(
          reason: 'no creds',
          cause: SessionFailureCause.noCredentials,
        ),
      );
      expect(result.failures, contains(PreflightFailure.noSession));
    });

    test('no preferences configured', () {
      final result = checker.check(
        rule: ruleWith(prefs: const {}),
        clock: clock,
        session: readySession(),
      );
      expect(result.failures, contains(PreflightFailure.noPreferences));
    });

    test('a rule whose only preference is vetoed counts as no preferences', () {
      final vetoed = SlotPreference(
        slot: MealSlot.lunch,
        ranked: const [
          PreferencePair(hallId: '1', optionId: '62702', rejected: true),
        ],
      );
      final result = checker.check(
        rule: ruleWith(prefs: {MealSlot.lunch: vetoed}),
        clock: clock,
        session: readySession(),
      );
      expect(result.failures, contains(PreflightFailure.noPreferences));
    });

    test('a closed window does not refuse the hunt', () {
      // Portal-local 10:00 UTC+3:30 = 13:30, outside an 08:00-09:00 window.
      //
      // The window is not a pre-flight condition. The spec's pre-flight is a
      // list of refusals — the account already holds the meal, the credit does
      // not cover the priority list — and a window that has not opened yet is
      // the ordinary case for a hunt configured in advance. The engine waits
      // for the window instead of refusing the hunt.
      final result = checker.check(
        rule: ruleWith(
          start: const ClockTime(8, 0),
          end: const ClockTime(9, 0),
        ),
        clock: clock,
        session: readySession(),
      );
      expect(result.failures, isEmpty);
      expect(result.passed, isTrue);
    });

    test('insufficient funds', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: clock,
        session: readySession(),
        balance: Balance(
          amountRial: 100000,
          fetchedAt: DateTime.utc(2026, 10, 18),
        ),
        requiredCredit: 350000,
      );
      expect(result.failures, contains(PreflightFailure.insufficientFunds));
    });

    test('unreadable balance', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: clock,
        session: readySession(),
        balance: null,
        requiredCredit: 350000,
      );
      expect(result.failures, contains(PreflightFailure.balanceUnreadable));
    });
  });

  group('failures accumulate rather than short-circuiting', () {
    test('reports both an unsynced clock and a missing session', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: _UnsyncedClock(),
        session: const SessionUnavailable(
          reason: 'x',
          cause: SessionFailureCause.noCredentials,
        ),
      );
      // Both are independent problems with independent fixes.
      expect(result.failures, contains(PreflightFailure.clockUnsynced));
      expect(result.failures, contains(PreflightFailure.noSession));
    });

    test('carries a readable explanation', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: _UnsyncedClock(),
        session: readySession(),
      );
      expect(result.detail, isNotNull);
      expect(result.detail, isNotEmpty);
    });
  });

  group('funds boundary', () {
    test('exactly enough passes', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: clock,
        session: readySession(),
        balance: Balance(
          amountRial: 350000,
          fetchedAt: DateTime.utc(2026, 10, 18),
        ),
        requiredCredit: 350000,
      );
      expect(result.passed, isTrue);
    });

    test('one rial short fails', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: clock,
        session: readySession(),
        balance: Balance(
          amountRial: 349999,
          fetchedAt: DateTime.utc(2026, 10, 18),
        ),
        requiredCredit: 350000,
      );
      expect(result.failures, contains(PreflightFailure.insufficientFunds));
    });
  });

  group('the one-meal invariant', () {
    final target = DateTime.utc(2026, 10, 28);

    Reservation held({
      MealSlot slot = MealSlot.lunch,
      DateTime? date,
      ReservationState state = ReservationState.active,
    }) => Reservation(
      id: 'r1',
      date: date ?? target,
      slot: slot,
      hall: central,
      option: const MenuOption(id: 'o1', name: 'dish', priceRial: 350000),
      state: state,
    );

    test('refuses when the account already holds that date and slot', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: clock,
        session: readySession(),
        targetDate: target,
        holdings: [held()],
      );
      expect(result.failures, contains(PreflightFailure.alreadyBooked));
    });

    test('allows a meal held in a different slot on the same date', () {
      // The invariant is one meal per slot per date, so a breakfast and a
      // lunch on the same day are both fine.
      final result = checker.check(
        rule: ruleWith(),
        clock: clock,
        session: readySession(),
        targetDate: target,
        holdings: [held(slot: MealSlot.breakfast)],
      );
      expect(result.passed, isTrue);
    });

    test('allows a meal held on a different date', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: clock,
        session: readySession(),
        targetDate: target,
        holdings: [held(date: DateTime.utc(2026, 10, 29))],
      );
      expect(result.passed, isTrue);
    });

    test('ignores a cancelled or consumed meal', () {
      // A released meal is not a held meal, so it does not block the hunt.
      final result = checker.check(
        rule: ruleWith(),
        clock: clock,
        session: readySession(),
        targetDate: target,
        holdings: [held(state: ReservationState.cancelled)],
      );
      expect(result.passed, isTrue);
    });

    test('refuses when the holdings could not be read', () {
      // A refusal rather than a pass: starting a hunt without knowing whether
      // the slot is already filled is exactly how a double purchase happens.
      final result = checker.check(
        rule: ruleWith(),
        clock: clock,
        session: readySession(),
        targetDate: target,
        holdings: null,
      );
      expect(result.failures, contains(PreflightFailure.holdingsUnreadable));
    });

    test('does not check the invariant when no target date is set', () {
      final result = checker.check(
        rule: ruleWith(),
        clock: clock,
        session: readySession(),
        holdings: null,
      );
      expect(
        result.failures,
        isNot(contains(PreflightFailure.holdingsUnreadable)),
      );
    });
  });

  group('ClaimReconciler', () {
    final listing = Listing(
      id: 'L1',
      date: DateTime.utc(2026, 10, 20),
      slot: MealSlot.lunch,
      hall: central,
      option: const MenuOption(id: 'o1', name: 'dish', priceRial: 350000),
    );

    test('concludes claimed when the buy page now shows the row as held', () async {
      // The reconciler reads the **buy page**, not the weekly reservation
      // grid: a basket purchase does not appear in the grid (verified live
      // 2026-10-19), so a grid-reading reconciler would conclude "not claimed"
      // for every successful purchase — and invite a second one.
      final client = _ReconClient(
        hold: const BasketHoldStatus(checked: true, amountRial: 350000),
      );
      final outcome = await const ClaimReconciler().reconcile(
        client: client,
        session: _session(),
        listing: listing,
      );
      expect(outcome, ReconciliationOutcome.claimed);
    });

    test('concludes notClaimed when the row is offered but not held', () async {
      final client = _ReconClient(
        hold: const BasketHoldStatus(checked: false, amountRial: 0),
      );
      final outcome = await const ClaimReconciler().reconcile(
        client: client,
        session: _session(),
        listing: listing,
      );
      expect(outcome, ReconciliationOutcome.notClaimed);
    });

    test('concludes notClaimed when the row is gone entirely', () async {
      // No row at all means the portal no longer offers this listing: it was
      // sold to someone else or withdrawn. Either way it is not ours.
      final client = _ReconClient(hold: null);
      final outcome = await const ClaimReconciler().reconcile(
        client: client,
        session: _session(),
        listing: listing,
      );
      expect(outcome, ReconciliationOutcome.notClaimed);
    });

    test('a checked row with a zero amount is not held', () async {
      // "checked" alone is unreliable: the portal echoes the posted checkbox
      // for a row it did not charge. The amount is the reliable signal.
      final client = _ReconClient(
        hold: const BasketHoldStatus(checked: true, amountRial: 0),
      );
      final outcome = await const ClaimReconciler().reconcile(
        client: client,
        session: _session(),
        listing: listing,
      );
      expect(outcome, ReconciliationOutcome.notClaimed);
    });

    test('concludes indeterminate when the re-read fails', () async {
      final client = _ReconClient(throwOnRead: true);
      final outcome = await const ClaimReconciler().reconcile(
        client: client,
        session: _session(),
        listing: listing,
      );
      expect(outcome, ReconciliationOutcome.indeterminate);
    });

    test('the re-read asks about the listing\'s own date and option', () async {
      // The reconciler must ask the buy page about *this* listing, for *this*
      // date — a re-read of the wrong date would report a different row and
      // conclude wrongly.
      final client = _ReconClient(
        hold: const BasketHoldStatus(checked: true, amountRial: 350000),
      );
      await const ClaimReconciler().reconcile(
        client: client,
        session: _session(),
        listing: listing,
      );
      expect(client.askedDate, DateTime.utc(2026, 10, 20));
      expect(client.askedOptionId, 'o1');
    });
  });
}

Session _session() => Session(
  account: 'a1',
  cookies: const {'ASP.NET_SessionId': 'x'},
  establishedAt: DateTime.utc(2026, 10, 18),
);

/// Minimal client that only serves [holdingsOnBuyPage].
class _ReconClient implements PortalClient {
  _ReconClient({this.hold, this.throwOnRead = false});

  /// What the buy page says about the row. Null means "no such row".
  final BasketHoldStatus? hold;
  final bool throwOnRead;

  DateTime? askedDate;
  String? askedOptionId;

  @override
  Future<BasketHoldStatus?> holdingsOnBuyPage(
    Session session, {
    required DateTime date,
    required String optionId,
  }) async {
    if (throwOnRead) throw Exception('network down');
    askedDate = date;
    askedOptionId = optionId;
    return hold;
  }

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async =>
      const <Transaction>[];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not used');
}

class _UnsyncedClock implements ServerClock {
  @override
  DateTime get nowUtc => DateTime.utc(2026, 10, 18);

  @override
  bool get isSynced => false;

  @override
  Duration get staleness => Duration.zero;
}
