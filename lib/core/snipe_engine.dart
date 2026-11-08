/// The snipe engine: the loop that actually wins a listing.
///
/// Assembly rather than invention — every part it needs already exists and is
/// tested. This file wires them together and owns the one thing none of them
/// can own alone: the ordering of decisions within a live hunt.
///
/// The ordering is the whole design, and it is deliberate:
///   1. Preflight, before the loop. Never discover a dead session mid-hunt.
///   2. Poll, then filter tombstoned listings, then rank. A dead listing must
///      never reach the ranker, because a match on a dead listing costs a claim
///      attempt that looks like a retry attack.
///   3. One in-flight claim, ever. Serialised per account.
///   4. On ambiguity, reconcile — never retry. This is the double-purchase guard.
///
/// Fully testable with fakes: the client, clock and sleep are all injected, so
/// the whole hunt runs deterministically in milliseconds.
library;

import 'dart:async';
import 'dart:math';

import 'hunt_config.dart';
import 'hunt_ranker.dart';
import 'ledger.dart';
import 'models.dart';
import 'persian.dart';
import 'polling.dart';
import 'portal.dart';
import 'preflight.dart';
import 'priority.dart';
import 'request_ledger.dart';
import 'session.dart';
import 'session_manager.dart';
import 'snipe.dart';
import 'time.dart';
import 'tombstone.dart';

/// Notified when a hunt ends, so the platform layer can release the service
/// and the UI can say what happened.
///
/// An interface rather than a callback so the engine keeps no reference to the
/// platform: the whole loop stays testable on the VM.
abstract class HuntOutcomeListener {
  /// A meal was bought.
  Future<void> onClaimed({
    required String ruleId,
    required Listing listing,
    required Reservation reservation,
  });

  /// The run ended without buying: window closed, budget spent, cancelled, or
  /// a precondition failed.
  Future<void> onEnded({
    required String ruleId,
    required SnipeState state,
    required String reason,
  });
}

/// An optional no-op listener, for tests and for callers that do not care.
class NoopHuntListener implements HuntOutcomeListener {
  const NoopHuntListener();

  @override
  Future<void> onClaimed({
    required String ruleId,
    required Listing listing,
    required Reservation reservation,
  }) async {}

  @override
  Future<void> onEnded({
    required String ruleId,
    required SnipeState state,
    required String reason,
  }) async {}
}

/// Signals the engine to end before its natural termination.
class SnipeCancelled implements Exception {
  const SnipeCancelled();

  @override
  String toString() => 'SnipeCancelled';
}

/// The engine's public surface, matching the frozen spec interface.
abstract class SnipeEngine {
  /// Starts a rule. Idempotent for an already-running rule.
  ///
  /// [hunt] is the hunt configuration, when the rule is a hunt. It supplies
  /// the window, the peak/off-peak rate and the priority list the rule's own
  /// fields cannot express.
  Future<void> start(SnipeRule rule, {HuntConfig? hunt});

  /// Runs the pre-flight checks without starting the hunt.
  ///
  /// The screen calls this so the user sees a verdict — and a refusal — before
  /// anything is bought.
  Future<PreflightResult> preflight(SnipeRule rule, {HuntConfig? hunt});

  /// Where the engine reports a hunt's outcome.
  ///
  /// Settable rather than fixed, because the listener usually needs to know
  /// *which* account the hunt belongs to — and the account is only known when
  /// the hunt starts, long after the engine was built.
  set listener(HuntOutcomeListener value);

  /// Stops a running rule and releases its resources.
  Future<void> stop(String ruleId);

  /// Whether a run is currently active for [ruleId].
  bool isRunning(String ruleId);

  /// Live state for the UI.
  Stream<SnipeRunStatus> watch(String ruleId);
}

/// Concrete engine.
class DefaultSnipeEngine implements SnipeEngine {
  DefaultSnipeEngine({
    required this._client,
    required this._sessions,
    required this._clock,
    this._ranker = const PriorityRanker(),
    this._huntRanker = const HuntRanker(),
    this._preflight = const PreflightChecker(),
    this._reconciler = const ClaimReconciler(),
    this._defaultPolicy = const PollingPolicy(),
    this._listener = const NoopHuntListener(),
    this._requests,
    Random? random,
    Future<void> Function(Duration)? sleep,
    Duration? waitSlice,
  })  : _random = random ?? Random(),
        _sleep = sleep ?? Future<void>.delayed,
        _waitSlice = waitSlice ?? const Duration(minutes: 1);

  final PortalClient _client;
  final SessionManager _sessions;
  final ServerClock _clock;
  final PriorityRanker _ranker;
  final HuntRanker _huntRanker;
  final PreflightChecker _preflight;
  final ClaimReconciler _reconciler;
  final PollingPolicy _defaultPolicy;
  final Random _random;

  /// The record of the requests the app has actually made.
  ///
  /// Optional, and null in the tests that use a fake client — a fake never
  /// touches the transport, so there is nothing to count. When it is present
  /// the run's budget is measured in **requests**, which is what the portal
  /// sees, rather than in polls, which is what it used to be measured in.
  final RequestLedger? _requests;

  /// How long the engine sleeps between checks while waiting for a window.
  ///
  /// Injected so a test can drive the wait without waiting a real minute per
  /// check — the wait is a *clock* question, so the test controls the clock
  /// and the cadence together.
  final Duration _waitSlice;

  /// Where the engine reports a hunt's outcome.
  ///
  /// Settable rather than fixed, because the listener usually needs to know
  /// *which* account the hunt belongs to — and the account is only known when
  /// the hunt starts, long after the engine was built.
  HuntOutcomeListener _listener;

  @override
  set listener(HuntOutcomeListener value) => _listener = value;

