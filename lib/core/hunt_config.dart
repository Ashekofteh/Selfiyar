/// The hunt's configuration: when to hunt, what to buy, and how hard to push.
///
/// ## The bounds are hard, not advisory
///
/// The user's interval preference is **clamped**, never honoured outside the
/// bounds in [HuntBounds]. The UI cannot represent a value beyond them, and
/// the model clamps again on the way in, so the guard does not depend on the UI
/// being correct. A hunt spends real money and spends the account's goodwill
/// with the portal; the app must not be configurable into behaviour that reads
/// as an attack.
///
/// ## The rate is a function of the time, not a constant
///
/// The portal publishes when each meal is distributed (see [distributionWindows]),
/// and a lunch hunt is not competitive at 19:00. So the hunt carries two
/// intervals and picks between them using the **server clock** — a device
/// clock an hour off would otherwise poll hard at the wrong time, or sleep
/// through the peak entirely.
///
/// ## The cost is shown, not implied
///
/// A faster interval is simultaneously a bigger competitive edge and a bigger
/// ban risk, and the two are the same knob. So the configuration can project
/// the request count for the window: a number the user is actually trading
/// against is information; a label saying "fast" is not.
library;

import 'dart:math' as math;

import 'models.dart';
import 'priority.dart';
import 'hunt_schedule.dart';
import 'snipe.dart';
import 'time.dart';

/// The portal's published distribution window for a meal.
///
/// Read from `ForgotReceipt.aspx` ("زمان دریافت فیش فراموشی").
class DistributionWindow {
  const DistributionWindow(this.start, this.end);

  /// When the meal becomes collectable, portal-local.
  final ClockTime start;

  /// When the collection window closes, portal-local.
  final ClockTime end;

  /// Whether [now] falls inside the window.
  ///
  /// Inclusive at both ends: the window opens *at* [start] and closes *at*
  /// [end], and the closing minute is still inside it.
  bool contains(ClockTime now) => now >= start && now <= end;

  /// The window's length.
  Duration get duration => Duration(
        minutes: end.minutesSinceMidnight - start.minutesSinceMidnight,
      );

  @override
  String toString() => 'DistributionWindow($start..$end)';
}

/// The portal's own distribution windows, per meal.
///
/// Breakfast and dinner share the evening window — they are collected
/// together — so a hunt for either is hot at the same hours.
const Map<MealSlot, DistributionWindow> distributionWindows = {
  MealSlot.breakfast: DistributionWindow(ClockTime(16, 30), ClockTime(20, 30)),
  MealSlot.lunch: DistributionWindow(ClockTime(9, 0), ClockTime(15, 30)),
  MealSlot.dinner: DistributionWindow(ClockTime(16, 30), ClockTime(20, 30)),
};

/// The safety bounds on a hunt's polling rate.
///
/// Every one of these is a **clamp**, not a validation error: a request for
/// an out-of-bounds value is honoured at the bound, so a bad value can never
/// stop the user hunting, and can never make the app hunt more aggressively
/// than the bounds allow.
abstract final class HuntBounds {
  /// The fastest the hunt may poll, even in peak.
  ///
  /// The product owner's floor. Aggressive, but chosen deliberately, and it is
  /// still two orders of magnitude below "hammering".
  static const Duration minPeakInterval = Duration(seconds: 2);

  /// The slowest a peak poll may be. Beyond this the hunt is not hunting.
  static const Duration maxPeakInterval = Duration(seconds: 60);

  /// Below this interval the risk of a rate-limit or ban is material enough
  /// that the user must explicitly acknowledge it.
  static const Duration riskAcknowledgementThreshold = Duration(seconds: 10);

  /// The fastest an off-peak poll may be.
  ///
  /// Off-peak still has to catch a listing within a reasonable time. Without
  /// this floor the user could set off-peak as fast as peak, which would
  /// defeat the point of having two rates and leave the request budget as the
  /// only thing stopping the app.
  static const Duration minOffPeakInterval = Duration(seconds: 30);

  /// The slowest an off-peak poll may be. The product owner's baseline.
  static const Duration maxOffPeakInterval = Duration(minutes: 15);

