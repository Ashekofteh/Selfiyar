/// The local store of bookable meal menus — the source of truth for offline menu viewing.
///
/// Keeps the weekly reservation table responsive (instant load) and functional offline.
///
/// ## Retention & Pruning Policy
///
/// University menus are kept up to [retentionDays] (default 28 days / 4 weeks)
/// so students can freely browse previous weeks even when offline.
/// A hard cap of [maxEntries] (default 120 slots) prevents pathological memory bloat.
library;

import 'models.dart';

/// The local menu store.
///
/// Pure and synchronous: the platform layer owns the disk. That keeps the
/// retention policy and the digest logic testable on the VM with no device.
class LocalMenuStore {
  LocalMenuStore({
    this.retentionDays = 28,
    this.maxEntries = 120,
    Iterable<MealMenu> initial = const [],
  })  : assert(retentionDays > 0, 'retention must be positive'),
        assert(maxEntries > 0, 'maxEntries must be positive') {
    for (final menu in initial) {
      _menus[menuKey(menu)] = menu;
    }
  }

  /// How many days of menus to keep.
  final int retentionDays;

  /// Hard cap on stored menus.
  final int maxEntries;

  final Map<String, MealMenu> _menus = {};

  int get count => _menus.length;
  bool get isEmpty => _menus.isEmpty;
  bool get isNotEmpty => _menus.isNotEmpty;

  /// Returns all stored menus sorted by date ascending, then slot order.
  List<MealMenu> get all {
    final list = _menus.values.toList()
      ..sort((a, b) {
        final dateCmp = a.date.compareTo(b.date);
        if (dateCmp != 0) return dateCmp;
        return a.slot.index.compareTo(b.slot.index);
      });
    return list;
  }

  /// Menus served on [date].
  List<MealMenu> forDate(DateTime date) => _menus.values
      .where((m) => _sameDate(m.date, date))
      .toList()
    ..sort((a, b) => a.slot.index.compareTo(b.slot.index));

  /// Menus served within the given collection of dates.
  List<MealMenu> forDates(Iterable<DateTime> dates) {
    final dateSet = dates.map(_dateOnly).toSet();
    return _menus.values
        .where((m) => dateSet.contains(_dateOnly(m.date)))
        .toList()
      ..sort((a, b) {
        final dateCmp = a.date.compareTo(b.date);
        if (dateCmp != 0) return dateCmp;
        return a.slot.index.compareTo(b.slot.index);
      });
  }

  /// Finds the menu for (date, slot), if any.
  MealMenu? find(DateTime date, MealSlot slot) => _menus[keyFor(date, slot)];

  /// Records a menu, replacing any existing entry for that (date, slot).
  void put(MealMenu menu) {
    _menus[menuKey(menu)] = menu;
  }

  /// Upserts incoming menus into the store, merging halls across accounts
  /// (e.g. brother and sister dorms) while updating dishes and reservable status
  /// to match current authoritative portal offerings.
  void upsert(Iterable<MealMenu> menus) {
    for (final incoming in menus) {
      final key = menuKey(incoming);
      final existing = _menus[key];
      if (existing == null) {
        _menus[key] = incoming;
      } else {
        // Merge halls by ID so all campuses/dormitories seen across accounts remain available
        final hallsMap = {for (final h in existing.halls) h.id: h};
        for (final h in incoming.halls) {
          hallsMap[h.id] = h;
        }

        // Dishes represent current offerings for this slot from the cafeteria.
        // Incoming authoritative dishes replace existing to avoid retaining obsolete/cancelled dishes.
        final dishes = incoming.dishes.isNotEmpty
            ? incoming.dishes.toList()
            : existing.dishes;

        _menus[key] = MealMenu(
          date: incoming.date,
          slot: incoming.slot,
          halls: hallsMap.values.toList(),
          dishes: dishes,
          reservable: incoming.reservable,
        );
      }
    }
  }

  /// Checks whether [incoming] menus contain any differences or additions
  /// compared to what is currently held in this store for those dates/slots.
  bool hasChanges(Iterable<MealMenu> incoming) {
    if (incoming.isEmpty) return false;
    for (final inc in incoming) {
      final existing = find(inc.date, inc.slot);
      // New slot/date not previously stored (e.g. next week published)
      if (existing == null) return true;
      if (existing.reservable != inc.reservable) return true;

      // Check dishes count and details
      if (existing.dishes.length != inc.dishes.length) return true;
      final existingDishes = {for (final d in existing.dishes) d.id: d};
      for (final d in inc.dishes) {
        final ex = existingDishes[d.id];
        if (ex == null || ex.name != d.name || ex.priceRial != d.priceRial) {
          return true;
        }
      }

      // Check if incoming introduced any new halls
      final existingHallIds = {for (final h in existing.halls) h.id};
      for (final h in inc.halls) {
        if (!existingHallIds.contains(h.id)) return true;
      }
    }
    return false;
  }

  /// Replaces every stored menu with [menus].
  void replaceAll(Iterable<MealMenu> menus) {
    _menus
      ..clear()
      ..addEntries(menus.map((m) => MapEntry(menuKey(m), m)));
  }

  /// Removes the menu for (date, slot).
  bool remove(DateTime date, MealSlot slot) =>
      _menus.remove(keyFor(date, slot)) != null;

  /// Clears all menus.
  void clear() => _menus.clear();

  /// Drops menus that fall outside the retention window or exceed the hard cap.
  int prune(DateTime now) {
    final cutoff = DateTime.utc(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: retentionDays));

    final before = _menus.length;

    // 1. Drop menus older than the retention cutoff.
    _menus.removeWhere((_, menu) => menu.date.isBefore(cutoff));

    // 2. Cap-based: drop the oldest by date if still exceeding maxEntries.
    if (_menus.length > maxEntries) {
      final sortedByDate = _menus.values.toList()
        ..sort((a, b) => a.date.compareTo(b.date));
      final excess = _menus.length - maxEntries;
      for (var i = 0; i < excess; i++) {
        _menus.remove(menuKey(sortedByDate[i]));
      }
    }

    return before - _menus.length;
  }

  /// The date after which a menu is obsolete.
  DateTime retentionCutoff(DateTime now) => DateTime.utc(
        now.year,
        now.month,
        now.day,
      ).subtract(Duration(days: retentionDays));

  static String keyFor(DateTime date, MealSlot slot) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}|${slot.name}';

  static String menuKey(MealMenu menu) => keyFor(menu.date, menu.slot);

  static bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _dateOnly(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// Compares two lists of menus for equality.
bool menusEqual(List<MealMenu> a, List<MealMenu> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  final mapB = {for (final m in b) LocalMenuStore.menuKey(m): m};
  for (final ma in a) {
    final mb = mapB[LocalMenuStore.menuKey(ma)];
    if (mb == null) return false;
    if (ma.reservable != mb.reservable) return false;
    if (ma.halls.length != mb.halls.length) return false;
    if (ma.dishes.length != mb.dishes.length) return false;
    for (var i = 0; i < ma.halls.length; i++) {
      if (ma.halls[i].id != mb.halls[i].id ||
          ma.halls[i].name != mb.halls[i].name) {
        return false;
      }
    }
    for (var i = 0; i < ma.dishes.length; i++) {
      if (ma.dishes[i].id != mb.dishes[i].id ||
          ma.dishes[i].name != mb.dishes[i].name ||
          ma.dishes[i].priceRial != mb.dishes[i].priceRial) {
        return false;
      }
    }
  }
  return true;
}