  /// Injected so tests advance the loop without waiting real time.
  ///
  /// A test that had to sleep 45 jittered seconds per iteration would be slow
  /// enough that nobody would run it, and an untested hunt loop is exactly the
  /// code that must not be taken on faith.
  final Future<void> Function(Duration) _sleep;

  final Map<String, _Run> _runs = {};

  /// Ledgers outlive their runs: a completed run is removed from [_runs], but
  /// its ledger stays readable so a purchase can be explained after the fact.
  /// Each ledger is already bounded (see [SnipeLedger.maxEntries]).
  final Map<String, SnipeLedger> _ledgers = {};

  /// The hunt configuration per rule, when the caller supplied one.
  final Map<String, HuntConfig> _huntConfigs = {};

  @override
  Future<void> start(SnipeRule rule, {HuntConfig? hunt}) async {
    if (_runs.containsKey(rule.id)) return; // idempotent

    // A disabled rule does not run.
    //
    // The `enabled` flag is the hunt's opt-in, and it is checked **here**
    // rather than only in the UI. The UI is not the only thing that can start
    // a rule: the platform can ask for a hunt at a moment when the student is
    // not looking at the screen, and a hunt that spends money must not start
    // because nobody was watching.
    //
    // The check is the same one the pre-flight makes, so a rule refused here
    // is refused there too, and the student sees one reason rather than two.
    if (!rule.enabled) return;

    if (hunt != null) _huntConfigs[rule.id] = hunt;

    final run = _Run(rule: rule, status: _initialStatus(rule), hunt: hunt);
    _runs[rule.id] = run;
    _ledgers[rule.id] = run.ledger;

    // Kick off the loop without blocking the caller: `start` returns once the
    // run is registered, so the UI can subscribe before the first poll.
    run.future = _runLoop(run);
  }

  @override
  Future<void> stop(String ruleId) async {
    final run = _runs[ruleId];
    if (run == null) return;
    run.cancel();
    try {
      await run.future;
    } catch (_) {
      // Cancellation is expected to surface as an error from the loop.
    }
    _runs.remove(ruleId);
  }

  @override
  Stream<SnipeRunStatus> watch(String ruleId) {
    final run = _runs[ruleId];
    if (run == null) return const Stream.empty();
    return run.controller.stream;
  }

  /// The ledger for a run, for the log screen and for tests.
  ///
  /// Survives the run's completion: explaining a purchase after the fact is the
  /// ledger's entire purpose.
  SnipeLedger? ledgerFor(String ruleId) => _ledgers[ruleId];

  /// Whether a rule is currently running.
  @override
  bool isRunning(String ruleId) => _runs.containsKey(ruleId);

  /// Runs the pre-flight checks without starting the hunt.
  ///
  /// The hunt screen calls this to show the user a verdict **before** anything
  /// is bought: the dish, the hall, the window, the projected request count —
  /// or the reason the hunt would be refused. Only then does the user press
  /// start.
  ///
  /// A pre-flight failure is free: it costs the reads the check itself needs
  /// and nothing more. A failure discovered mid-hunt has already spent the
  /// request budget and possibly the money.
  @override
  Future<PreflightResult> preflight(SnipeRule rule, {HuntConfig? hunt}) async {
    final inputs = await _readPreflightInputs(rule);
    return _preflight.check(
      rule: rule,
      clock: _clock,
      session: inputs.session,
      balance: inputs.balance,
      requiredCredit: hunt?.requiredCreditRial,
      targetDate: hunt?.targetDate,
      holdings: inputs.holdings,
      hunt: hunt,
    );
  }

  /// The reads a pre-flight needs: the session, the balance and the holdings.
  ///
  /// A read that fails yields null rather than throwing, because "could not
  /// read it" and "read it and it is zero" are different facts, and the
  /// checker has to be able to tell them apart.
  Future<_PreflightInputs> _readPreflightInputs(SnipeRule rule) async {
    final sessionResult = await _sessions.ensureSession(rule.account);
    final session = _sessions.sessionFor(rule.account);

    Balance? balance;
    List<Reservation>? holdings;

    if (session != null) {
      Future<Balance?> readBalance() async {
        try {
          return await _client.fetchBalance(session);
        } on LoginRejectedException {
          return await _sessions.withSession(
            rule.account,
            (fresh) => _client.fetchBalance(fresh),
          );
        } catch (_) {
          return null;
        }
      }

      Future<List<Reservation>?> readHoldings() async {
        try {
          return await _client.fetchReservations(session);
        } on LoginRejectedException {
          return await _sessions.withSession(
            rule.account,
            (fresh) => _client.fetchReservations(fresh),
          );
        } catch (_) {
          return null;
        }
      }

      final results = await Future.wait([
        readBalance(),
        readHoldings(),
      ]);
      balance = results[0] as Balance?;
      holdings = results[1] as List<Reservation>?;
    }

    return _PreflightInputs(
      session: sessionResult,
      balance: balance,
      holdings: holdings,
    );
  }

  SnipeRunStatus _initialStatus(SnipeRule rule) => SnipeRunStatus(
        ruleId: rule.id,
        state: SnipeState.idle,
      );