  /// The hard cap on requests in one window, per account.
  ///
  /// The budget, not the interval, is the ultimate backstop: even a hunt
  /// configured at the fastest possible rate cannot exceed it.
  static const int defaultRequestBudget = 400;

  /// Clamps a peak interval to the permitted range.
  static Duration clampPeak(Duration interval) {
    if (interval < minPeakInterval) return minPeakInterval;
    if (interval > maxPeakInterval) return maxPeakInterval;
    return interval;
  }

  /// Clamps an off-peak interval to the permitted range.
  static Duration clampOffPeak(Duration interval) {
    if (interval < minOffPeakInterval) return minOffPeakInterval;
    if (interval > maxOffPeakInterval) return maxOffPeakInterval;
    return interval;
  }

  /// Whether an interval at this rate needs an explicit risk acknowledgement.
  static bool needsRiskAcknowledgement(Duration interval) =>
      interval < riskAcknowledgementThreshold;
}

/// How hard the hunt may push.
///
/// Both intervals are **clamped on construction**, so an out-of-range value can
/// never be represented, let alone acted on. The clamp is silent by design: a
/// user who drags a slider past the floor gets the floor, not an error dialog
/// telling them off for something the UI should not have offered.
class HuntRate {
  HuntRate({
    Duration peakInterval = defaultPeakInterval,
    Duration offPeakInterval = defaultOffPeakInterval,
  })  : peakInterval = HuntBounds.clampPeak(peakInterval),
        offPeakInterval = HuntBounds.clampOffPeak(offPeakInterval);

  /// The fastest interval considered safe without an explicit risk
  /// acknowledgement.
  static const Duration defaultPeakInterval = Duration(seconds: 10);

  /// A quiet off-peak baseline: about 80 requests over a 20-hour day.
  static const Duration defaultOffPeakInterval = Duration(minutes: 15);

  /// The default rate.
  static final HuntRate defaults = HuntRate();

  /// The interval during the target meal's distribution window.
  final Duration peakInterval;

  /// The interval outside it, but still inside the hunt window.
  final Duration offPeakInterval;

  /// Whether this rate needs the user to acknowledge the ban risk.
  bool get needsRiskAcknowledgement =>
      HuntBounds.needsRiskAcknowledgement(peakInterval);

  /// A copy with the given intervals, clamped.
  HuntRate copyWith({
    Duration? peakInterval,
    Duration? offPeakInterval,
  }) =>
      HuntRate(
        peakInterval: peakInterval ?? this.peakInterval,
        offPeakInterval: offPeakInterval ?? this.offPeakInterval,
      );

  @override
  String toString() =>
      'HuntRate(peak=${peakInterval.inSeconds}s, offPeak=${offPeakInterval.inSeconds}s)';
}

/// One dish the hunt may buy.
///
/// **The dish is identified by its name, not by an option id.** The market
/// renumbers ids — the same dish on the same date is `62737` in the weekly
/// grid and `62798` on the buy page — so an id picked from the official menu
/// can never identify the market listing of that dish, and a hunt keyed on
/// ids would never fire. See [normalizeDishName].
class HuntDish {
  HuntDish({
    required this.optionId,
    required this.name,
    required this.priceRial,
  }) : dishKey = normalizeDishName(name);

  /// The portal's option id, as seen on the page the dish was picked from.
  ///
  /// **Not the identity.** It is retained so the UI can point back at the
  /// offering, and so a listing that happens to carry the same id can be
  /// preferred — but a match never *requires* it.
  final OptionId optionId;

  /// The dish's name, as the portal renders it.
  final String name;

  /// The normalised name the hunt matches listings on.
  final String dishKey;

  /// The price **for the target date and slot**, as the portal quoted it.
  ///
  /// Not a property of the dish: the same option id costs 2,150,000 as a
  /// breakfast and 500,000 as a lunch (verified). The ceiling is therefore
  /// always checked against the live offering for the target date, never a
  /// remembered price and never another date's price.
  final int priceRial;

  @override
  String toString() => 'HuntDish($optionId, $name, $priceRial Rial)';
}

/// A dining hall, as the portal named it for this account.
class HuntHall {
  const HuntHall({required this.id, required this.name});

