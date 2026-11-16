import 'package:bahonar_nut/core/shared/persian.dart';
import 'package:test/test.dart';

void main() {
  group('rial to toman', () {
    test('divides by ten', () {
      expect(rialToToman(350000), 35000);
      expect(rialToToman(150000), 15000);
      expect(rialToToman(500000), 50000);
      expect(rialToToman(1000000), 100000);
    });

    test('every real portal price converts exactly', () {
      // The prices observed on the live portal, all multiples of 10 Rial.
      for (final rial in [150000, 350000, 500000, 225000, 1000000, 0]) {
        expect(rial % 10, 0);
        expect(rialToToman(rial) * 10, rial,
            reason: '$rial Rial must convert without loss');
      }
    });

    test('rounds half up when there is a remainder', () {
      expect(rialToToman(5), 1); // 0.5 -> 1
      expect(rialToToman(4), 0); // 0.4 -> 0
      expect(rialToToman(15), 2); // 1.5 -> 2
      expect(rialToToman(14), 1); // 1.4 -> 1
    });

    test('handles zero and negatives', () {
      expect(rialToToman(0), 0);
      expect(rialToToman(-350000), -35000);
      expect(rialToToman(-5), -1, reason: 'rounds away from zero, half up');
    });
  });

  group('toman to rial', () {
    test('multiplies by ten', () {
      expect(tomanToRial(35000), 350000);
      expect(tomanToRial(0), 0);
    });

    test('round-trips a portal price', () {
      for (final rial in [150000, 350000, 500000, 1000000]) {
        expect(tomanToRial(rialToToman(rial)), rial);
      }
    });
  });

  group('formatting for display', () {
    test('formats a Toman amount with Persian digits and separator', () {
      expect(formatTomanPersian(350000), '۳۵٬۰۰۰ تومان');
      expect(formatTomanPersian(150000), '۱۵٬۰۰۰ تومان');
      expect(formatTomanPersian(500000), '۵۰٬۰۰۰ تومان');
      expect(formatTomanPersian(1000000), '۱۰۰٬۰۰۰ تومان');
    });

    test('formats a Toman amount under a thousand without a separator', () {
      expect(formatTomanPersian(5000), '۵۰۰ تومان');
    });

    test('formats zero', () {
      expect(formatTomanPersian(0), '۰ تومان');
    });

    test('formats a negative amount with a minus sign', () {
      expect(formatTomanPersian(-15000), '−۱٬۵۰۰ تومان');
    });

    test('the unit word is Toman, never Rial', () {
      expect(formatTomanPersian(350000), contains('تومان'));
      expect(formatTomanPersian(350000), isNot(contains('ریال')));
    });

    test('a Rial amount formats to ten times the Toman figure', () {
      // The Rial formatter is retained for the rare case it is needed, and it
      // must not be mistaken for the display formatter.
      expect(formatRialPersian(350000), '۳۵۰٬۰۰۰ ریال');
      expect(formatTomanPersian(350000), '۳۵٬۰۰۰ تومان');
    });
  });
}