  Future<void> _runLoop(_Run run) async {
    final rule = run.rule;
    final ledger = run.ledger;

    try {
      _transition(run, SnipeState.preflight);
      ledger.record(
        at: _clock.isSynced ? _clock.nowUtc : DateTime.now().toUtc(),
        kind: LedgerEventKind.started,
        message: 'اجرای قانون آغاز شد.',
      );

      // --- Preflight ---
      final inputs = await _readPreflightInputs(rule);
      final session = _sessions.sessionFor(rule.account);

      // A hunt's priority list is rebuilt from the **live official menu** for
      // the target date and slot, not reused from the setup screen.
      //
      // A price belongs to a (date, slot): the same option costs 2,150,000
      // as a breakfast and 500,000 as a lunch. So a hunt that starts hours
      // after the screen was filled — or for a different date than the one
      // the screen was filled for — must use the current figure, both for the
      // price it will pay and for the credit the pre-flight demands.
      if (run.hunt != null) {
        final rebuilt = await _rebuildFromLiveMenu(run, session);
        if (rebuilt == null) return; // The read failed; the run has ended.
        run.hunt = rebuilt;
      }

      // The pre-flight judges the *rebuilt* list. A dish the portal is not
      // offering for the target date and slot has been dropped, and a hunt
      // with nothing left to buy must be refused — not left polling a market
      // it will never match.
      final hunt = run.hunt;

      final verdict = _preflight.check(
        rule: rule,
        clock: _clock,
        session: inputs.session,
        balance: inputs.balance,
        requiredCredit: hunt?.requiredCreditRial,
        targetDate: hunt?.targetDate,
        holdings: inputs.holdings,
        hunt: hunt,
      );

      if (!verdict.passed) {
        ledger.record(
          at: DateTime.now().toUtc(),
          kind: LedgerEventKind.preflightFailed,
          message: verdict.detail ?? 'پیش‌نیازها برقرار نبود.',
        );
        _finish(run, SnipeState.aborted, verdict.detail ?? 'preflight failed');
        await _listener.onEnded(
          ruleId: rule.id,
          state: SnipeState.aborted,
          reason: verdict.detail ?? 'preflight failed',
        );
        return;
      }

      ledger.record(
        at: _now(),
        kind: LedgerEventKind.preflightPassed,
        message: 'پیش‌نیازها بررسی شد.',
      );

      _transition(run, SnipeState.hunting);

      // --- Hunt ---
      run.session = session;
      await _hunt(run, session!, inputs.balance);
    } on SnipeCancelled {
      _finish(run, SnipeState.windowExpired, 'stopped by user');
      await _listener.onEnded(
        ruleId: rule.id,
        state: SnipeState.windowExpired,
        reason: 'stopped by user',
      );
    } catch (error) {
      ledger.record(
        at: DateTime.now().toUtc(),
        kind: LedgerEventKind.runEnded,
        message: 'اجرا با خطا پایان یافت: $error',
      );
      _finish(run, SnipeState.aborted, error.toString());
      await _listener.onEnded(
        ruleId: rule.id,
        state: SnipeState.aborted,
        reason: error.toString(),
      );
    } finally {
      // A finished run leaves the registry: otherwise `isRunning` would lie
      // forever and the run would leak. The ledger survives in `_ledgers`.
      _runs.remove(rule.id);
      run.controller.close();
    }
  }

  Future<void> _hunt(_Run run, Session session, Balance? balance) async {
    final rule = run.rule;
    final hunt = run.hunt;
    final policy = _defaultPolicy;
    final breaker = CircuitBreaker(policy.failureThreshold);
    final allocatedBudget = hunt != null
        ? max(hunt.requestBudget, (hunt.projectedRequests() * 1.3).ceil())
        : policy.requestBudget;
    final budget = RequestBudget(allocatedBudget);

    // The run's own request count, taken from the ledger when there is one.
    //
    // The ledger counts **requests**; the budget used to count **polls**, and
    // a poll is one or two requests — so the backstop against a ban was
    // allowing twice the traffic it was written to allow. When the ledger is
    // absent (a test with a fake client) the poll count stands, because
    // there is no transport and so no request to count.
    final requests = _requests;
    final requestsAtStart = requests?.totalFor(session.account) ?? 0;

    /// The requests this run has spent.
    int requestsSpent() => requests == null
        ? budget.spent
        : (requests.totalFor(session.account) - requestsAtStart);

    while (!run.isCancelled) {
      // The window is re-evaluated every cycle, because crossing into the
      // window mid-hunt is exactly when the rate should change — and because
      // a window that closes mid-hunt has to end the run.
      final now = _now();
      final clockTime = _clock.isSynced
          ? ClockTime(_clock.portalNow.hour, _clock.portalNow.minute)
          : null;
      final portalDate = _clock.isSynced ? _clock.portalTodayUtc : null;

      // The window is checked against the **date** as well as the time of
      // day, for a hunt whose window is attached to a collection date.
      //
      // A time-of-day check alone would open today's window for a hunt that
      // belongs to tomorrow, and the hunt would poll the wrong day's market —
      // burning the request budget against listings it can never buy, and
      // ending a day early.
      if (clockTime != null && !rule.isOpenAt(clockTime, portalDate)) {
        // Outside the window the hunt does **not** poll at all. It waits.
        //
        // The spec is explicit: outside the hunt window the engine does not
        // poll, it sleeps until the window opens, which is what keeps the
        // request count near zero for a user who only hunts in the evening.
        //
        // The distinction that matters is *which* side of the window we are
        // on. A window that has not opened yet is a wait; a window that has
        // closed after the hunt was running is the end of the hunt. The run
        // knows the difference because it remembers whether it has ever polled
        // inside the window.
        if (run.hasHunted) {
          run.ledger.record(
            at: now,
            kind: LedgerEventKind.runEnded,
            message: 'بازه زمانی به پایان رسید.',
          );
          _finish(run, SnipeState.windowExpired, 'window closed');
          await _listener.onEnded(
            ruleId: rule.id,
            state: SnipeState.windowExpired,
            reason: 'window closed',
          );
          return;
        }

        // Wait for the window to open. No request is spent on the wait, so
        // the request budget is untouched and the account sees no traffic.
        final outcome = await _waitForWindow(run, clockTime);
        if (outcome != _WindowWait.opened) return; // Cancelled, or gave up.
        continue;
      }

      // The budget is checked in **requests** when the ledger is available.
      //
      // The poll counter is still spent, because it is what the run's own
      // accounting reports and what the tests exercise. But the thing that
      // ends the run is the request count, because that is what the portal
      // sees and therefore what the budget exists to bound.
      if (requestsSpent() >= budget.limit) {
        run.ledger.record(
          at: now,
          kind: LedgerEventKind.runEnded,
          message: 'سهمیه درخواست این اجرا به پایان رسید.',
        );
        _finish(run, SnipeState.windowExpired, 'budget exhausted');
        await _listener.onEnded(
          ruleId: rule.id,
          state: SnipeState.windowExpired,
          reason: 'budget exhausted',
        );
        return;
      }

      budget.spend();
      // The run has now hunted: from here on, being outside the window means
      // the window has closed rather than that it has yet to open.
      run.hasHunted = true;
      // The session is read from the run each cycle, not captured once: a hunt
      // outlives the session it started with, and a poll that kept using the
      // expired one would never see the market again.
      final pollOk = await _pollOnce(run, run.session ?? session, balance);

      if (pollOk) {
        breaker.recordSuccess();
      } else {
        if (breaker.recordFailure()) {
          run.ledger.record(
            at: _now(),
            kind: LedgerEventKind.runEnded,
            message: 'پس از چند خطای متوالی، اجرا متوقف شد.',
          );
          _finish(run, SnipeState.aborted, 'circuit open');
          await _listener.onEnded(
            ruleId: rule.id,
            state: SnipeState.aborted,
            reason: 'circuit open',
          );
          return;
        }
      }

      // A completed claim ends the run.
      if (SnipeStateMachine.isTerminal(run.status.state)) return;

      // The interval is measured from the *end* of the previous cycle, not
      // from its start. The wait below is chained after the poll has finished
      // and been parsed, so a slow response cannot overlap the next request.
      //
      // The hunt's rate is a function of the time: peak inside the target
      // meal's distribution window, off-peak outside it.
      final interval = _intervalFor(
        run,
        clockTime,
        breaker.consecutiveFailures,
        portalDate: portalDate,
      );
      await _sleep(interval);
    }
    throw const SnipeCancelled();
  }