  /// The portal's hall id. **The identity.**
  ///
  /// Never the name. The portal serves different hall names depending on the
  /// account — a female account may see «مرکزی خواهران» where a male one sees
  /// «مرکزی برادران» — and a string matcher for a Persian hall name is a bug
  /// waiting to happen. The name is display; the id is identity.
  final HallId id;

  /// The name the portal supplied. **Display only.**
  final String name;

  @override
  String toString() => 'HuntHall($id, $name)';
}

/// The menu for one meal slot, in the terms the hunt screen offers them.
///
/// ## Why this is a domain type
///
/// The hunt screen shows two lists — the dishes and the halls — and both come
/// from the same official menu. Turning a menu into those two lists is a
/// decision with a rule behind it, so it belongs in the domain where it can
/// be tested without a widget: a hall that is not served is not offered, and
/// a dish is offered with the price the menu quoted for *that* (date, slot).
class MenuChoice {
  const MenuChoice({
    required this.dishes,
    required this.halls,
  });

  /// The dishes on offer, in the portal's own order, with their prices.
  final List<HuntDish> dishes;

  /// The halls that serve this meal, in the portal's own order.
  final List<HuntHall> halls;

  /// The choice for [slot] within [menus], or null when the portal does not
  /// serve that meal on that date.
  ///
  /// Null is a real answer, and not the same as an empty one: an empty
  /// choice means "the portal serves this meal and offers nothing on it",
  /// while null means "there is no such meal". A hunt for a meal the portal
  /// does not serve can buy nothing, and the screen must say so.
  static MenuChoice? from(List<MealMenu> menus, MealSlot slot) {
    for (final menu in menus) {
      if (menu.slot != slot) continue;
      return MenuChoice(
        dishes: [
          for (final dish in menu.dishes)
            HuntDish(
              optionId: dish.id,
              name: dish.name,
              priceRial: dish.priceRial,
            ),
        ],
        halls: [
          for (final hall in menu.halls) HuntHall(id: hall.id, name: hall.name),
        ],
      );
    }
    return null;
  }
}

/// The hunt's configuration for one rule.
class HuntConfig {
  HuntConfig({
    this.windowStart = const ClockTime(16, 30),
    this.windowEnd = const ClockTime(20, 30),
    this.targetSlot = MealSlot.dinner,
    this.targetDate,
    this.startDate,
    this.dishPriority = const [],
    this.hallPriority = const [],
    HuntRate? rate,
    this.enabled = false,
    int? requestBudget,
    this.riskAcknowledged = false,
  })  : rate = rate ?? HuntRate.defaults,
        requestBudget = requestBudget ??
            computeBudget(
              windowStart: windowStart,
              windowEnd: windowEnd,
              targetSlot: targetSlot,
              rate: rate ?? HuntRate.defaults,
              targetDate: targetDate,
              startDate: startDate,
            ),
        assert((requestBudget ?? 400) > 0, 'requestBudget must be positive');

