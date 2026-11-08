/// Persian (Jalali) calendar and digit formatting.
///
/// Pure Dart, no dependencies. Kept separate from the composer so the calendar
/// conversion can be tested directly against known portal dates — the portal is
/// the authority on what "26 مهر 1405" means, and the conversion is verified
/// against it (`persian_test.dart`).
library;

/// Persian month names, indexed 1..12.
const List<String> persianMonths = [
  '',
  'فروردین',
  'اردیبهشت',
  'خرداد',
  'تیر',
  'مرداد',
  'شهریور',
  'مهر',
  'آبان',
  'آذر',
  'دی',
  'بهمن',
  'اسفند',
];

/// Persian weekday names, indexed by `DateTime.weekday` (Mon=1 .. Sun=7).
const List<String> persianWeekdays = [
  '',
  'دوشنبه',
  'سه‌شنبه',
  'چهارشنبه',
  'پنج‌شنبه',
  'جمعه',
  'شنبه',
  'یکشنبه',
];

/// A civil date in the Jalali calendar.
class JalaliDate {
  const JalaliDate(this.year, this.month, this.day);

  final int year;
  final int month;
  final int day;

  String get monthName => persianMonths[month];

  /// e.g. `26 مهر`
  String get dayMonthPersian => '${toPersianDigits(day)} $monthName';

  /// e.g. `۲۶ مهر`
  String get dayMonth => '${toPersianDigits(day)} $monthName';

  /// e.g. `1405/07/26`
  String get numericPersian => '${toPersianDigits(year)}/'
      '${toPersianDigits(month).padLeft(2, '۰')}/'
      '${toPersianDigits(day).padLeft(2, '۰')}';

  @override
  String toString() => '$year/$month/$day';

  @override
  bool operator ==(Object other) =>
      other is JalaliDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);
}

/// Converts a Gregorian civil date to Jalali.
///
/// Standard algorithm (Borkowski / the widely used `jalaali-js` form), accurate
/// across the range this app cares about. The Gregorian input's time component
/// and timezone are ignored; only the civil date matters.
JalaliDate toJalali(DateTime gregorian) {
  const gDaysInMonth = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];

  final gy = gregorian.year;
  final gm = gregorian.month;
  final gd = gregorian.day;

  final gy2 = gm > 2 ? gy + 1 : gy;

  var days = 355666 +
      (365 * gy) +
      ((gy2 + 3) ~/ 4) -
      ((gy2 + 99) ~/ 100) +
      ((gy2 + 399) ~/ 400) +
      gd +
      gDaysInMonth[gm - 1];

  var jy = -1595 + (33 * (days ~/ 12053));
  days %= 12053;
  jy += 4 * (days ~/ 1461);
  days %= 1461;

  if (days > 365) {
    jy += (days - 1) ~/ 365;
    days = (days - 1) % 365;
  }

  final int jm;
  final int jd;
  if (days < 186) {
    jm = 1 + (days ~/ 31);
    jd = 1 + (days % 31);
  } else {
    jm = 7 + ((days - 186) ~/ 30);
    jd = 1 + ((days - 186) % 30);
  }

  return JalaliDate(jy, jm, jd);
}

/// Converts a Jalali civil date to Gregorian.
///
/// The inverse of [toJalali], and needed because the portal's grids label rows
/// in Jalali (`شنبه 1405/08/02`) while the app reasons in Gregorian civil
/// dates. The conversion is exact: 1405/07/26 is 2026-10-18.
///
/// Implemented as a bounded search over the *verified* [toJalali] rather than
/// as a second hand-written algorithm. Two independent date algorithms is two
/// chances to be wrong; and when the first attempt at the inverse was written
/// it was wrong — it returned July instead of October — while [toJalali] had
/// already been checked against the portal's own dates. Deriving the inverse
/// from the verified forward function makes the pair correct by construction,
/// and the search is over a window of a few hundred days, so it is cheap.
DateTime fromJalali(JalaliDate jalali) {
  // The Jalali year runs March-to-March, so a Jalali year maps to the Gregorian
  // year that is 621 greater (1405 -> 2026). Searching the whole of that
  // Gregorian year plus the next is ample.
  final approximateYear = jalali.year + 621;
  final start = DateTime.utc(approximateYear, 1, 1);
  final end = DateTime.utc(approximateYear + 2, 1, 1);

  var candidate = start;
  while (candidate.isBefore(end)) {
    if (toJalali(candidate) == jalali) return candidate;
    candidate = candidate.add(const Duration(days: 1));
  }

  throw ArgumentError(
    'no Gregorian date maps to Jalali ${jalali.year}/${jalali.month}/${jalali.day}',
  );
}

/// The number of days in a Jalali month.
///
/// The first six months have 31 days, the next five have 30, and Esfand has
/// 29 — 30 in a leap year.
int jalaliMonthLength(int year, int month) {
  if (month <= 6) return 31;
  if (month <= 11) return 30;
  return isJalaliLeapYear(year) ? 30 : 29;
}