  /// The wait before the next poll.
  ///
  /// A hunt uses its configured rate; a plain rule uses the policy's cadence.
  ///
  /// ## The hunt's jitter only ever lengthens the wait
  ///
  /// The policy's jitter is symmetric — 0.8× to 1.2× — because for a rule
  /// nobody configured, the mean is what matters. For a hunt it does not: the
  /// user set a rate, and the rate is a **floor**. A symmetric jitter could
  /// make the hunt poll *faster* than the user asked, which would
  ///
  ///   - undercut the hard floor (a 2-second peak could become 1.6 seconds),
  ///   - break the floor the ban acknowledgement is attached to, and
  ///   - make the projected request count a lie, since the UI prices the
  ///     slider from the nominal interval.
  ///
  /// So the hunt's jitter is one-sided: the wait is the interval or a little
  /// longer, never shorter. The clients still do not synchronise — each one
  /// has its own random offset — so the original reason for jitter survives.
  ///
  /// The hunt's floor is [HuntBounds], not the policy's 20-second hard floor.
  /// The two disagree on purpose: the policy's floor governs a rule that
  /// nobody configured, and the hunt's bounds are the product owner's explicit
  /// decision — 2 seconds in peak, with a ban-risk acknowledgement above it.
  /// The hunt's rate is clamped on construction, so it cannot be out of range
  /// by the time it reaches here.
  Duration _intervalFor(
    _Run run,
    ClockTime? clockTime,
    int consecutiveFailures, {
    DateTime? portalDate,
  }) {
    final hunt = run.hunt;
    if (hunt == null) {
      return _defaultPolicy.nextInterval(
        consecutiveFailures: consecutiveFailures,
        random: _random,
      );
    }

    final base = clockTime == null
        ? hunt.rate.offPeakInterval
        : hunt.intervalAt(clockTime, portalDate: portalDate);

    // A failure backs the hunt off too: when something is wrong, asking less
    // often protects both the portal and the account.
    var interval = base;
    if (consecutiveFailures > 0) {
      final multiplier = 1 << consecutiveFailures;
      final backedOff = base * multiplier;
      interval = backedOff > _defaultPolicy.maxBackoff
          ? _defaultPolicy.maxBackoff
          : backedOff;
    }

    // One-sided jitter: the factor is in [1, jitterMax], never below 1.
    final factor = 1 + _random.nextDouble() * (_defaultPolicy.jitterMax - 1);

    return Duration(
      microseconds: (interval.inMicroseconds * factor).round(),
    );
  }

