/// The snipe rule and its state machine.
///
/// The state machine exists to make illegal transitions impossible to express
/// by accident, and to make the terminal states genuinely terminal. The three
/// failure modes it guards are the ones that will definitely happen in
/// production: losing a race, an ambiguous claim, and a session dying mid-hunt.
library;

import 'models.dart';
import 'priority.dart';
import 'time.dart';

/// Where a rule can be in its lifecycle.
enum SnipeState {
  /// Not started, or finished and reset.
  idle,

  /// Verifying clock, session, and funds before the window opens.
  preflight,

  /// Window is open; polling for inventory.
  hunting,

  /// A listing matched the preferences and was selected.
  matched,

  /// A claim request is in flight. Only one per account at a time.
  claiming,

  /// The claim succeeded.
  claimed,

  /// Someone else took it, or the portal rejected the claim.
  lost,

  /// Preconditions were not met (unsynced clock, dead session, no funds).
  aborted,

  /// The window closed without a purchase.
  windowExpired,
}

/// Static facts about the state machine, kept separate from any instance so
/// tests and UI can reason about it without constructing anything.
abstract final class SnipeStateMachine {
  /// States from which no further transition occurs.
  static const Set<SnipeState> terminal = {
    SnipeState.claimed,
    SnipeState.aborted,
    SnipeState.windowExpired,
  };

  /// The legal transition table. Any pair absent here is a programming error.
  static const Map<SnipeState, Set<SnipeState>> allowed = {
    SnipeState.idle: {SnipeState.preflight},
    SnipeState.preflight: {
      SnipeState.hunting,
      SnipeState.aborted,
    },
    SnipeState.hunting: {
      SnipeState.matched,
      SnipeState.windowExpired,
      SnipeState.aborted,
    },
    SnipeState.matched: {
      SnipeState.claiming,
      // A match can evaporate before we claim it.
      SnipeState.lost,
      SnipeState.windowExpired,
    },
    SnipeState.claiming: {
      SnipeState.claimed,
      // Ambiguous or rejected: the engine reconciles, then either the listing is
      // gone (lost) or the hunt continues.
      SnipeState.lost,
      SnipeState.hunting,
      SnipeState.aborted,
    },
    SnipeState.lost: {
      // Back to hunting only if the window is still open.
      SnipeState.hunting,
      SnipeState.windowExpired,
    },
    SnipeState.claimed: {},
    SnipeState.aborted: {},
    SnipeState.windowExpired: {},
  };

  static bool canTransition(SnipeState from, SnipeState to) =>
      allowed[from]?.contains(to) ?? false;

  static bool isTerminal(SnipeState state) => terminal.contains(state);
}

/// Thrown when a caller attempts an illegal transition. Surfacing this as an
/// error rather than silently ignoring it means state-machine bugs are loud.
class IllegalTransitionError extends Error {
  IllegalTransitionError(this.from, this.to);

  final SnipeState from;
  final SnipeState to;

  @override
  String toString() =>
      'IllegalTransitionError: $from -> $to is not a legal transition';
}

/// Mutable state holder for one running rule.
///
/// Deliberately small: it guards transitions and nothing else. Polling cadence
/// lives in PollingPolicy; selection lives in PriorityRanker.
class SnipeRun {
  SnipeRun(this.ruleId) : state = SnipeState.idle;

  final String ruleId;
  SnipeState state;

  /// Transitions to [next], or throws if the move is illegal.
  void transitionTo(SnipeState next) {
    if (!SnipeStateMachine.canTransition(state, next)) {
      throw IllegalTransitionError(state, next);
    }
    state = next;
  }

  bool get isTerminal => SnipeStateMachine.isTerminal(state);
}

/// Which date a rule targets.
enum DateTarget {
  /// The current day, in the portal's timezone.
  today,

  /// The first date beyond the cutoff wall.
  firstAvailableAfterCutoff,

  /// An explicit civil date chosen by the user.
  explicit,
}