/// The years, modulo 33, that are leap years.
///
/// The Jalali calendar's leap year falls in a 33-year cycle, of which eight
/// years are leap. A year is one of them when its remainder modulo 33 is in
/// this set.
///
/// The set is not a simple arithmetic progression: the cycle skips a year at
/// two points, which is why the rule is a list rather than a formula.
const Set<int> _jalaliLeapRemainders = {1, 5, 9, 13, 17, 22, 26, 30};

/// Whether a Jalali year is a leap year.
///
/// Verified against [toJalali] across 1300..1500 — see
/// `persian_test.dart`. The rule and the conversion have to agree, because
/// the conversion decides which day a month ends on.
bool isJalaliLeapYear(int year) =>
    _jalaliLeapRemainders.contains(year % 33);

/// Parses a Jalali date in the portal's `yyyy/MM/dd` form.
///
/// Returns null for anything that is not a Jalali date, so a caller never
/// mistakes an unparsed label for the epoch.
DateTime? parseJalaliDate(String text) {
  final match = RegExp(r'(\d{1,4})\s*[/\\-]\s*(\d{1,2})\s*[/\\-]\s*(\d{1,2})')
      .firstMatch(text);
  if (match == null) return null;

  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;

  return fromJalali(JalaliDate(year, month, day));
}

/// Formats a Gregorian date as e.g. `یکشنبه ۲۶ مهر`.
String formatPersianDate(DateTime date) {
  final jalali = toJalali(date);
  return '${persianWeekdays[date.weekday]} ${jalali.dayMonth}';
}

/// Formats a Gregorian date as e.g. `یکشنبه ۲۶ مهر ۱۴۰۵`.
String formatPersianDateWithYear(DateTime date) {
  final jalali = toJalali(date);
  return '${persianWeekdays[date.weekday]} ${jalali.dayMonth} '
      '${toPersianDigits(jalali.year)}';
}

/// Converts ASCII digits in [input] to Persian digits, leaving other characters
/// untouched.
///
/// Used for user-facing text only. Identifiers, prices sent over the wire and
/// anything compared programmatically keep ASCII digits — mixing the two is a
/// classic and painful bug class.
String toPersianDigits(Object input) {
  const western = '0123456789';
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  final text = input.toString();
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    final index = western.indexOf(char);
    buffer.write(index >= 0 ? persian[index] : char);
  }
  return buffer.toString();
}

/// Converts Persian digits to Western ones.
///
/// The counterpart of [toPersianDigits], for the other direction: a number
/// the student **typed** arrives as Persian digits, and it has to become a
/// Western number before it can be parsed or sent to the portal.
///
/// Only the digits are converted. Separators are the caller's business,
/// because a Persian amount may be written with thousands separators and the
/// caller knows whether it is reading one.
String toEnglishDigits(String input) {
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    final char = String.fromCharCode(rune);
    final pIdx = persian.indexOf(char);
    if (pIdx >= 0) {
      buffer.write('$pIdx');
      continue;
    }
    final aIdx = arabic.indexOf(char);
    if (aIdx >= 0) {
      buffer.write('$aIdx');
      continue;
    }
    buffer.write(char);
  }
  return buffer.toString();
}

/// Keeps only the digits in [input], in either script, as Western digits.
///
/// ## Why the Persian digits are kept
///
/// A student types on a Persian keyboard, so the digits arrive as Persian
/// ones — and a field that accepts only Western digits **silently refuses
/// the input**. The student types four digits and nothing appears, which
/// looks exactly like a frozen app.
///
/// So the field accepts both, and the conversion happens here — at the edge,
/// where the portal's answer is posted.
String digitsOnly(String input) {
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    final char = String.fromCharCode(rune);
    final pIdx = persian.indexOf(char);
    if (pIdx >= 0) {
      buffer.write('$pIdx');
    } else {
      final aIdx = arabic.indexOf(char);
      if (aIdx >= 0) {
        buffer.write('$aIdx');
      } else if (char.codeUnitAt(0) >= 0x30 && char.codeUnitAt(0) <= 0x39) {
        buffer.write(char);
      }
    }
  }
  return buffer.toString();
}

/// Formats a Rial amount for display, e.g. `۳۵۰٬۰۰۰ ریال`.
///
/// **This is for the rare case that Rial must be shown.** Iran has not used
/// Rial in daily life for a long time; everything the user sees should be in
/// Toman. Use [formatTomanPersian] for that. Kept because the portal's own
/// figures are denominated in Rial, and a debug view may need to quote them
/// verbatim.
String formatRialPersian(int amountRial) =>
    '${_groupDigits(amountRial)} ریال';