  /// Rebuilds the hunt's priority list from the live official menu.
  ///
  /// Returns null when the menu could not be read, in which case the run
  /// has already been ended — a hunt that proceeds with a stale price list
  /// would demand the wrong credit and could buy at the wrong price.
  ///
  /// ## Why the menu and not the marketplace
  ///
  /// The menu is the **official offering**: it says which dishes the
  /// university serves for a (date, slot), at what price, in which halls.
  /// The marketplace says which meals have been *released* for sale — a
  /// subset of the menu, and one that empties as the day goes on.
  ///
  /// The rebuild needs the official offering, for two reasons:
  ///
  ///  * **The price.** A price belongs to a (date, slot), and the menu is
  ///    where the portal publishes it. The marketplace may not have the dish
  ///    at all yet, and then it has no price to give.
  ///  * **Which meal a dish belongs to.** The marketplace only shows
  ///    released meals, so a dish that has not been released carries no slot
  ///    information — and the rebuild could not tell "not on offer yet" from
  ///    "belongs to another meal". The menu always knows.
  ///
  /// The marketplace remains where the hunt's *listings* come from: the
  /// polling, the ranking and the claim all happen there.
  Future<HuntConfig?> _rebuildFromLiveMenu(_Run run, Session? session) async {
    final hunt = run.hunt!;
    final effectiveSession = session ?? run.session;
    if (effectiveSession == null) return hunt;

    final targetDate = hunt.targetDate;
    if (targetDate == null) return hunt;

    List<MealMenu> menus;
    try {
      menus = await _client.fetchMenu(effectiveSession, targetDate);
    } on LoginRejectedException {
      try {
        menus = await _sessions.withSession(
          run.rule.account,
          (fresh) => _client.fetchMenu(fresh, targetDate),
        );
        run.session = _sessions.sessionFor(run.rule.account);
      } catch (error) {
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.runEnded,
          message: 'خواندن منوی غذاهای روز از سامانه ممکن نشد: $error',
        );
        _finish(run, SnipeState.aborted, 'offering unreadable');
        await _listener.onEnded(
          ruleId: run.rule.id,
          state: SnipeState.aborted,
          reason: 'offering unreadable',
        );
        return null;
      }
    } catch (error) {
      run.ledger.record(
        at: _now(),
        kind: LedgerEventKind.runEnded,
        message: 'خواندن منوی غذاهای روز از سامانه ممکن نشد: $error',
      );
      _finish(run, SnipeState.aborted, 'offering unreadable');
      await _listener.onEnded(
        ruleId: run.rule.id,
        state: SnipeState.aborted,
        reason: 'offering unreadable',
      );
      return null;
    }

    // The live price for each dish, taken from the official menu for the
    // target date and slot.
    final livePrice = <String, int>{};
    final liveOptionId = <String, String>{};
    // Which slots serve each dish on this date, so a dish that belongs to a
    // *different* meal can be told apart from one that is simply not on
    // offer yet.
    final offeredIn = <String, Set<MealSlot>>{};

    for (final menu in menus) {
      for (final dish in menu.dishes) {
        final key = dish.dishKey;
        offeredIn.putIfAbsent(key, () => <MealSlot>{}).add(menu.slot);
        if (menu.slot != hunt.targetSlot) continue;
        livePrice.putIfAbsent(key, () => dish.priceRial);
        liveOptionId.putIfAbsent(key, () => dish.id);
      }
    }

    // The prices are refreshed; a dish the menu does not offer *right now*
    // is **not** dropped.
    //
    // A dish the portal is not offering right now is exactly what a hunt
    // waits for — the market fills up during the window, which is the whole
    // point of hunting. Dropping it would end the hunt before the listing it
    // is waiting for appears.
    //
    // The price is the part that must be refreshed: it belongs to a
    // (date, slot), and the hunt may start for a different one than the
    // setup screen quoted. A dish the menu does not list keeps the price
    // the setup screen quoted, because there is no live figure to use and a
    // hunt with no price could not be credit-checked.
    //
    // A dish the portal serves for a **different** meal on this date is a
    // different matter: it is not "not on offer yet", it is a dish left in
    // the list from an earlier target. The pre-flight demands the credit for
    // the *sum* of the priority list, so a stale 500,000 Rial lunch dish in a
    // breakfast hunt would refuse a hunt that 150,000 Rial would have paid
    // for. Such a dish is dropped.
    final rebuilt = <HuntDish>[];
    var repriced = 0;
    var dropped = 0;
    for (final dish in hunt.dishPriority) {
      final price = livePrice[dish.dishKey];
      if (price == null) {
        final slots = offeredIn[dish.dishKey];
        if (slots != null && !slots.contains(hunt.targetSlot)) {
          dropped++;
          continue;
        }
        rebuilt.add(dish);
        continue;
      }
      if (price != dish.priceRial) repriced++;
      rebuilt.add(HuntDish(
        optionId: liveOptionId[dish.dishKey] ?? dish.optionId,
        name: dish.name,
        priceRial: price,
      ));
    }

    run.ledger.record(
      at: _now(),
      kind: LedgerEventKind.preflightPassed,
      message: _rebuildMessage(repriced: repriced, dropped: dropped),
    );

