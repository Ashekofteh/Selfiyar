/// The one-meal-per-slot-per-day invariant.
///
/// ## Why this lives in the client
///
/// Verified live (2026-10-19, F21/F22):
///
///   * The basket's food dropdown is **not** filtered by what the student
///     already holds. For 1405/07/30 the basket offered option 62759 — the
///     exact meal the account already held weekly — for the same date and slot.
///   * The **server does not enforce the rule either**. A POST attempting to
///     buy the already-held meal returned 200, an empty alert box, no state
///     change, and no charge.
///
/// So the rule is entirely the app's responsibility. Without this guard the app
/// could buy a second meal for a slot the student already reserved — and
/// because a basket purchase is **irreversible**, that is money spent on a meal
/// the student cannot collect and cannot cancel.
///
/// ## The rule
///
/// For a given (date, slot) pair, a student may hold **at most one** meal, from
/// either source, and never both.
library;

import 'models.dart';

/// Where a meal came from.
enum MealSource {
  /// A weekly reservation, made through the reservation grid.
  weeklyReservation,

  /// A Food Basket purchase, of another student's released meal.
  basketPurchase,
}

/// A held meal, from either source.
class HeldMeal {
  const HeldMeal({
    required this.accountId,
    required this.date,
    required this.slot,
    required this.source,
    this.optionId,
    this.dishName,
    this.isConsumed = false,
  });

  final AccountId accountId;
  final DateTime date;
  final MealSlot slot;
  final MealSource source;
  final OptionId? optionId;
  final String? dishName;
  final bool isConsumed;

  /// The identity of a held meal: account + date + slot.
  ///
  /// The account is part of the key because each student has their own meals;
  /// see [heldMealKey].
  String get key => '$accountId|${dateKey(date)}|${slot.name}';

  static String dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  @override
  String toString() => 'HeldMeal($key, ${source.name})';
}

/// The identity of a (date, slot) pair within one account.
String mealKey(DateTime date, MealSlot slot) =>
    '${HeldMeal.dateKey(date)}|${slot.name}';

/// The identity of a held meal within the ledger: account + date + slot.
///
/// The account matters: each student has their own meals, so one account
/// holding a slot must never block another account from holding it. Keying the
/// ledger by date+slot alone would make the app refuse legitimate bookings for
/// the second account — a bug that would only appear with two accounts on one
/// phone, which is exactly what this app is for.
String heldMealKey(AccountId accountId, DateTime date, MealSlot slot) =>
    '$accountId|${mealKey(date, slot)}';

/// Why a meal cannot be held.
enum MealConflictReason {
  /// A weekly reservation already holds this slot on this date.
  alreadyReservedWeekly,

  /// A basket purchase already holds this slot on this date.
  alreadyPurchasedFromBasket,

  /// The meal was already held, and the same slot on the same date was
  /// attempted a second time.
  duplicateAttempt,
}

/// The verdict of a would-be hold.
class MealConflict {
  const MealConflict({required this.reason, required this.conflicting});

  final MealConflictReason reason;

  /// The meal that already occupies the slot.
  final HeldMeal conflicting;

  @override
  String toString() => 'MealConflict(${reason.name}, ${conflicting.key})';
}

/// The result of checking whether a meal may be held.
class MealAdmission {
  /// The meal may be held.
  const MealAdmission.allowed() : allowed = true, conflict = null;

  /// The meal may not be held.
  const MealAdmission.denied(this.conflict) : allowed = false;

  final bool allowed;
  final MealConflict? conflict;

  bool get isAllowed => allowed;

  @override
  String toString() => allowed
      ? 'MealAdmission.allowed'
      : 'MealAdmission.denied(${conflict?.reason.name})';
}

/// Enforces the one-meal-per-slot-per-date rule across both sources.
///
/// The store is the single place that knows what an account holds, so the rule
/// cannot be bypassed by a caller that forgets to check.
class MealLedger {
  MealLedger([Iterable<HeldMeal> initial = const []]) {
    for (final meal in initial) {
      _byKey[meal.key] = meal;
    }
  }

  final Map<String, HeldMeal> _byKey = {};

  /// Every meal currently held, across all accounts, dates and slots.
  List<HeldMeal> get all => _byKey.values.toList();

  int get count => _byKey.length;

  /// The meal held by [accountId] for (date, slot), if any.
  HeldMeal? heldFor(AccountId accountId, DateTime date, MealSlot slot) =>
      _byKey[heldMealKey(accountId, date, slot)];

  /// Whether [accountId] already holds a meal in this slot on this date.
  bool holds(AccountId accountId, DateTime date, MealSlot slot) =>
      heldFor(accountId, date, slot) != null;

  /// Checks whether a meal may be held, WITHOUT holding it.
  ///
  /// Use this before presenting the user with a confirm action, and again
  /// immediately before the write, because the state may have changed in
  /// between (another device, a manual browser booking, a basket purchase that
  /// landed while the app was closed).
  MealAdmission check({
    required AccountId accountId,
    required DateTime date,
    required MealSlot slot,
    required MealSource source,
  }) {
    final existing = heldFor(accountId, date, slot);
    if (existing == null) {
      return const MealAdmission.allowed();
    }

    // The slot is occupied. The only permitted transition is nothing at all:
    // one meal per slot per date, from either source, full stop.
    final reason = switch (existing.source) {
      MealSource.weeklyReservation =>
        MealConflictReason.alreadyReservedWeekly,
      MealSource.basketPurchase =>
        MealConflictReason.alreadyPurchasedFromBasket,
    };
    return MealAdmission.denied(MealConflict(
      reason: reason,
      conflicting: existing,
    ));
  }

  /// Records a held meal.
  ///
  /// Returns the admission verdict: if the slot was already occupied, the
  /// existing meal is **kept** and the attempt is denied. The caller must treat
  /// a denial as a refusal to write, not as a warning.
  MealAdmission hold({
    required AccountId accountId,
    required DateTime date,
    required MealSlot slot,
    required MealSource source,
    OptionId? optionId,
    String? dishName,
  }) {
    final verdict = check(
      accountId: accountId,
      date: date,
      slot: slot,
      source: source,
    );
    if (!verdict.allowed) return verdict;

    _byKey[heldMealKey(accountId, date, slot)] = HeldMeal(
      accountId: accountId,
      date: date,
      slot: slot,
      source: source,
      optionId: optionId,
      dishName: dishName,
    );
    return verdict;
  }

  /// Removes a held meal, e.g. after a cancellation.
  ///
  /// Returns the removed meal, or null when the slot was empty.
  HeldMeal? release(AccountId accountId, DateTime date, MealSlot slot) =>
      _byKey.remove(heldMealKey(accountId, date, slot));

  /// Replaces the whole set, e.g. after re-reading the portal.
  void replaceAll(Iterable<HeldMeal> meals) {
    _byKey
      ..clear()
      ..addEntries(meals.map(
          (m) => MapEntry(heldMealKey(m.accountId, m.date, m.slot), m)));
  }

  /// The meals held by [accountId] on [date], in slot order.
  List<HeldMeal> heldOn(AccountId accountId, DateTime date) {
    final out = <HeldMeal>[];
    for (final slot in MealSlot.values) {
      final meal = heldFor(accountId, date, slot);
      if (meal != null) out.add(meal);
    }
    return out;
  }
}
