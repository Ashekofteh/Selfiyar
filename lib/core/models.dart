/// Domain models for the Food Basket app.
///
/// This library is platform-agnostic: it must never import `dart:io`, `dart:ui`,
/// or any `package:flutter/*`. Keeping it pure is what lets the whole domain be
/// unit-tested on the Dart VM and reused verbatim by the Windows target.
library;

/// Identifiers are opaque strings owned by the portal. Never parse them,
/// never construct them, never assume a format.
typedef MealId = String;
typedef HallId = String;
typedef OptionId = String;
typedef ListingId = String;
typedef AccountId = String;

/// The three meals served per day.
enum MealSlot { breakfast, lunch, dinner }

/// Localized Persian names for meal slots.
extension MealSlotPersian on MealSlot {
  String get persianName => switch (this) {
        MealSlot.breakfast => 'صبحانه',
        MealSlot.lunch => 'ناهار',
        MealSlot.dinner => 'شام',
      };
}

/// A meal on a day: the (date, slot) pair a reservation is held for.
///
/// ## Why this exists, and why it is not a string
///
/// The cancel used to travel as a string, `<date>|<slot>`, and the adapter
/// parsed it back. That round-trip was **silently lossy**: Dart's enum
/// `toString()` is `MealSlot.breakfast`, but the parser matched
/// `slot.name` — `breakfast` — and fell through to a default. So a cancel
/// for a breakfast was applied to the **lunch** grid, and the read-back
/// looked for lunch, found none, and reported success. The portal kept the
/// breakfast; the app removed it from its mirror (F65).
///
/// A string that has to be parsed back into a slot is a string that can be
/// parsed into the **wrong** slot. The pair is carried as values instead, so
/// there is nothing to misparse.
class MealRef {
  const MealRef({required this.date, required this.slot});

  /// The day, in the portal's (Tehran) local frame. Time-of-day is
  /// meaningless; the cutoff lives in `ServerClock`.
  final DateTime date;

  final MealSlot slot;

  @override
  bool operator ==(Object other) =>
      other is MealRef &&
      other.date.year == date.year &&
      other.date.month == date.month &&
      other.date.day == date.day &&
      other.slot == slot;

  @override
  int get hashCode => Object.hash(date.year, date.month, date.day, slot);

  @override
  String toString() =>
      '${date.toIso8601String().substring(0, 10)}|${slot.name}';
}

/// Lifecycle of a reservation the student holds.
///
/// [unknown] exists because the portal can report a state we do not recognise;
/// it must never be silently coerced into [active].
enum ReservationState { active, cancelled, consumed, sold, unknown }

/// A dining hall. Two exist today (مرکزی برادران / فنی برادران) but the count
/// is data, not a constant.
class Hall {
  const Hall({required this.id, required this.name});

  final HallId id;
  final String name;

  @override
  String toString() => 'Hall($id, $name)';
}

/// The canonical key for a dish name, used to match a dish across portal pages.
///
/// ## Why the name and not the option id
///
/// The **market renumbers the ids.** Verified live (2026-10-20): the same
/// dish, on the same date and slot, is option `62737` in the weekly
/// reservation grid and option `62798` on the Food Basket buy page — the
/// same name, the same price, a different id. So an id a user picked from the
/// official menu can never identify the market listing of that same dish, and
/// a hunt that matched on ids would never fire.
///
/// The name is the only thing that survives the renumbering, so it is what a
/// dish is matched on. The portal is also inconsistent about how it separates
/// the components of a name (`پنیر /گوجه /نان` in one grid, `پنیر/گوجه/نان`
/// in another, with `,` and `/` both in use), so the name is normalised
/// before comparison — otherwise one dish reads as two.
String normalizeDishName(String name) => name
    .replaceAll(RegExp(r'\s+'), '')
    .replaceAll('،', ',')
    .replaceAll('٫', ',')
    .replaceAll('/', ',')
    .trim();

/// A menu option within a meal, carrying the subsidized price in Rial.
///
/// The portal also renders an unsubsidized (بدون یارانه) price tier, but that
/// tier is non-functional and is never modelled here.
class MenuOption {
  const MenuOption({
    required this.id,
    required this.name,
    required this.priceRial,
  });

  final OptionId id;
  final String name;
  final int priceRial;

  /// The name normalised for cross-page matching. See [normalizeDishName].
  String get dishKey => normalizeDishName(name);

  @override
  String toString() => 'MenuOption($id, $name, $priceRial Rial)';
}

/// The official offering for one (date, meal slot): the halls that serve it
/// and the dishes on offer.
///
/// ## The dishes are the same in every hall
///
/// The portal publishes **one menu per (date, slot)** and names the halls
/// that serve it. The dishes are not per-hall: every hall serves the same
/// dishes for that meal. So a menu is a list of halls and a list of dishes,
/// and the pairings are implied — not a per-hall list of dishes.
///
/// This is the *weekly menu* (`Reservation.aspx`), which says what the
/// university serves. It is not the *marketplace* (`FoodBasketBuy.aspx`),
/// which says what has been released for sale. The two answer different
/// questions, and the hunt's setup needs this one.
class MealMenu {
  const MealMenu({
    required this.date,
    required this.slot,
    required this.halls,
    required this.dishes,
    required this.reservable,
  });