    return hunt.copyWith(dishPriority: rebuilt);
  }

  /// The ledger line describing what the rebuild did.
  static String _rebuildMessage({required int repriced, required int dropped}) {
    final parts = <String>[];
    if (repriced > 0) {
      parts.add('قیمت ${toPersianDigits(repriced)} غذا با پیشنهاد زنده سامانه '
          'به‌روزرسانی شد');
    } else {
      parts.add('قیمت غذاها با پیشنهاد زنده سامانه بررسی شد');
    }
    if (dropped > 0) {
      parts.add('${toPersianDigits(dropped)} غذای این وعده نبود و از فهرست '
          'حذف شد');
    }
    return '${parts.join('، و ')}.';
  }

  /// Sleeps until the hunt's window opens.
  ///
  /// ## Why the wait is bounded
  ///
  /// A window is a time of day, so its next occurrence is either today or
  /// tomorrow — the wait is bounded by construction. A hunt configured for a
  /// window that can never open therefore cannot sleep forever, holding the
  /// foreground service and the alarm with it.
  ///
  /// ## Why the wait re-reads the clock
  ///
  /// The wait is driven by the *server* clock, not by counting down. A device
  /// that was dozing, or a clock that drifted while the hunt waited, would
  /// otherwise wake up hours late and miss the very window it was waiting for.
  ///
  /// ## Why the wait is chopped up
  ///
  /// The wait is a sequence of short sleeps rather than one long one, so a
  /// cancellation is noticed within a slice instead of at the end of the
  /// window. The user pressing "stop" must not have to wait until evening.
  ///
  /// The slice is a minute: short enough that a cancellation is prompt, long
  /// enough that a hunt waiting for an evening window does not wake the radio
  /// hundreds of times before it opens.
  Future<_WindowWait> _waitForWindow(_Run run, ClockTime now) async {
    final rule = run.rule;

    run.ledger.record(
      at: _now(),
      kind: LedgerEventKind.waiting,
      message: 'بازه زمانی هنوز باز نشده است؛ شکار تا زمان باز شدن آن '
          'منتظر می‌ماند و درخواستی نمی‌فرستد.',
    );

    // The wait ends at the window's own end, on the day the window next
    // occurs.
    //
    // A window is a time of day, so it occurs today if it has not ended yet
    // and tomorrow if it has. The deadline is that occurrence's *end*, which
    // is exactly the moment the hunt would have been over had it been
    // hunting. It is deliberately not a fixed number of hours: a hunt started
    // at 16:00 for a 16:30 window must get its window today, and one started
    // at 22:00 must get tomorrow's.
    final deadline = _clock.isSynced
        ? _windowEndUtc(rule, now)
        : null;

    final slice = _waitSlice;

    while (!run.isCancelled) {
      // The clock, not the countdown, decides when the wait is over: the hunt
      // opens as soon as the portal says the window is open.
      final current = _clock.isSynced
          ? ClockTime(_clock.portalNow.hour, _clock.portalNow.minute)
          : now;
      final today = _clock.isSynced ? _clock.portalTodayUtc : null;

      if (rule.isOpenAt(current, today)) return _WindowWait.opened;

      if (deadline != null && !_clock.nowUtc.isBefore(deadline)) {
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.runEnded,
          message: 'بازه زمانی باز نشد؛ شکار متوقف شد.',
        );
        _finish(run, SnipeState.windowExpired, 'window never opened');
        await _listener.onEnded(
          ruleId: rule.id,
          state: SnipeState.windowExpired,
          reason: 'window never opened',
        );
        return _WindowWait.gaveUp;
      }

      await _sleep(slice);
    }

    return _WindowWait.cancelled;
  }

  /// The instant the hunt's window ends, on the day it next occurs.
  ///
  /// Null when the clock is not synced, because the answer is a date and a
  /// date cannot be guessed.
  ///
  /// ## When the rule carries a date
  ///
  /// A rule with a [SnipeRule.windowDate] is attached to a **collection
  /// date** — the day its meal is taken. The window ends on that date, and
  /// the deadline is that instant: a hunt waiting for tomorrow's window must
  /// not give up tonight, and a hunt whose collection day has passed must not
  /// wait forever for a day that will never come.
  ///
  /// Without a date the rule's window is a bare time of day, and the old
  /// behaviour applies: it ends today if it has not ended yet, tomorrow
  /// otherwise.
  DateTime? _windowEndUtc(SnipeRule rule, ClockTime now) {
    final today = _clock.portalTodayUtc;
    final endMinutes = rule.windowEnd.minutesSinceMidnight;
    final nowMinutes = now.minutesSinceMidnight;

    final windowDate = rule.windowDate;
    final day = windowDate ??
        (endMinutes <= nowMinutes
            ? today.add(const Duration(days: 1))
            : today);

    // The window is a *portal-local* wall-clock time, so the instant is that
    // time minus the portal's offset — the same arithmetic the reservation
    // cutoff uses.
    return DateTime.utc(
      day.year,
      day.month,
      day.day,
      rule.windowEnd.hour,
      rule.windowEnd.minute,
    ).subtract(ServerClock.portalUtcOffset);
  }

  /// One poll cycle. Returns false when the poll itself failed.
  ///
  /// Returns true when the poll succeeded, whether or not a match was found —
  /// "found nothing" is a healthy outcome, not a failure, and treating it as one
  /// would trip the circuit breaker on a quiet market.
  Future<bool> _pollOnce(_Run run, Session session, Balance? balance) async {
    final rule = run.rule;
    final hunt = run.hunt;
    final now = _now();

    // A hunt reads the basket for its *target date*: the buy page is
    // date-filtered, and the market's listings for another day are not what
    // the hunt is waiting for.
    final cursor = hunt?.targetDate == null ? null : _jalaliOf(hunt!.targetDate!);

    BasketPage page;
    try {
      page = await _client.fetchBasket(session, cursor: cursor);
    } on LoginRejectedException {
      // The portal expired the session mid-hunt. Re-authenticate and read
      // again: the bounced page carries no listings, so a hunt that treated it
      // as an empty market would keep polling against a dead session and
      // never see the listing it is waiting for.
      try {
        page = await _sessions.withSession(
          rule.account,
          (fresh) => _client.fetchBasket(fresh, cursor: cursor),
        );
        run.session = _sessions.sessionFor(rule.account);
      } catch (error) {
        run.bumpPoll(now, error: error.toString());
        run.ledger.record(
          at: now,
          kind: LedgerEventKind.polled,
          message: 'خطا در دریافت سبد: $error',
        );
        return false;
      }
    } catch (error) {
      run.bumpPoll(now, error: error.toString());
      run.ledger.record(
        at: now,
        kind: LedgerEventKind.polled,
        message: 'خطا در دریافت سبد: $error',
      );
      return false;
    }

    run.bumpPoll(now);

    // Filter tombstones before ranking: a dead listing must never reach the
    // ranker, or a match on it costs a claim attempt that reads as a retry.
    final live = run.tombstones.filter(rule.account, page.listings, now);
    final skipped = page.listings.length - live.length;

    run.ledger.record(
      at: now,
      kind: LedgerEventKind.polled,
      message: '${page.listings.length} آگهی بررسی شد'
          '${skipped > 0 ? "، $skipped مورد حذف‌شده" : ""}.',
    );

    // A hunt ranks with its own ranker, which matches on the dish name — the
    // market renumbers option ids, so an id-based match would never fire.
    if (hunt != null) {
      final result = _huntRanker.selectBest(
        config: hunt,
        listings: live,
        maxPriceRial: hunt.maxPriceRial,
      );

      for (final candidate in result.considered) {
        if (candidate.isEligible) continue;
        run.ledger.record(
          at: now,
          kind: LedgerEventKind.skipped,
          message: 'رد شد (${candidate.skipReason?.name}): '
              '${candidate.listing.option.name}',
          listingId: candidate.listing.id,
          simulated: rule.dryRun,
        );
      }

      final best = result.best;
      if (best == null) return true;

      _transition(run, SnipeState.matched);
      run.ledger.record(
        at: now,
        kind: LedgerEventKind.matched,
        message: 'آگهی مناسب پیدا شد: ${best.option.name}، ${best.hall.name}',
        listingId: best.id,
        simulated: rule.dryRun,
      );

      await _claim(run, session, best);
      return true;
    }

    // Restrict to the slots this rule covers.
    final candidates = live.where((l) => rule.slots.contains(l.slot));

    final best = _rankAcrossSlots(rule, candidates, run);
    if (best == null) return true;

    _transition(run, SnipeState.matched);
    run.ledger.record(
      at: now,
      kind: LedgerEventKind.matched,
      message: 'آگهی مناسب پیدا شد: ${best.option.name}',
      listingId: best.id,
      simulated: rule.dryRun,
    );

    await _claim(run, session, best);
    return true;
  }

  /// Ranks candidates, and records why each was skipped.
  Listing? _rankAcrossSlots(
    SnipeRule rule,
    Iterable<Listing> candidates,
    _Run run,
  ) {
    // Group by slot: a SlotPreference is per meal, so ranking across slots in one
    // pass would compare options that are not alternatives.
    final bySlot = <MealSlot, List<Listing>>{};
    for (final listing in candidates) {
      bySlot.putIfAbsent(listing.slot, () => []).add(listing);
    }

    Listing? best;
    for (final entry in bySlot.entries) {
      final preference = rule.preferences[entry.key];
      if (preference == null) continue;

      final result = _ranker.selectBest(
        preference: preference,
        listings: entry.value,
        maxPriceRial: rule.maxPriceRial,
      );

      for (final candidate in result.considered) {
        if (candidate.isEligible) continue;
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.skipped,
          message: 'رد شد (${candidate.rejection?.name}): '
              '${candidate.listing.option.name}',
          listingId: candidate.listing.id,
          simulated: rule.dryRun,
        );
      }

      final winner = result.best;
      if (winner == null) continue;
      if (best == null || winner.priceRial < best.priceRial) best = winner;
    }
    return best;
  }

  Future<void> _claim(_Run run, Session session, Listing listing) async {
    final rule = run.rule;
    final now = _now();

    // --- Dry run: record and stop, without ever calling the write path. ---
    if (rule.dryRun) {
      run.ledger.record(
        at: now,
        kind: LedgerEventKind.claimSucceeded,
        message: 'شبیه‌سازی: این آگهی خریداری می‌شد.',
        listingId: listing.id,
        simulated: true,
      );
      run.countPurchase(now);
      _finish(run, SnipeState.claimed, 'dry run match');
      await _listener.onEnded(
        ruleId: rule.id,
        state: SnipeState.claimed,
        reason: 'dry run match',
      );
      return;
    }

    _transition(run, SnipeState.claiming);
    run.ledger.record(
      at: now,
      kind: LedgerEventKind.claimAttempted,
      message: 'تلاش برای خرید ${listing.option.name}',
      listingId: listing.id,
    );

    final ClaimResult result;
    try {
      result = await _client.claim(session, listing.id);
    } catch (error) {
      // A thrown claim is ambiguous by definition: we do not know whether the
      // server processed it before the connection failed.
      await _handleAmbiguous(run, session, listing, error.toString());
      return;
    }

    switch (result) {
      case ClaimSucceeded(:final reservation):
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.claimSucceeded,
          message: 'خرید انجام شد: ${reservation.option.name}',
          listingId: listing.id,
        );
        run.setClaimed(listing.id);
        run.countPurchase(_now());
        _finish(run, SnipeState.claimed, 'claimed');
        // The purchase is final, so the hunt stops here. Continuing would
        // risk a second, unwanted meal — and a basket purchase cannot be
        // cancelled, so there is no undo for that.
        //
        // The notification is posted *after* the outcome is known, never when
        // the claim is sent: an ambiguous claim must not produce a success
        // notification, because it may not have been a purchase at all.
        await _listener.onClaimed(
          ruleId: rule.id,
          listing: listing,
          reservation: reservation,
        );

      case ClaimRejected(:final reason):
        run.tombstones.add(
          accountId: rule.account,
          listingId: listing.id,
          reason: TombstoneReason.claimRejected,
          now: _now(),
          listingExpiresAt: listing.expiresAt,
        );
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.claimLost,
          message: 'خرید انجام نشد: $reason',
          listingId: listing.id,
        );
        _transition(run, SnipeState.lost);
        _transition(run, SnipeState.hunting);

      case ClaimAmbiguous(:final diagnostic):
        await _handleAmbiguous(run, session, listing, diagnostic);
    }
  }

  /// Resolves an ambiguous claim by re-reading, then never retries it.
  Future<void> _handleAmbiguous(
    _Run run,
    Session session,
    Listing listing,
    String diagnostic,
  ) async {
    final rule = run.rule;

    run.ledger.record(
      at: _now(),
      kind: LedgerEventKind.claimAmbiguous,
      message: 'نتیجه خرید نامشخص بود، بررسی مجدد انجام می‌شود.',
      listingId: listing.id,
    );

    final outcome = await _reconciler.reconcile(
      client: _client,
      session: session,
      listing: listing,
    );

    // Whatever the outcome, this listing is never claimed again. If it did land,
    // retrying buys a second meal; if it did not, retrying is the dead-listing
    // poll pattern. Nothing good comes from a second attempt.
    run.tombstones.add(
      accountId: rule.account,
      listingId: listing.id,
      reason: TombstoneReason.lostRace,
      now: _now(),
      listingExpiresAt: listing.expiresAt,
    );

    switch (outcome) {
      case ReconciliationOutcome.claimed:
        // The purchase did happen — the claim landed and only our knowledge was
        // late. Record it as a purchase, not just a reconciliation note, or the
        // ledger understates what the user was charged.
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.claimSucceeded,
          message: 'بررسی مجدد نشان داد خرید انجام شده است.',
          listingId: listing.id,
        );
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.reconciled,
          message: 'نتیجه نامشخص بود و با بررسی مجدد تأیید شد.',
          listingId: listing.id,
        );
        run.setClaimed(listing.id);
        run.countPurchase(_now());
        _finish(run, SnipeState.claimed, 'reconciled as claimed');
        await _listener.onClaimed(
          ruleId: rule.id,
          listing: listing,
          reservation: Reservation(
            id: 'reconciled-${listing.id}',
            date: listing.date,
            slot: listing.slot,
            hall: listing.hall,
            option: listing.option,
            state: ReservationState.active,
          ),
        );

      case ReconciliationOutcome.notClaimed:
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.reconciled,
          message: 'بررسی مجدد نشان داد خرید انجام نشده است.',
          listingId: listing.id,
        );
        _transition(run, SnipeState.lost);
        _transition(run, SnipeState.hunting);

      case ReconciliationOutcome.indeterminate:
        // Still unknown. Treat as lost and move on: continuing to hunt risks
        // more than it gains, and the tombstone prevents the dangerous retry.
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.reconciled,
          message: 'بررسی مجدد قطعی نبود؛ این آگهی دیگر تلاش نمی‌شود.',
          listingId: listing.id,
        );
        _transition(run, SnipeState.lost);
        _transition(run, SnipeState.hunting);
    }
  }

  /// A civil date as the portal's `yyyy/MM/dd` Jalali string.
  ///
  /// The buy page's date filter takes the portal's own Jalali form, and the
  /// engine must not invent one: a date the page does not recognise silently
  /// returns the wrong rows, which would be read as "no listings" and would
  /// look like a quiet market.
  static String _jalaliOf(DateTime date) {
    final jalali = toJalali(date);
    return '${jalali.year}/${jalali.month.toString().padLeft(2, '0')}/'
        '${jalali.day.toString().padLeft(2, '0')}';
  }

  DateTime _now() => _clock.isSynced ? _clock.nowUtc : DateTime.now().toUtc();

  void _transition(_Run run, SnipeState next) {
    // A cancelled run keeps whatever state it reached; transitions after
    // cancellation are meaningless rather than errors.
    if (run.isCancelled && !SnipeStateMachine.isTerminal(next)) return;
    run.status = run.status.withState(next);
    run.emit();
  }

  void _finish(_Run run, SnipeState state, String reason) {
    run.status = run.status.withState(state, stopReason: reason);
    run.emit();
  }
}

