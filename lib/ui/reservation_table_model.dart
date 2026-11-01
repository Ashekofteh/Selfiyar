/// The model behind the reservations table.
///
/// ## Why the table has its own model
///
/// The table answers one question: **what is the state of every meal the
/// student can have, for every day they can still act on?** That is not the
/// same question as "what does the mirror hold" (the reservations screen's
/// question), and it is not the same as "what does the portal serve" (the
/// hunt screen's question).
///
/// So the rows are **built**, not read. A row is a (date, slot) pair with a
/// status derived from three sources:
///
///   * the **menu** — which meals the portal serves, and at what price;
///   * the **mirror** — which of those the student already holds;
///   * the **clock** — which are already past their cutoff.
///
/// ## Why a row can exist without a menu
///
/// A day the portal does not serve still needs to be visible if the student
/// **holds** a meal on it — a basket purchase never appears in the weekly
/// grid (F16), so a menu-only table would hide a meal the student paid for.
/// So a row exists when the portal serves the meal **or** the student holds
/// it.
///
/// ## Why a row does not name a dish
///
/// A menu offers **several** dishes, and the student picks one when they
/// book. So a bookable row says how many options there are and what the
/// cheapest costs — and the dish is chosen in the booking sheet.
///
/// A **held** row names its dish, because that one is decided.
library;

import '../core/local_meal_store.dart';
import '../core/meal_invariant.dart';
import '../core/models.dart';
import '../core/persian.dart';
import '../core/time.dart';
export '../core/persian.dart'
    show
        weekStartSaturday,
        weekEndFriday,
        formatWeekTitle,
        formatWeekRange,
        formatMonthTitle,
        formatJalaliMonthName;


/// What the student can do with a meal.
enum MealRowStatus {
  /// The student holds this meal, reserved for the week.
  held,

  /// The student holds this meal, bought from the Food Basket.
  ///
  /// A basket purchase is **irreversible** (F16) — there is no cancel. The
  /// row says so, because offering a cancel here would be a lie.
  bought,

  /// The meal is served and can still be reserved.
  bookable,

  /// The meal is served, but its cutoff has passed.
  ///
  /// The portal refuses a locked row **silently** (F: session 12), so the app
  /// has to say so before the student tries.
  locked,

  /// The student holds this meal, but its date has passed its cutoff.
  ///
  /// The meal is theirs and it is shown — they paid for it — but it can no
  /// longer be given back: the portal renders a locked row `disabled`, so the
  /// cancel post is discarded (F14). Offering a cancel button here would be
  /// offering one that silently does nothing (F63).
  heldLocked,

  /// The student holds this meal, but has listed it for sale in the Food Basket.
  listedInBasket,
}

/// One row of the table: a (date, slot) pair and its state.
class MealRow {
  const MealRow({
    required this.date,
    required this.slot,
    required this.status,
    this.dishName,
    this.hallName,
    this.priceRial,
    this.optionCount = 0,
    this.availableDishes = const [],
    this.receiptCode,
  });

  final DateTime date;
  final MealSlot slot;
  final MealRowStatus status;

  /// The dish of a **held** meal, or the name(s) of dishes available for booking.
  final String? dishName;

  /// The hall a held meal is in.
  final String? hallName;

  /// The price in Rial.
  ///
  /// For a held meal, what was paid. For a bookable one, the **cheapest**
  /// option's price — the number a student looks at first.
  final int? priceRial;

  /// How many dishes the portal offers for a bookable meal.
  final int optionCount;

  /// The list of available dish names on offer for this meal.
  final List<String> availableDishes;

  /// The cached forgot-card receipt code, if issued.
  final String? receiptCode;

  /// Whether a temporary forgot-card slip code has already been issued for this meal.
  bool get hasReceipt => receiptCode != null && receiptCode!.isNotEmpty;

  /// Whether the student can cancel this meal.
  ///
  /// A basket purchase cannot be given back (F16), and a weekly reservation
  /// can only be cancelled while its date is still editable (F14).
  bool get cancellable => status == MealRowStatus.held;

  /// Whether the student can list this meal for sale in the Food Basket.
  ///
  /// A basket purchase cannot be resold (F16). A held meal whose date has
  /// locked can be offered for sale in the secondary Food Basket to avoid the
  /// unconsumed meal penalty (Announcement 2090).
  bool get sellable => status == MealRowStatus.heldLocked;

  /// Whether this meal is currently listed for sale in the Food Basket.
  bool get inBasketSale => status == MealRowStatus.listedInBasket;

  /// The status, in words.
  String get statusLabel => switch (status) {
        MealRowStatus.held => 'رزرو شده',
        MealRowStatus.heldLocked => 'رزرو شده - مهلت گذشته',
        MealRowStatus.listedInBasket => 'در سبد فروش',
        MealRowStatus.bought => 'خریداری شده',
        MealRowStatus.bookable => 'قابل رزرو',
        MealRowStatus.locked => 'مهلت گذشته',
      };
}