  /// Computes a safe, dynamic request budget for the specified window, rate and slot.
  ///
  /// Guarantees that the hunt will not exhaust its budget prematurely before the
  /// window duration elapses (accounting for 130% projected volume with a minimum
  /// floor of [HuntBounds.defaultRequestBudget]).
  static int computeBudget({
    required ClockTime windowStart,
    required ClockTime windowEnd,
    required MealSlot targetSlot,
    required HuntRate rate,
    DateTime? targetDate,
    DateTime? startDate,
  }) {
    final collection = HuntSchedules.collectionDate(
      targetDate: targetDate,
      slot: targetSlot,
    );
    final DateTime? startDay;
    if (startDate != null) {
      startDay = DateTime.utc(startDate.year, startDate.month, startDate.day);
    } else if (collection != null && windowEnd <= windowStart) {
      startDay = DateTime.utc(collection.year, collection.month, collection.day - 1);
    } else {
      startDay = collection;
    }

    final int windowSecs;
    if (startDay != null && collection != null) {
      final startInstant = DateTime.utc(
        startDay.year,
        startDay.month,
        startDay.day,
        windowStart.hour,
        windowStart.minute,
      );
      final endInstant = DateTime.utc(
        collection.year,
        collection.month,
        collection.day,
        windowEnd.hour,
        windowEnd.minute,
      );
      final diff = endInstant.difference(startInstant).inSeconds;
      windowSecs = diff > 0 ? diff : 0;
    } else if (windowEnd <= windowStart) {
      windowSecs = 0;
    } else {
      windowSecs = (windowEnd.minutesSinceMidnight - windowStart.minutesSinceMidnight) * 60;
    }

    final peak = distributionWindows[targetSlot]!;
    final peakStart = peak.start.minutesSinceMidnight;
    final peakEnd = peak.end.minutesSinceMidnight;

    final int peakSecs;
    if (startDay != null && collection != null) {
      final isSameDay = startDay.year == collection.year &&
          startDay.month == collection.month &&
          startDay.day == collection.day;
      final huntStartOnCollectionDay = isSameDay ? windowStart.minutesSinceMidnight : 0;
      final huntEndOnCollectionDay = windowEnd.minutesSinceMidnight;
      final start = huntStartOnCollectionDay > peakStart ? huntStartOnCollectionDay : peakStart;
      final end = huntEndOnCollectionDay < peakEnd ? huntEndOnCollectionDay : peakEnd;
      peakSecs = end > start ? (end - start) * 60 : 0;
    } else if (windowEnd <= windowStart) {
      peakSecs = 0;
    } else {
      final huntStart = windowStart.minutesSinceMidnight;
      final huntEnd = windowEnd.minutesSinceMidnight;
      final start = huntStart > peakStart ? huntStart : peakStart;
      final end = huntEnd < peakEnd ? huntEnd : peakEnd;
      peakSecs = end > start ? (end - start) * 60 : 0;
    }

    final offPeakSecs = windowSecs - peakSecs;
    final peakInterval = rate.peakInterval.inSeconds;
    final offPeakInterval = rate.offPeakInterval.inSeconds;

    final requests = (peakInterval > 0 ? peakSecs / peakInterval : 0) +
        (offPeakInterval > 0 ? offPeakSecs / offPeakInterval : 0);
    final projected = requests.ceil();
    final withMargin = (projected * 1.3).ceil();
    return math.max(withMargin, HuntBounds.defaultRequestBudget);
  }

  /// When the hunt is allowed to run at all, portal-local.
  final ClockTime windowStart;

  /// When the hunt stops running, portal-local.
  final ClockTime windowEnd;

  /// The meal this rule hunts for, which decides the peak window.
  final MealSlot targetSlot;

  /// The date the hunt targets, in the portal's civil frame.
  ///
  /// Null means "the first date the portal will serve", resolved at setup.
  final DateTime? targetDate;

  /// The civil date the hunt operation begins, in the portal's civil frame.
  ///
  /// When null, defaults to [collectionDate].
  final DateTime? startDate;

  /// The collection date for the target meal.
  DateTime? get collectionDate => HuntSchedules.collectionDate(
        targetDate: targetDate,
        slot: targetSlot,
      );

  /// The effective start date for the hunt operation.
  DateTime? get effectiveStartDate {
    if (startDate != null) {
      return DateTime.utc(startDate!.year, startDate!.month, startDate!.day);
    }
    final collection = collectionDate;
    if (collection != null && windowEnd <= windowStart) {
      return DateTime.utc(collection.year, collection.month, collection.day - 1);
    }
    return collection;
  }

  /// The dishes to buy, in priority order.
  ///
  /// A one-element list means "only this dish". A two-element list means
  /// "either will do, this one first".
  final List<HuntDish> dishPriority;

  /// The halls to buy from, in priority order.
  ///
  /// An empty list means "any hall the portal offers this dish in". A
  /// one-element list means only that hall. A two-element list means either,
  /// this one first.
  final List<HuntHall> hallPriority;

  final HuntRate rate;

  /// Off by default: a hunt spends money and makes requests.
  final bool enabled;

  /// Hard cap on requests in one window, per account.
  final int requestBudget;

  /// Whether the user has accepted the ban risk of a sub-10-second rate.
  ///
  /// Remembered so the warning is not shown on every launch, but the warning
  /// is shown again whenever the user *raises* the rate past the threshold.
  final bool riskAcknowledged;

  /// The distribution window of the target meal.
  DistributionWindow get peakWindow => distributionWindows[targetSlot]!;