/// How to act when a listing matches.
enum MatchAction {
  /// Buy immediately.
  autoBuy,

  /// Notify and wait for the user to confirm.
  notifyOnly,
}

/// A user's standing instruction to watch the basket and buy.
class SnipeRule {
  const SnipeRule({
    required this.id,
    required this.account,
    required this.preferences,
    this.enabled = true,
    this.windowStart = const ClockTime(0, 0),
    this.windowEnd = const ClockTime(23, 59),
    this.slots = const {MealSlot.breakfast, MealSlot.lunch, MealSlot.dinner},
    this.target = DateTarget.today,
    this.explicitDate,
    this.windowStartDate,
    this.windowDate,
    this.maxPriceRial,
    this.dryRun = false,
    this.maxPurchasesPerWindow = 1,
    this.action = MatchAction.autoBuy,
  })  : assert(
          target != DateTarget.explicit || explicitDate != null,
          'target == explicit requires explicitDate',
        ),
        assert(
          maxPurchasesPerWindow > 0,
          'maxPurchasesPerWindow must be positive',
        );

  final String id;
  final AccountId account;
  final bool enabled;

  /// Window of the day during which polling is allowed, in *portal-local* time.
  ///
  /// Portal-local, not device-local: a user travelling abroad would otherwise
  /// set 11:00–14:00, get device-local behaviour, and silently miss every window.
  final ClockTime windowStart;
  final ClockTime windowEnd;

  /// Which meals this rule may buy.
  final Set<MealSlot> slots;

  final DateTarget target;
  final DateTime? explicitDate;

  /// The civil date the window starts, in the portal's frame.
  ///
  /// For single-day rules, this matches [windowDate]. For overnight or
  /// multi-day operations, this can be earlier than [windowDate].
  final DateTime? windowStartDate;

  /// The civil date the window belongs to (and closes on), in the portal's frame.
  ///
  /// Null means the window is a **time of day** with no date attached, and
  /// the rule applies to whichever day it is read on. That is the right
  /// behaviour for a plain rule, and the wrong behaviour for a hunt: a hunt
  /// for tomorrow's dinner must not open today's window.
  ///
  /// A hunt sets this to its **collection date** — the day the meal is taken,
  /// which for a breakfast is the day *before* the target date, because
  /// breakfast is collected with the previous evening's dinner. See
  /// [HuntSchedules].
  ///
  /// With a date attached, the window is only open on that date range, so a hunt
  /// that wakes on the wrong day waits instead of hunting. Without it, the
  /// rule keeps the old behaviour of applying the window to any day.
  final DateTime? windowDate;

  /// Preferences per meal slot.
  final Map<MealSlot, SlotPreference> preferences;

  /// Hard price ceiling in Rial. A safety valve: without it a single mispriced
  /// listing can drain the balance.
  final int? maxPriceRial;

  /// Simulate without purchasing. Lets the user validate their ranking against
  /// live data before letting it spend money.
  final bool dryRun;

  /// Stop after this many purchases in one window, bounding the blast radius of
  /// any priority bug that survives review.
  final int maxPurchasesPerWindow;

  final MatchAction action;

  /// True when [now] (portal-local minutes since midnight) falls in the window.
  bool isWithinWindow(ClockTime now) {
    // A window never wraps past midnight; if the user sets end <= start the rule
    // is inert rather than silently spanning a full day.
    if (windowEnd <= windowStart) return false;
    return now >= windowStart && now <= windowEnd;
  }