  /// Date-only, in the portal's (Tehran) local frame.
  final DateTime date;
  final MealSlot slot;

  /// The halls that serve this meal, in the portal's own order.
  ///
  /// The identity is the **id**; the name is display only. The portal names
  /// halls differently for different accounts.
  final List<Hall> halls;

  /// The dishes on offer, in the portal's own order, with their prices.
  ///
  /// A price belongs to a (date, slot): the same dish costs 150,000 Rial as a
  /// breakfast and 500,000 as a lunch. So these prices are only meaningful
  /// together with this menu's [date] and [slot].
  final List<MenuOption> dishes;

  /// False once the server-side cutoff has passed.
  final bool reservable;

  @override
  String toString() =>
      'MealMenu(${date.toIso8601String()} $slot, ${dishes.length} dishes, '
      '${halls.length} halls)';
}

/// A (date, meal, hall, option) tuple the student could reserve.
class MealOffering {
  const MealOffering({
    required this.date,
    required this.slot,
    required this.hall,
    required this.option,
    required this.reservable,
  });

  /// Date-only, in the portal's (Tehran) local frame. Time-of-day is meaningless
  /// here; the cutoff lives in [ServerClock].
  final DateTime date;
  final MealSlot slot;
  final Hall hall;
  final MenuOption option;

  /// False once the server-side cutoff has passed.
  final bool reservable;

  @override
  String toString() =>
      'MealOffering(${date.toIso8601String()} $slot ${hall.name} ${option.name})';
}

/// A reservation the student holds.
class Reservation {
  const Reservation({
    required this.id,
    required this.date,
    required this.slot,
    required this.hall,
    required this.option,
    required this.state,
  });

  final MealId id;
  final DateTime date;
  final MealSlot slot;
  final Hall hall;
  final MenuOption option;
  final ReservationState state;

  @override
  String toString() => 'Reservation($id, $slot, ${state.name})';
}

/// A listing in the Food Basket: another student's released reservation.
///
/// **Identity is composite, and includes the hall.**
///
/// `FoodBasketBuy.aspx` renders one row per (date, meal slot). Each row carries
/// a **hall dropdown** (the halls the market is offering that row's meals in)
/// and a **food dropdown** (the meals on offer). A purchase is a POST naming
/// both: the row's `drpSelf` and its `drpFood`.
///
/// So a listing is `(date, slot, hallId, optionId)`, and the hall is part of
/// the identity rather than a decoration. Two listings of the same dish in two
/// different halls are genuinely different listings: they are bought with
/// different POSTs, and one being gone says nothing about the other.
///
/// The hall is **not** a display detail. The portal names halls per account
/// (a female account may see «مرکزی خواهران» where a male one sees «مرکزی
/// برادران»), so the app keys on the id and shows whatever name the portal
/// supplied. Matching on a Persian hall name would be a bug waiting to happen.
class Listing {
  const Listing({
    required this.id,
    required this.date,
    required this.slot,
    required this.hall,
    required this.option,
    this.expiresAt,
  });

  /// Builds a listing and derives its composite id.
  factory Listing.composite({
    required DateTime date,
    required MealSlot slot,
    required Hall hall,
    required MenuOption option,
    DateTime? expiresAt,
  }) {
    final id = compositeListingId(
      date: date,
      slot: slot,
      hallId: hall.id,
      optionId: option.id,
    );
    return Listing(
      id: id,
      date: date,
      slot: slot,
      hall: hall,
      option: option,
      expiresAt: expiresAt,
    );
  }

  /// The composite identity of a listing: `date|slot|hallId|optionId`.
  ///
  /// Uses only the civil date, never a time component: a listing is a meal on
  /// a day, and including a time would make the same meal two different ids.
  static String compositeListingId({
    required DateTime date,
    required MealSlot slot,
    required String hallId,
    required String optionId,
  }) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}'
      '|${slot.name}'
      '|$hallId'
      '|$optionId';

  final ListingId id;
  final DateTime date;
  final MealSlot slot;

  /// The hall this listing is bought from.
  ///
  /// Not optional: the claim POST names a hall, so a listing without one
  /// cannot be bought. The parser drops such rows rather than inventing a
  /// hall, because guessing here spends money.
  final Hall hall;

  final MenuOption option;

  /// Server-reported expiry, when the portal exposes one. Optional because the
  /// portal may not always publish it.
  final DateTime? expiresAt;

  /// The price to pay, taken from the option itself.
  int get priceRial => option.priceRial;

  @override
  String toString() => 'Listing($id, ${option.name})';
}

/// Account balance snapshot.
class Balance {
  const Balance({
    required this.amountRial,
    required this.fetchedAt,
    this.profileName,
  });

  final int amountRial;
  final DateTime fetchedAt;
  final String? profileName;

  @override
  String toString() =>
      'Balance($amountRial Rial${profileName != null ? ", $profileName" : ""})';
}