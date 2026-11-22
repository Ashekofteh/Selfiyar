import 'package:bahonar_nut/transport/html_parsing.dart';
import 'package:test/test.dart';

/// The price of a dish is read out of the option's text.
///
/// The portal writes a dish as `تخم مرغ2عدد/نان/چای/قند 150000 ریال` — a
/// name that carries a digit of its own, then the price, then the currency
/// word. Reading every digit in the string made that dish cost 2,150,000 Rial
/// instead of 150,000: a fourteen-fold overcharge in the price the app shows,
/// and in the price the hunt's credit check and price cap compare against.
void main() {
  group('parseRial', () {
    test('reads the amount before the currency word', () {
      expect(parseRial('225,000 ریال'), 225000);
      expect(parseRial('150000 ریال'), 150000);
      expect(parseRial('500000 ریال'), 500000);
    });

    test('ignores the digits in the dish name', () {
      // Verified live against the portal on 2026-10-20: the option's text is
      // exactly this, and the price is 150,000 Rial — the "2" belongs to
      // "تخم مرغ2عدد" and is part of the name.
      expect(parseRial('تخم مرغ2عدد/نان/چای/قند 150000 ریال'), 150000);
      expect(parseRial('تخم مرغ2عدد/نان/چای/قند 150000 ریال'), isNot(2215000));
    });

    test('reads the last number when the currency word is absent', () {
      expect(parseRial('150000'), 150000);
      expect(parseRial('تخم مرغ2عدد 150000'), 150000);
    });

    test('reads a Persian-digit amount', () {
      expect(parseRial('۱۵۰۰۰۰ ریال'), 150000);
      expect(parseRial('۲۲۵,۰۰۰ ریال'), 225000);
    });

    test('keeps a leading minus as a negative amount', () {
      // An overdrawn account is shown with a minus. Dropping it would turn a
      // debt into a positive balance — and a booking the account cannot pay
      // for would be approved.
      expect(parseRial('-50,000 ریال'), -50000);
      expect(parseRial('−50,000 ریال'), -50000);
      expect(parseRial('-۱۵۰۰۰۰ ریال'), -150000);
      expect(parseRial('-150000'), -150000);
    });

    test('returns null when there is no amount', () {
      expect(parseRial(''), isNull);
      expect(parseRial('ریال'), isNull);
      expect(parseRial('بدون قیمت'), isNull);
    });
  });
}