  /// True when the window is open at [now] on the portal's date [portalDate].
  ///
  /// When dates are attached ([windowStartDate] or [windowDate]), the window
  /// spans from [windowStart] on [windowStartDate] (or [windowDate]) to
  /// [windowEnd] on [windowDate]. This supports both single-day windows and
  /// cross-day/overnight operations (e.g. today 18:20 to tomorrow 14:00).
  ///
  /// A rule with no date keeps the time-of-day behaviour, so a plain
  /// rule — which has no collection date — is unaffected.
  ///
  /// A null [portalDate] means the date is unknown, and the check falls back to
  /// the time of day: the caller cannot know better, and refusing the window
  /// outright would end every hunt whose clock had not synced.
  bool isOpenAt(ClockTime now, DateTime? portalDate) {
    final startDay = windowStartDate;
    final endDay = windowDate;

    if (startDay != null || endDay != null) {
      if (portalDate == null) {
        return isWithinWindow(now);
      }
      final effectiveStartDay = startDay ?? endDay!;
      final effectiveEndDay = endDay ?? startDay!;

      final startInstant = DateTime.utc(
        effectiveStartDay.year,
        effectiveStartDay.month,
        effectiveStartDay.day,
        windowStart.hour,
        windowStart.minute,
      );
      final endInstant = DateTime.utc(
        effectiveEndDay.year,
        effectiveEndDay.month,
        effectiveEndDay.day,
        windowEnd.hour,
        windowEnd.minute,
      );
      final currentInstant = DateTime.utc(
        portalDate.year,
        portalDate.month,
        portalDate.day,
        now.hour,
        now.minute,
      );
      return !currentInstant.isBefore(startInstant) &&
          !currentInstant.isAfter(endInstant);
    }

    return isWithinWindow(now);
  }

  /// Resolve the target date for this rule.
  DateTime? resolveTargetDate(ServerClock clock) {
    switch (target) {
      case DateTarget.today:
        return clock.portalTodayUtc;
      case DateTarget.firstAvailableAfterCutoff:
        return clock.firstReservableDate();
      case DateTarget.explicit:
        final d = explicitDate!;
        return DateTime.utc(d.year, d.month, d.day);
    }
  }
}

/// Live status of a running rule, for the UI and the log.
class SnipeRunStatus {
  const SnipeRunStatus({
    required this.ruleId,
    required this.state,
    this.pollCount = 0,
    this.lastPollAt,
    this.lastError,
    this.claimedListingId,
    this.purchasesThisWindow = 0,
    this.stopReason,
  });

  final String ruleId;
  final SnipeState state;
  final int pollCount;
  final DateTime? lastPollAt;
  final String? lastError;
  final ListingId? claimedListingId;
  final int purchasesThisWindow;

  /// Why the run ended, when it has.
  final String? stopReason;

  bool get isTerminal => SnipeStateMachine.isTerminal(state);

  SnipeRunStatus withState(SnipeState nextState, {String? stopReason}) =>
      SnipeRunStatus(
        ruleId: ruleId,
        state: nextState,
        pollCount: pollCount,
        lastPollAt: lastPollAt,
        lastError: lastError,
        claimedListingId: claimedListingId,
        purchasesThisWindow: purchasesThisWindow,
        stopReason: stopReason ?? this.stopReason,
      );

  SnipeRunStatus withPoll(DateTime at, {String? error}) => SnipeRunStatus(
        ruleId: ruleId,
        state: state,
        pollCount: pollCount + 1,
        lastPollAt: at,
        lastError: error,
        claimedListingId: claimedListingId,
        purchasesThisWindow: purchasesThisWindow,
        stopReason: stopReason,
      );

  SnipeRunStatus withClaimed(ListingId id) => SnipeRunStatus(
        ruleId: ruleId,
        state: state,
        pollCount: pollCount,
        lastPollAt: lastPollAt,
        lastError: lastError,
        claimedListingId: id,
        purchasesThisWindow: purchasesThisWindow,
        stopReason: stopReason,
      );

  SnipeRunStatus withPurchase(DateTime at) => SnipeRunStatus(
        ruleId: ruleId,
        state: state,
        pollCount: pollCount,
        lastPollAt: at,
        lastError: lastError,
        claimedListingId: claimedListingId,
        purchasesThisWindow: purchasesThisWindow + 1,
        stopReason: stopReason,
      );
}