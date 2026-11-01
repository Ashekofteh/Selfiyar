/// The local store of held meals — the source of truth for offline reminders.
///
/// ## Why it exists
///
/// The reminder feature must work **offline**: firing a notification should
/// never require logging into the portal. So the app keeps a local mirror of
/// what each account holds, updated whenever the app does something (a
/// booking, a basket purchase, a cancellation) and refreshed opportunistically
/// when a live session is available.
///
/// The live portal check remains available as an **opt-in** setting, off by
/// default. When it is on, the reminder reconciles against the portal before
/// sending; when it is off, it reads only the local store.
///
/// ## Retention
///
/// A meal only matters until the end of the week it belongs to. Once a week has
/// passed the record is obsolete: the meal was eaten, missed, or expired, and
/// the portal will not let it be used again. Keeping those records forever is
/// storage bloat with no possible use, so the store prunes them.
///
/// Pruning is by **date**, not by insertion time, so a record's lifetime is
/// determined by the week it describes rather than by when the app happened to
/// cache it.
library;

import 'meal_invariant.dart';
import 'models.dart';

/// A meal as stored on the device.
class StoredMeal {
  const StoredMeal({
    required this.accountId,
    required this.date,
    required this.slot,
    required this.source,
    required this.capturedAt,
    this.optionId,
    this.dishName,
    this.hallName,
    this.priceRial,
    this.isConsumed = false,
  });

  final AccountId accountId;
  final DateTime date;
  final MealSlot slot;
  final MealSource source;

  /// When the app last confirmed this meal. Used for diagnostics and to
  /// decide whether a live re-check is warranted.
  final DateTime capturedAt;

  final OptionId? optionId;
  final String? dishName;
  final String? hallName;
  final int? priceRial;
  final bool isConsumed;

  /// The identity within the store: account + date + slot.
  String get key => '$accountId|${HeldMeal.dateKey(date)}|${slot.name}';

  HeldMeal toHeldMeal() => HeldMeal(
        accountId: accountId,
        date: date,
        slot: slot,
        source: source,
        optionId: optionId,
        dishName: dishName,
        isConsumed: isConsumed,
      );

  StoredMeal copyWith({
    DateTime? capturedAt,
    bool? isConsumed,
  }) =>
      StoredMeal(
        accountId: accountId,
        date: date,
        slot: slot,
        source: source,
        capturedAt: capturedAt ?? this.capturedAt,
        optionId: optionId,
        dishName: dishName,
        hallName: hallName,
        priceRial: priceRial,
        isConsumed: isConsumed ?? this.isConsumed,
      );

  @override
  String toString() => 'StoredMeal($key)';
}

/// The local meal store.
///
/// Pure and synchronous: the platform layer owns the disk. That keeps the
/// retention policy and the digest logic testable on the VM with no device.
class LocalMealStore {
  LocalMealStore({
    this.retentionDays = 14,
    this.maxEntries = 400,
    Iterable<StoredMeal> initial = const [],
  })  : assert(retentionDays > 0, 'retention must be positive'),
        assert(maxEntries > 0, 'maxEntries must be positive') {
    for (final meal in initial) {
      _meals[meal.key] = meal;
    }
  }

  /// How many days of meals to keep.
  ///
  /// Fourteen days covers the current and the coming week with a week of
  /// slack. The reminder's furthest horizon is the coming week, so anything
  /// older than that cannot affect any notification.
  final int retentionDays;

  /// Hard cap on stored meals, so a pathological state cannot grow without
  /// bound regardless of the retention policy.
  final int maxEntries;

  final Map<String, StoredMeal> _meals = {};

  int get count => _meals.length;

  List<StoredMeal> get all => _meals.values.toList();

  /// The meals stored for [accountId], newest date first.
  List<StoredMeal> forAccount(AccountId accountId) {
    final out = _meals.values
        .where((m) => m.accountId == accountId)
        .toList()
      ..sort((a, b) {
        final byDate = b.date.compareTo(a.date);
        if (byDate != 0) return byDate;
        return a.slot.index.compareTo(b.slot.index);
      });
    return out;
  }