/// The reads a pre-flight needs.
class _PreflightInputs {
  const _PreflightInputs({
    required this.session,
    this.balance,
    this.holdings,
  });

  final SessionResult session;

  /// Null when the balance could not be read.
  final Balance? balance;

  /// Null when the holdings could not be read.
  final List<Reservation>? holdings;
}

/// How a wait for the hunt's window ended.
enum _WindowWait {
  /// The window opened, and the hunt may poll.
  opened,

  /// The run was cancelled while waiting.
  cancelled,

  /// The window never opened, and the run gave up.
  gaveUp,
}

/// Mutable state for one running rule.
class _Run {
  _Run({required this.rule, required this.status, this.hunt})
      : ledger = SnipeLedger(rule.id);

  final SnipeRule rule;

  /// The hunt configuration, when this run is a hunt.
  ///
  /// Replaced once at the start of the run, with the priority list rebuilt
  /// from the live offering — the prices the setup screen quoted belong to
  /// the date and slot it was filled for, and a hunt may start for a
  /// different one.
  HuntConfig? hunt;

  final SnipeLedger ledger;
  final TombstoneSet tombstones = TombstoneSet();
  final StreamController<SnipeRunStatus> controller =
      StreamController<SnipeRunStatus>.broadcast();

  SnipeRunStatus status;
  Future<void> future = Future<void>.value();
  bool _cancelled = false;