/// Formats a **Toman** amount for display, e.g. `۳۵٬۰۰۰ تومان`.
///
/// ## The unit
///
/// 1 Toman = 10 Rial, so Toman = Rial / 10. The portal's prices are all exact
/// multiples of 10 Rial (150,000 / 350,000 / 500,000), so a meal price converts
/// without a remainder. Rial amounts that are *not* multiples of 10 would round,
/// so this rounds **half up** and the caller is told the rounded value.
///
/// ## Why the conversion lives at the display boundary
///
/// The domain, the adapter and the stored data all stay in Rial, because that
/// is the portal's own unit and every comparison — the price cap, the balance
/// check, the spend summary — must be exact. Converting once, at the edge, is
/// the only place a rounding error can occur, and it cannot corrupt a
/// comparison. The alternative, storing Toman, would mean dividing every portal
/// figure on the way in and risking a mismatch against the server's own
/// arithmetic.
String formatTomanPersian(int amountRial) {
  final toman = rialToToman(amountRial);
  return '${_groupDigits(toman)} تومان';
}

/// Converts Rial to Toman, rounding half up.
///
/// Rial amounts that are not a multiple of 10 lose up to 0.5 Toman. Meal prices
/// and balances are always multiples of 10, so this is exact for every real
/// value the app handles.
int rialToToman(int amountRial) {
  final negative = amountRial < 0;
  final magnitude = amountRial.abs();
  // Half up: (magnitude + 5) ~/ 10 rounds .5 upwards.
  final toman = (magnitude + 5) ~/ 10;
  return negative ? -toman : toman;
}

/// Converts Toman to Rial, for the rare case a Toman figure must be sent back.
int tomanToRial(int amountToman) => amountToman * 10;

/// Groups an integer's digits with the Persian thousands separator.
String _groupDigits(int amount) {
  final digits = amount.abs().toString();
  final grouped = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) grouped.write('٬');
    grouped.write(digits[i]);
  }
  final sign = amount < 0 ? '−' : '';
  return '$sign${toPersianDigits(grouped.toString())}';
}

/// A clock time rendered in Persian, e.g. `۲۰:۰۰`.
String formatClockTimePersian(int hour, int minute) {
  final h = toPersianDigits(hour.toString().padLeft(2, '0'));
  final m = toPersianDigits(minute.toString().padLeft(2, '0'));
  return '$h:$m';
}

/// In the Iranian academic calendar, the dining week runs Saturday (شنبه) through
/// Friday (جمعه). Hours, minutes, and seconds are normalized to 00:00:00 UTC.
DateTime weekStartSaturday(DateTime date) {
  final utc = DateTime.utc(date.year, date.month, date.day);
  final daysSinceSaturday = (utc.weekday % 7); // Sat: 6 % 7 = 6, Sun: 7 % 7 = 0, Mon: 1, ..., Fri: 5
  final diff = (utc.weekday == DateTime.saturday) ? 0 : (daysSinceSaturday + 1);
  return utc.subtract(Duration(days: diff));
}

/// The Friday that ends the Iranian dining week starting at [saturday].
DateTime weekEndFriday(DateTime saturday) =>
    DateTime.utc(saturday.year, saturday.month, saturday.day + 6);

/// Persian title for a relative week offset from current week (0 = current).
String formatWeekTitle(int weekOffset) {
  if (weekOffset == 0) return 'هفته جاری';
  if (weekOffset == 1) return 'هفته بعد';
  if (weekOffset == -1) return 'هفته قبل';
  if (weekOffset > 1) return '${toPersianDigits(weekOffset)} هفته بعد';
  return '${toPersianDigits(weekOffset.abs())} هفته قبل';
}

/// Formats the Jalali date range for the week starting on [saturday],
/// e.g. `۲۵ مهر الی ۱ آبان ۱۴۰۵`.
String formatWeekRange(DateTime saturday) {
  final friday = weekEndFriday(saturday);
  final jSat = toJalali(saturday);
  final jFri = toJalali(friday);

  if (jSat.year == jFri.year) {
    if (jSat.month == jFri.month) {
      return '${toPersianDigits(jSat.day)} الی ${toPersianDigits(jFri.day)} ${jSat.monthName} ${toPersianDigits(jSat.year)}';
    }
    return '${toPersianDigits(jSat.day)} ${jSat.monthName} الی ${toPersianDigits(jFri.day)} ${jFri.monthName} ${toPersianDigits(jSat.year)}';
  }
  return '${toPersianDigits(jSat.day)} ${jSat.monthName} ${toPersianDigits(jSat.year)} الی ${toPersianDigits(jFri.day)} ${jFri.monthName} ${toPersianDigits(jFri.year)}';
}

/// Persian title for a relative month offset from current month (0 = current).
String formatMonthTitle(int monthOffset) {
  if (monthOffset == 0) return 'ماه جاری';
  if (monthOffset == 1) return 'ماه بعد';
  if (monthOffset == -1) return 'ماه قبل';
  if (monthOffset > 1) return '${toPersianDigits(monthOffset)} ماه بعد';
  return '${toPersianDigits(monthOffset.abs())} ماه قبل';
}

/// Formats a Jalali month and year, e.g. `آبان ۱۴۰۵`.
String formatJalaliMonthName(int year, int month) =>
    '${persianMonths[month]} ${toPersianDigits(year)}';
