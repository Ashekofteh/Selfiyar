/// Which meals the university dining halls actually serve, by weekday.
///
/// Verified against two consecutive weeks of live portal grids (1405/07/25–08/01
/// and 1405/08/02–08/08), which agreed exactly:
///
/// | Weekday   | Breakfast | Lunch | Dinner |
/// |-----------|-----------|-------|--------|
/// | Saturday  |    no     |  yes  |  yes   |
/// | Sunday    |    yes    |  yes  |  yes   |
/// | Monday    |    yes    |  yes  |  yes   |
/// | Tuesday   |    yes    |  yes  |  yes   |
/// | Wednesday |    yes    |  yes  |  yes   |
/// | Thursday  |    yes    |  yes  |   no   |
/// | Friday    |    no     |  no   |   no   |
///
/// **Why Saturday and Friday breakfast are absent** (the pattern is wider than
/// the stated rule, and this is why): breakfast is collected together with the
/// *previous* night's dinner. Friday has no dinner, so Saturday has no breakfast;
/// Thursday has no dinner, so Friday has no breakfast. The rule and the table
/// describe one system.
///
/// **Advisory only.** The portal's own grid is authoritative whenever a read
/// succeeds. This table exists so a 10:30 alarm is not scheduled on a Friday and
/// so a closed slot never produces a reminder. Where they disagree, the portal
/// wins. Two weeks is a strong sample but holidays can perturb it, which is
/// exactly why the calendar never overrides a live read.
library;

import '../meal/models.dart';

/// Days of the week, indexed to match `DateTime.weekday` (Mon=1 .. Sun=7).
enum Weekday {
  monday(DateTime.monday, 'دوشنبه'),
  tuesday(DateTime.tuesday, 'سه‌شنبه'),
  wednesday(DateTime.wednesday, 'چهارشنبه'),
  thursday(DateTime.thursday, 'پنجشنبه'),
  friday(DateTime.friday, 'جمعه'),
  saturday(DateTime.saturday, 'شنبه'),
  sunday(DateTime.sunday, 'یکشنبه');

  const Weekday(this.isoNumber, this.persianName);

  /// Matches `DateTime.weekday`.
  final int isoNumber;

  /// Persian name, as the portal renders it.
  final String persianName;

  static Weekday fromDateTime(DateTime date) => values.firstWhere(
    (d) => d.isoNumber == date.weekday,
    orElse: () => throw ArgumentError('invalid weekday: $date'),
  );
}

/// The weekly serving pattern for the dining halls.
class ServiceCalendar {
  const ServiceCalendar();

  /// Weekdays on which no meal is served at all.
  static const Set<Weekday> closedAllDay = {Weekday.friday};

  /// Meal slots not served on each weekday. Anything absent from this map runs
  /// as normal for that day.
  static const Map<Weekday, Set<MealSlot>> _closedSlots = {
    // Friday: the halls are shut.
    Weekday.friday: {MealSlot.breakfast, MealSlot.lunch, MealSlot.dinner},
    // Thursday: dinner is not served.
    Weekday.thursday: {MealSlot.dinner},
    // Saturday: breakfast would be collected with Friday's dinner, which is not
    // served, so it does not exist.
    Weekday.saturday: {MealSlot.breakfast},
  };

  /// True when [slot] is served on [day].
  bool isServed(Weekday day, MealSlot slot) =>
      !(_closedSlots[day]?.contains(slot) ?? false);

  /// True when nothing at all is served on [day].
  bool isClosedAllDayOn(Weekday day) => closedAllDay.contains(day);

  /// The slots served on [day], in meal order.
  Set<MealSlot> servedSlots(Weekday day) =>
      MealSlot.values.where((s) => isServed(day, s)).toSet();

  /// True when [slot] is served on the weekday of [date].
  bool isServedOn(DateTime date, MealSlot slot) =>
      isServed(Weekday.fromDateTime(date), slot);

  /// True when no meal is served on the weekday of [date].
  bool isClosedOn(DateTime date) =>
      isClosedAllDayOn(Weekday.fromDateTime(date));

  /// The dates among [candidates] on which [slot] is served, in order.
  ///
  /// A date the halls are closed for [slot] is left out, because a hunt
  /// aimed at it has nothing to buy: the market carries no listing for a
  /// meal that is never served. The order of [candidates] is preserved, and
  /// a candidate is compared by its civil date, so a date built in a
  /// different time zone still matches.
  List<DateTime> servableDates(List<DateTime> candidates, MealSlot slot) =>
      candidates.where((d) => isServedOn(d, slot)).toList();
}