  /// Completes when the run is cancelled.
  ///
  /// A hunt can wait hours for its window to open, and a wait that ignored
  /// cancellation would make "stop" block for the whole wait — the user would
  /// tap stop and the app would keep the hunt alive until evening.
  final Completer<void> _cancelledSignal = Completer<void>();

  /// The session the run is polling with.
  ///
  /// Held on the run rather than passed down, because a hunt outlives the
  /// session it started with: the portal expires it, and the run has to be
  /// able to pick up a fresh one without being restarted.
  Session? session;

  /// Whether the run has ever polled inside its window.
  ///
  /// This is what separates a window that has *not opened yet* from one that
  /// has *closed*. Before the first poll inside the window, being outside it
  /// means "wait"; after it, being outside it means the hunt is over. Without
  /// this the run would either end before it ever started, or wait forever
  /// after its window had already passed.
  bool hasHunted = false;

  bool get isCancelled => _cancelled;

  /// Completes when the run is cancelled.
  Future<void> get cancelled => _cancelledSignal.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_cancelledSignal.isCompleted) _cancelledSignal.complete();
  }

  void emit() {
    if (!controller.isClosed) controller.add(status);
  }

  void bumpPoll(DateTime at, {String? error}) {
    status = status.withPoll(at, error: error);
    emit();
  }

  void setClaimed(ListingId listingId) {
    status = status.withClaimed(listingId);
    emit();
  }

  void countPurchase(DateTime at) {
    status = status.withPurchase(at);
    emit();
  }
}