  /// Whether [now] (portal-local) falls inside the hunt's own window.
  ///
  /// When [portalDate] is provided, checks against the full datetime span
  /// from [effectiveStartDate] at [windowStart] to [collectionDate] at [windowEnd].
  bool isWithinWindow(ClockTime now, {DateTime? portalDate}) {
    final startDay = effectiveStartDate;
    final endDay = collectionDate;

    if (portalDate != null && startDay != null && endDay != null) {
      final startInstant = DateTime.utc(
        startDay.year,
        startDay.month,
        startDay.day,
        windowStart.hour,
        windowStart.minute,
      );
      final endInstant = DateTime.utc(
        endDay.year,
        endDay.month,
        endDay.day,
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

    // A window never wraps past midnight on a bare time-of-day check;
    // if the user sets end <= start the hunt is inert rather than silently spanning a full day.
    if (windowEnd <= windowStart) return false;
    return now >= windowStart && now <= windowEnd;
  }

  /// Whether [now] is inside the target meal's distribution window.
  ///
  /// When [portalDate] is provided, peak only occurs on the meal's [collectionDate].
  bool isPeak(ClockTime now, {DateTime? portalDate}) {
    if (portalDate != null && targetDate != null) {
      final collection = collectionDate;
      if (collection != null &&
          (portalDate.year != collection.year ||
              portalDate.month != collection.month ||
              portalDate.day != collection.day)) {
        return false;
      }
    }
    return peakWindow.contains(now);
  }

  /// The interval to use at [now].
  ///
  /// Peak inside the target meal's distribution window, off-peak outside it.
  /// The caller is responsible for not polling at all outside the hunt's own
  /// window — this only answers "how hard", not "whether".
  Duration intervalAt(ClockTime now, {DateTime? portalDate}) =>
      isPeak(now, portalDate: portalDate)
          ? rate.peakInterval
          : rate.offPeakInterval;

  /// The credit the priority list needs.
  ///
  /// The **maximum** price among dishes in the priority list, not the sum.
  /// The hunt books at most one meal for the slot, and dishes in the list
  /// represent user preferences in priority order. Therefore, having enough
  /// credit to afford the dearest dish is sufficient.
  int get requiredCreditRial {
    if (dishPriority.isEmpty) return 0;
    return dishPriority.map((d) => d.priceRial).fold(0, math.max);
  }

  /// The hunt window's length, in seconds.
  int get windowSeconds {
    final startDay = effectiveStartDate;
    final endDay = collectionDate;
    if (startDay != null && endDay != null) {
      final startInstant = DateTime.utc(
        startDay.year,
        startDay.month,
        startDay.day,
        windowStart.hour,
        windowStart.minute,
      );
      final endInstant = DateTime.utc(
        endDay.year,
        endDay.month,
        endDay.day,
        windowEnd.hour,
        windowEnd.minute,
      );
      final diff = endInstant.difference(startInstant).inSeconds;
      return diff > 0 ? diff : 0;
    }

    if (windowEnd <= windowStart) return 0;
    return (windowEnd.minutesSinceMidnight - windowStart.minutesSinceMidnight) * 60;
  }

  /// The overlap between the hunt window and the target meal's distribution
  /// window, in seconds.
  ///
  /// **Zero when the two do not overlap.** A lunch hunt running in the
  /// evening window never sees peak, so it polls entirely off-peak — and
  /// projecting it as if it were peak would overstate the request count and
  /// hide the fact that the user has set the hunt up wrong.
  int get peakOverlapSeconds {
    final peak = peakWindow;
    final peakStart = peak.start.minutesSinceMidnight;
    final peakEnd = peak.end.minutesSinceMidnight;

    final startDay = effectiveStartDate;
    final endDay = collectionDate;

    if (startDay != null && endDay != null) {
      final isSameDay = startDay.year == endDay.year &&
          startDay.month == endDay.month &&
          startDay.day == endDay.day;

      final huntStartOnCollectionDay = isSameDay
          ? windowStart.minutesSinceMidnight
          : 0;
      final huntEndOnCollectionDay = windowEnd.minutesSinceMidnight;

      final start = huntStartOnCollectionDay > peakStart
          ? huntStartOnCollectionDay
          : peakStart;
      final end = huntEndOnCollectionDay < peakEnd
          ? huntEndOnCollectionDay
          : peakEnd;

      if (end <= start) return 0;
      return (end - start) * 60;
    }

    final huntStart = windowStart.minutesSinceMidnight;
    final huntEnd = windowEnd.minutesSinceMidnight;
    if (huntEnd <= huntStart) return 0;

    final start = huntStart > peakStart ? huntStart : peakStart;
    final end = huntEnd < peakEnd ? huntEnd : peakEnd;
    if (end <= start) return 0;
    return (end - start) * 60;
  }

  /// The number of requests the hunt is projected to make over its own window.
  ///
  /// This is the number the user trades against, so it is surfaced rather
  /// than buried.
  int projectedRequests() {
    final peak = peakOverlapSeconds;
    final offPeak = windowSeconds - peak;

    final requests = peak / rate.peakInterval.inSeconds +
        offPeak / rate.offPeakInterval.inSeconds;
    return requests.ceil();
  }

  /// The projected request count over an arbitrary span of seconds, at the
  /// given interval.
  ///
  /// Used by the UI to price a slider position before the user commits to it.
  static int requestsFor(Duration interval, int seconds) {
    if (interval.inSeconds <= 0 || seconds <= 0) return 0;
    return (seconds / interval.inSeconds).ceil();
  }

  /// A copy with the given fields changed.
  HuntConfig copyWith({
    ClockTime? windowStart,
    ClockTime? windowEnd,
    MealSlot? targetSlot,
    DateTime? targetDate,
    DateTime? startDate,
    bool clearStartDate = false,
    List<HuntDish>? dishPriority,
    List<HuntHall>? hallPriority,
    HuntRate? rate,
    bool? enabled,
    int? requestBudget,
    bool? riskAcknowledged,
  }) {
    final nextWindowStart = windowStart ?? this.windowStart;
    final nextWindowEnd = windowEnd ?? this.windowEnd;
    final nextTargetSlot = targetSlot ?? this.targetSlot;
    final nextTargetDate = targetDate ?? this.targetDate;
    final nextStartDate = clearStartDate ? null : (startDate ?? this.startDate);
    final nextRate = rate ?? this.rate;

    final windowOrRateChanged = windowStart != null ||
        windowEnd != null ||
        rate != null ||
        targetSlot != null ||
        targetDate != null ||
        startDate != null ||
        clearStartDate;

    final nextBudget = requestBudget ??
        (windowOrRateChanged
            ? computeBudget(
                windowStart: nextWindowStart,
                windowEnd: nextWindowEnd,
                targetSlot: nextTargetSlot,
                rate: nextRate,
                targetDate: nextTargetDate,
                startDate: nextStartDate,
              )
            : this.requestBudget);

    return HuntConfig(
      windowStart: nextWindowStart,
      windowEnd: nextWindowEnd,
      targetSlot: nextTargetSlot,
      targetDate: nextTargetDate,
      startDate: nextStartDate,
      dishPriority: dishPriority ?? this.dishPriority,
      hallPriority: hallPriority ?? this.hallPriority,
      rate: nextRate,
      enabled: enabled ?? this.enabled,
      requestBudget: nextBudget,
      riskAcknowledged: riskAcknowledged ?? this.riskAcknowledged,
    );
  }

  /// A copy aimed at a different date or meal slot.
  ///
  /// The dish and hall priority lists are **cleared**, because they belong to
  /// the (date, slot) they were chosen for.
  ///
  /// A price is a property of a (date, slot): the same dish costs 150,000 Rial
  /// as a breakfast and 500,000 Rial as a lunch. So a lunch dish left in the
  /// list after the slot becomes breakfast is a dish the portal is not
  /// offering — and the pre-flight, which demands the credit for the *sum* of
  /// the priority list, would then refuse a hunt for 15,000 Toman because a
  /// stale 50,000 Toman lunch dish was still on the list.
  ///
  /// The halls have the same problem in a milder form: the portal names the
  /// halls it serves for a given day, and a hall it does not serve that day
  /// cannot be bought from.
  HuntConfig retargeted({
    MealSlot? targetSlot,
    DateTime? targetDate,
    DateTime? startDate,
  }) {
    final slot = targetSlot ?? this.targetSlot;
    final date = targetDate ?? this.targetDate;
    final start = startDate ?? this.startDate;

    final sameSlot = slot == this.targetSlot;
    final sameDate = _sameDay(date, this.targetDate);
    final sameStart = _sameDay(start, this.startDate);
    if (sameSlot && sameDate && sameStart) return this;

    final newCollection = HuntSchedules.collectionDate(
      targetDate: date,
      slot: slot,
    );

    final DateTime? newStart;
    if (startDate != null) {
      newStart = startDate;
    } else if (this.startDate != null) {
      if (newCollection != null && this.startDate!.isAfter(newCollection)) {
        newStart = null;
      } else {
        newStart = this.startDate;
      }
    } else {
      newStart = null;
    }

    final newBudget = computeBudget(
      windowStart: windowStart,
      windowEnd: windowEnd,
      targetSlot: slot,
      rate: rate,
      targetDate: date,
      startDate: newStart,
    );

    return HuntConfig(
      windowStart: windowStart,
      windowEnd: windowEnd,
      targetSlot: slot,
      targetDate: date,
      startDate: newStart,
      dishPriority: const [],
      hallPriority: const [],
      rate: rate,
      enabled: enabled,
      requestBudget: newBudget,
      riskAcknowledged: riskAcknowledged,
    );
  }

  static bool _sameDay(DateTime? a, DateTime? b) {
    if (a == null || b == null) return a == b;
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  /// The ranker's preference, built from the dish and hall priority lists.
  ///
  /// The cartesian product of the two lists, ordered dish-first: the first
  /// dish is preferred in every hall before the second dish is considered at
  /// all. That is what "the first choice, then the second" means when a dish
  /// is available in two halls.
  ///
  /// A hall list of one restricts the preference to that hall. A hall list of
  /// two ranks central first, engineering second. An empty hall list means any
  /// hall, which the ranker expresses as "not listed" — but the ranker
  /// rejects unlisted pairs, so the product is taken over every hall the
  /// portal actually offers.
  SlotPreference toSlotPreference({required List<HuntHall> offeredHalls}) {
    final ranked = <PreferencePair>[];

    for (final dish in dishPriority) {
      for (final hall in hallPriority.isEmpty ? offeredHalls : hallPriority) {
        ranked.add(PreferencePair(hallId: hall.id, optionId: dish.optionId));
      }
    }

    return SlotPreference(slot: targetSlot, ranked: ranked);
  }

  /// The rule the engine runs, derived from this configuration.
  ///
  /// The window and the slot come from the configuration, so the engine's own
  /// window check and the hunt's are the same window — a rule that hunted
  /// outside the configured window would be a rule the user could not see.
  ///
  /// The price ceiling is the *dearest* dish on the priority list, because the
  /// hunt may buy the second choice when the first is unavailable, and a
  /// ceiling below the second choice's price would forbid the fallback the
  /// user asked for.
  SnipeRule toRule({
    required String id,
    required AccountId account,
    bool dryRun = false,
  }) =>
      SnipeRule(
        id: id,
        account: account,
        enabled: enabled,
        windowStart: windowStart,
        windowEnd: windowEnd,
        slots: {targetSlot},
        target: targetDate == null
            ? DateTarget.today
            : DateTarget.explicit,
        explicitDate: targetDate,
        windowStartDate: effectiveStartDate,
        windowDate: collectionDate,
        preferences: {
          targetSlot: toSlotPreference(offeredHalls: hallPriority),
        },
        maxPriceRial: maxPriceRial,
        dryRun: dryRun,
      );

  /// The highest price the hunt will pay.
  ///
  /// Null when the hunt set no ceiling, in which case the price is judged
  /// against the live offering per dish instead.
  int? get maxPriceRial {
    if (dishPriority.isEmpty) return null;
    var highest = dishPriority.first.priceRial;
    for (final dish in dishPriority) {
      if (dish.priceRial > highest) highest = dish.priceRial;
    }
    return highest;
  }

  @override
  String toString() => 'HuntConfig($targetSlot, ${dishPriority.length} dishes, '
      '${hallPriority.length} halls, $rate)';
}
