import 'package:bahonar_nut/core/persian.dart';
import 'package:test/test.dart';

void main() {
  group('Jalali -> Gregorian matches the portal', () {
    test('1405/07/26 is 2026-10-18 (the portal\'s own date)', () {
      expect(
        fromJalali(const JalaliDate(1405, 7, 26)),
        DateTime.utc(2026, 10, 18),
      );
    });

    test('1405/07/25 is 2026-10-17', () {
      expect(
        fromJalali(const JalaliDate(1405, 7, 25)),
        DateTime.utc(2026, 10, 17),
      );
    });

    test('1405/08/02 is 2026-10-24 (the next week the portal showed)', () {
      expect(
        fromJalali(const JalaliDate(1405, 8, 2)),
        DateTime.utc(2026, 10, 24),
      );
    });

    test('1405/08/08 is 2026-10-30', () {
      expect(
        fromJalali(const JalaliDate(1405, 8, 8)),
        DateTime.utc(2026, 10, 30),
      );
    });

    test('1405/07/30 is 2026-10-22 and 1405/08/01 is 2026-10-23', () {
      // Mehr has 30 days, so these are consecutive Gregorian days.
      expect(
        fromJalali(const JalaliDate(1405, 7, 30)),
        DateTime.utc(2026, 10, 22),
      );
      expect(
        fromJalali(const JalaliDate(1405, 8, 1)),
        DateTime.utc(2026, 10, 23),
      );
    });
  });

  group('round trip', () {
    test('every day of a year survives toJalali -> fromJalali', () {
      var date = DateTime.utc(2026, 1, 1);
      for (var i = 0; i < 365; i++) {
        final round = fromJalali(toJalali(date));
        expect(round, date, reason: 'round trip failed for $date');
        date = date.add(const Duration(days: 1));
      }
    });

    test('across a leap year too', () {
      var date = DateTime.utc(2028, 1, 1);
      for (var i = 0; i < 366; i++) {
        expect(fromJalali(toJalali(date)), date, reason: 'failed for $date');
        date = date.add(const Duration(days: 1));
      }
    });

    test('across the Jalali new year boundary', () {
      var date = DateTime.utc(2026, 3, 20); // around Nowruz 1405
      for (var i = 0; i < 20; i++) {
        expect(fromJalali(toJalali(date)), date, reason: 'failed for $date');
        date = date.add(const Duration(days: 1));
      }
    });
  });

  group('parseJalaliDate', () {
    test('parses the portal\'s own label format', () {
      expect(
        parseJalaliDate('شنبه 1405/08/02'),
        DateTime.utc(2026, 10, 24),
      );
    });

    test('parses a bare date', () {
      expect(parseJalaliDate('1405/07/26'), DateTime.utc(2026, 10, 18));
    });

    test('parses date with Persian digits', () {
      expect(parseJalaliDate('۱۴۰۵/۰۷/۲۶'), DateTime.utc(2026, 10, 18));
      expect(parseJalaliDate('شنبه ۱۴۰۵/۰۸/۰۲'), DateTime.utc(2026, 10, 24));
    });

    test('returns null for text with no date', () {
      expect(parseJalaliDate('-'), isNull);
      expect(parseJalaliDate(''), isNull);
      expect(parseJalaliDate('مرکزی برادران'), isNull);
    });

    test('returns null for an impossible month', () {
      expect(parseJalaliDate('1405/13/01'), isNull);
    });
  });
}
