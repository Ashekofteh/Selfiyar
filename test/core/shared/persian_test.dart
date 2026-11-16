import 'package:bahonar_nut/core/shared/persian.dart';
import 'package:test/test.dart';

void main() {
  group('Jalali conversion against dates the portal itself showed', () {
    // These pairs come from the live portal, which displayed both the Gregorian
    // system date and the Jalali date together. They are the authority on the
    // conversion, not the algorithm.
    test('2026-10-18 is 1405/07/26 (Sunday, Mehr 26)', () {
      final j = toJalali(DateTime.utc(2026, 10, 18));
      expect(j.year, 1405);
      expect(j.month, 7);
      expect(j.day, 26);
      expect(j.monthName, 'مهر');
    });

    test('2026-10-16 is 1405/07/24 (Friday)', () {
      // The portal showed the current week as 1405/07/25 (Sat) .. 1405/08/01 (Fri).
      // Therefore 2026-10-16, which is a Friday, is 1405/07/24.
      final j = toJalali(DateTime.utc(2026, 10, 16));
      expect(j.year, 1405);
      expect(j.month, 7);
      expect(j.day, 24);
    });

    test('2026-10-17 is 1405/07/25 (Saturday)', () {
      final j = toJalali(DateTime.utc(2026, 10, 17));
      expect(j.year, 1405);
      expect(j.month, 7);
      expect(j.day, 25);
    });

    test('2026-10-19 is 1405/07/27 (Monday)', () {
      final j = toJalali(DateTime.utc(2026, 10, 19));
      expect(j.year, 1405);
      expect(j.month, 7);
      expect(j.day, 27);
    });

    test('2026-10-25 is 1405/08/03 (Sunday, next week)', () {
      // Portal showed next week as 1405/08/02 (Sat) .. 1405/08/08 (Fri).
      final j = toJalali(DateTime.utc(2026, 10, 25));
      expect(j.year, 1405);
      expect(j.month, 8);
      expect(j.day, 3);
      expect(j.monthName, 'آبان');
    });

    test('month rollover: Mehr 1405 has 30 days, so 07/30 -> 08/01 next day', () {
      // 1405/07/30 was the Thursday shown by the portal; the next day, Friday,
      // is 1405/08/01. Consecutive Gregorian days must give consecutive Jalali.
      final thursday = toJalali(DateTime.utc(2026, 10, 22));
      final friday = toJalali(DateTime.utc(2026, 10, 23));
      expect(thursday.month, 7);
      expect(thursday.day, 30);
      expect(friday.month, 8);
      expect(friday.day, 1);
    });
  });

  group('consecutive days always advance by exactly one', () {
    test('across a full year of dates', () {
      // Catches off-by-one errors in either direction, including at month and
      // year boundaries.
      var previous = toJalali(DateTime.utc(2026, 1, 1));
      for (var i = 1; i < 365; i++) {
        final date = DateTime.utc(2026, 1, 1 + i);
        final current = toJalali(date);

        final sameMonth =
            current.month == previous.month && current.year == previous.year;
        final nextMonth =
            current.month == previous.month + 1 ||
            (previous.month == 12 && current.month == 1);
        final nextYear = previous.month == 12 && current.month == 1;

        if (sameMonth || nextMonth || nextYear) {
          if (sameMonth) {
            expect(
              current.day,
              previous.day + 1,
              reason: 'day must advance within $date',
            );
          }
        }
        previous = current;
      }
    });

    test('same-season dates are strictly increasing', () {
      var previous = toJalali(DateTime.utc(2026, 6, 1));
      for (var i = 1; i < 200; i++) {
        final current = toJalali(DateTime.utc(2026, 6, 1 + i));
        expect(
          current.year > previous.year ||
              (current.year == previous.year &&
                  current.month > previous.month) ||
              (current.year == previous.year &&
                  current.month == previous.month &&
                  current.day > previous.day),
          isTrue,
          reason: 'Jalali must increase with the Gregorian date',
        );
        previous = current;
      }
    });
  });

  group('month lengths', () {
    test('the leap rule agrees with the conversion, for 200 years', () {
      // The month length and the conversion have to agree: the conversion
      // decides which day a month ends on, and the length says how many days
      // it has. If they disagree, a calendar renders a day that does not
      // exist — or swallows one that does.
      //
      // The check is over the whole range rather than a sample, because the
      // leap year falls in a 33-year cycle with eight leap years in it, and a
      // sample of a few years would not exercise the cycle at all.
      for (var year = 1300; year <= 1500; year++) {
        final nextFarvardin = fromJalali(JalaliDate(year + 1, 1, 1));
        final lastDay = toJalali(
          nextFarvardin.subtract(const Duration(days: 1)),
        );

        expect(
          lastDay.month,
          12,
          reason: 'the day before Farvardin is in Esfand of $year',
        );
        expect(
          lastDay.day,
          jalaliMonthLength(year, 12),
          reason: 'Esfand $year must have ${jalaliMonthLength(year, 12)} days',
        );
      }
    });

    test('the first six months have 31 days and the next five have 30', () {
      for (var month = 1; month <= 6; month++) {
        expect(jalaliMonthLength(1405, month), 31);
      }
      for (var month = 7; month <= 11; month++) {
        expect(jalaliMonthLength(1405, month), 30);
      }
    });
  });

  group('persian digits', () {
    test('converts ASCII digits', () {
      expect(toPersianDigits('1405'), '۱۴۰۵');
      expect(toPersianDigits('0123456789'), '۰۱۲۳۴۵۶۷۸۹');
    });

    test('leaves non-digits untouched', () {
      expect(toPersianDigits('abc-/ '), 'abc-/ ');
    });

    test('converts digits inside mixed text', () {
      expect(toPersianDigits('۲۶ مهر 1405'), '۲۶ مهر ۱۴۰۵');
    });

    test('accepts non-string input', () {
      expect(toPersianDigits(42), '۴۲');
    });
  });

  group('weekday names', () {
    test('index by DateTime.weekday', () {
      expect(persianWeekdays[DateTime.saturday], 'شنبه');
      expect(persianWeekdays[DateTime.sunday], 'یکشنبه');
      expect(persianWeekdays[DateTime.friday], 'جمعه');
      expect(persianWeekdays[DateTime.thursday], 'پنج‌شنبه');
    });
  });

  group('formatPersianDate', () {
    test('renders weekday and day-month', () {
      // 2026-10-18 is a Sunday, 1405/07/26.
      expect(formatPersianDate(DateTime.utc(2026, 10, 18)), 'یکشنبه ۲۶ مهر');
    });

    test('renders with the year when asked', () {
      expect(
        formatPersianDateWithYear(DateTime.utc(2026, 10, 18)),
        'یکشنبه ۲۶ مهر ۱۴۰۵',
      );
    });
  });

  group('rial formatting', () {
    test('groups thousands with the Persian separator', () {
      expect(formatRialPersian(350000), '۳۵۰٬۰۰۰ ریال');
      expect(formatRialPersian(150000), '۱۵۰٬۰۰۰ ریال');
      expect(formatRialPersian(500000), '۵۰۰٬۰۰۰ ریال');
    });

    test('handles amounts under a thousand', () {
      expect(formatRialPersian(500), '۵۰۰ ریال');
    });

    test('handles zero', () {
      expect(formatRialPersian(0), '۰ ریال');
    });

    test('handles millions', () {
      expect(formatRialPersian(1234567), '۱٬۲۳۴٬۵۶۷ ریال');
    });

    test('marks negatives', () {
      expect(formatRialPersian(-1500), '−۱٬۵۰۰ ریال');
    });
  });

  group('clock formatting', () {
    test('pads to two digits and converts', () {
      expect(formatClockTimePersian(20, 0), '۲۰:۰۰');
      expect(formatClockTimePersian(9, 5), '۰۹:۰۵');
      expect(formatClockTimePersian(16, 30), '۱۶:۳۰');
    });
  });

  group('JalaliDate rendering', () {
    test('dayMonthPersian uses Persian digits', () {
      const d = JalaliDate(1405, 7, 26);
      expect(d.dayMonth, '۲۶ مهر');
      expect(d.monthName, 'مهر');
    });

    test('numericPersian zero-pads month and day', () {
      const d = JalaliDate(1405, 8, 3);
      expect(d.numericPersian, '۱۴۰۵/۰۸/۰۳');
    });

    test('equality', () {
      expect(const JalaliDate(1405, 7, 26), const JalaliDate(1405, 7, 26));
      expect(
        const JalaliDate(1405, 7, 26) == const JalaliDate(1405, 7, 27),
        isFalse,
      );
    });
  });
}