/// Builds the rows of the table.
///
/// The rows come back in **date order, then meal order** — the order the
/// student experiences them in, so the table reads as a schedule rather than
/// as a set.
List<MealRow> buildMealRows({
  required List<MealMenu> menus,
  required List<StoredMeal> held,
  required ServerClock? clock,
  bool Function(DateTime date, MealSlot slot)? isListedInBasket,
  String? Function(DateTime date, MealSlot slot)? receiptCodeFor,
}) {
  // The mirror's meals, keyed by (date, slot).
  final heldByKey = <String, StoredMeal>{};
  for (final meal in held) {
    heldByKey[_key(meal.date, meal.slot)] = meal;
  }

  // The menu entry for each (date, slot) the portal serves.
  final menuByKey = <String, MealMenu>{};
  for (final menu in menus) {
    menuByKey[_key(menu.date, menu.slot)] = menu;
  }

  // Every (date, slot) pair the table has a row for: the portal serves it,
  // or the student holds it.
  final dates = <String, DateTime>{};
  final slots = <String, MealSlot>{};
  for (final key in {...menuByKey.keys, ...heldByKey.keys}) {
    dates[key] = heldByKey[key]?.date ?? menuByKey[key]!.date;
    slots[key] = heldByKey[key]?.slot ?? menuByKey[key]!.slot;
  }

  final rows = <MealRow>[];
  for (final key in dates.keys) {
    final heldMeal = heldByKey[key];
    final menu = menuByKey[key];

    if (heldMeal != null) {
      // A held meal whose date has passed its cutoff can no longer be given
      // back: the portal renders a locked row `disabled` and discards the
      // cancel post (F14). The meal is still shown — the student holds it —
      // but it must not offer a cancel that would silently do nothing (F63).
      final locked = clock != null &&
          clock.isSynced &&
          !clock.isReservable(dates[key]!);
      final inBasket = isListedInBasket?.call(dates[key]!, slots[key]!) ?? false;

      final MealRowStatus status;
      if (heldMeal.source == MealSource.basketPurchase) {
        status = MealRowStatus.bought;
      } else if (inBasket) {
        status = MealRowStatus.listedInBasket;
      } else if (locked) {
        status = MealRowStatus.heldLocked;
      } else {
        status = MealRowStatus.held;
      }

      rows.add(MealRow(
        date: dates[key]!,
        slot: slots[key]!,
        status: status,
        dishName: heldMeal.dishName,
        hallName: heldMeal.hallName,
        priceRial: heldMeal.priceRial,
        optionCount: menu?.dishes.length ?? 0,
        receiptCode: receiptCodeFor?.call(dates[key]!, slots[key]!),
      ));
      continue;
    }

    // The portal does not serve this meal, and the student does not hold it.
    // There is nothing to show.
    if (menu == null) continue;

    // The cutoff. The portal refuses a locked row silently, so the app has to
    // say so first.
    final locked = !menu.reservable ||
        (clock != null && clock.isSynced && !clock.isReservable(dates[key]!));

    final cheapest = _cheapest(menu);
    final dishDisplay = menu.dishes.length == 1
        ? menu.dishes.first.name
        : (menu.dishes.isNotEmpty
            ? menu.dishes.map((d) => d.name).join(' یا ')
            : null);

    rows.add(MealRow(
      date: dates[key]!,
      slot: slots[key]!,
      status: locked ? MealRowStatus.locked : MealRowStatus.bookable,
      dishName: dishDisplay,
      priceRial: cheapest?.priceRial,
      optionCount: menu.dishes.length,
      availableDishes: menu.dishes.map((d) => d.name).toList(),
    ));
  }

  rows.sort((a, b) {
    final byDate = a.date.compareTo(b.date);
    if (byDate != 0) return byDate;
    return a.slot.index.compareTo(b.slot.index);
  });

  return rows;
}

/// The cheapest dish on the menu, which is the one the price cell carries.
MenuOption? _cheapest(MealMenu menu) {
  if (menu.dishes.isEmpty) return null;
  return menu.dishes.reduce(
    (a, b) => a.priceRial <= b.priceRial ? a : b,
  );
}

/// The key of a (date, slot) pair.
String _key(DateTime date, MealSlot slot) =>
    '${date.year}-${date.month}-${date.day}|${slot.name}';

/// The Persian name of a date, for the table's day headers.
String formatRowDate(DateTime date) => formatPersianDateWithYear(date);



/// Filters rows down to those falling strictly within the week `[saturday, saturday + 6 days]`.
List<MealRow> filterRowsForWeek(List<MealRow> rows, DateTime saturday) {
  final start = DateTime.utc(saturday.year, saturday.month, saturday.day);
  final end = DateTime.utc(saturday.year, saturday.month, saturday.day + 6);
  return rows.where((row) {
    final d = DateTime.utc(row.date.year, row.date.month, row.date.day);
    return !d.isBefore(start) && !d.isAfter(end);
  }).toList();
}