  /// The meals stored for [accountId] on [date].
  List<StoredMeal> onDate(AccountId accountId, DateTime date) => _meals.values
      .where((m) => m.accountId == accountId && _sameDate(m.date, date))
      .toList();

  /// The meal stored for (accountId, date, slot), if any.
  StoredMeal? find(AccountId accountId, DateTime date, MealSlot slot) {
    for (final meal in _meals.values) {
      if (meal.accountId == accountId &&
          meal.slot == slot &&
          _sameDate(meal.date, date)) {
        return meal;
      }
    }
    return null;
  }

  /// Records a meal, replacing any existing record for the same slot.
  void put(StoredMeal meal) {
    _meals[meal.key] = meal;
  }

  /// Replaces every stored meal with [meals].
  ///
  /// Used by a portal sync, where the portal's list is the truth: a meal that
  /// has been cancelled or has passed must not linger in the local mirror and
  /// keep showing up in a reminder.
  void replaceAll(Iterable<StoredMeal> meals) {
    _meals
      ..clear()
      ..addEntries(meals.map((m) => MapEntry(m.key, m)));
  }

  /// Removes the meal for (accountId, date, slot).
  ///
  /// Returns true when something was removed.
  bool remove(AccountId accountId, DateTime date, MealSlot slot) {
    final key = _keyFor(accountId, date, slot);
    return _meals.remove(key) != null;
  }

  /// Replaces every meal for [accountId] with [meals].
  ///
  /// Used after a live re-read, so the local mirror matches the portal exactly
  /// — including meals that disappeared.
  void replaceForAccount(AccountId accountId, Iterable<StoredMeal> meals) {
    _meals.removeWhere((_, meal) => meal.accountId == accountId);
    for (final meal in meals) {
      _meals[meal.key] = meal;
    }
  }

  /// Removes every meal for [accountId]. Used when an account is deleted.
  void purgeAccount(AccountId accountId) =>
      _meals.removeWhere((_, meal) => meal.accountId == accountId);

  /// Drops meals that are no longer relevant.
  ///
  /// A meal is obsolete once its week has passed: it was eaten, missed, or
  /// expired, and the portal will not honour it again. [now] is the current
  /// civil date; meals dated before the retention window are removed, and the
  /// oldest excess entries are dropped if the hard cap is still exceeded.
  ///
  /// Returns the number of records removed, so the caller can log it.
  int prune(DateTime now) {
    final cutoff = DateTime.utc(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: retentionDays));

    final before = _meals.length;

    // 1. Age-based: anything older than the retention window.
    _meals.removeWhere((_, meal) => meal.date.isBefore(cutoff));

    // 2. Cap-based: if still over the hard cap, drop the oldest by date.
    if (_meals.length > maxEntries) {
      final byDate = _meals.values.toList()
        ..sort((a, b) => a.date.compareTo(b.date));
      final excess = _meals.length - maxEntries;
      for (var i = 0; i < excess; i++) {
        _meals.remove(byDate[i].key);
      }
    }

    return before - _meals.length;
  }

  /// A [MealLedger] view of the store, for the one-meal invariant.
  ///
  /// The ledger enforces the invariant against what is *known*, so a purchase
  /// is refused if a meal for that slot and date is already recorded — from
  /// either source.
  MealLedger toLedger() => MealLedger(all.map((m) => m.toHeldMeal()));

  /// The date after which a meal may be dropped, for display in the UI.
  DateTime retentionCutoff(DateTime now) => DateTime.utc(
        now.year,
        now.month,
        now.day,
      ).subtract(Duration(days: retentionDays));

  static String _keyFor(AccountId accountId, DateTime date, MealSlot slot) =>
      '$accountId|${HeldMeal.dateKey(date)}|${slot.name}';

  static bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
