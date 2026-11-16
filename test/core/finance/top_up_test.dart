import 'package:test/test.dart';

import 'package:bahonar_nut/core/finance/top_up.dart';

void main() {
  group('the top-up amount', () {
    test('the portal accepts 120,000 Rial and refuses less', () {
      // The bounds were bisected live against the portal on 2026-10-21: the
      // portal accepts 120,000 and refuses 119,999 — and refuses SILENTLY,
      // re-rendering the amount form with no message (F56). So the app is
      // the only place the student can be told.
      expect(const TopUpAmount(119999).isValid, isFalse);
      expect(const TopUpAmount(120000).isValid, isTrue);
    });

    test('the portal accepts 5,000,000 Rial and refuses more', () {
      expect(const TopUpAmount(5000000).isValid, isTrue);
      expect(const TopUpAmount(5000001).isValid, isFalse);
    });

    test('an amount inside the range is accepted', () {
      expect(const TopUpAmount(150000).isValid, isTrue);
      expect(const TopUpAmount(350000).isValid, isTrue);
      expect(const TopUpAmount(1000000).isValid, isTrue);
    });

    test('a non-positive amount is refused', () {
      expect(const TopUpAmount(0).isValid, isFalse);
      expect(const TopUpAmount(-1).isValid, isFalse);
    });

    test('a refused amount says what is wrong, in Persian', () {
      // The portal's own refusal is silent, so this message is the only
      // warning the student gets.
      expect(const TopUpAmount(50000).problem, isNotNull);
      expect(const TopUpAmount(50000).problem, contains('کمترین'));
      expect(const TopUpAmount(6000000).problem, contains('بیشترین'));
      expect(const TopUpAmount(150000).problem, isNull);
    });

    test('the bounds are stated in Toman, the unit the student sees', () {
      // 120,000 Rial is 12,000 Toman. The student never sees Rial.
      expect(const TopUpAmount(119999).problem, contains('۱۲٬۰۰۰'));
    });

    test('the amount converts to Toman', () {
      expect(const TopUpAmount(350000).toman, 35000);
      expect(const TopUpAmount(150000).toman, 15000);
    });
  });

  group('the payment list', () {
    test('the newest payment with the amount is the one that matched', () {
      // The portal's list is newest-first, and two attempts can share an
      // amount — so the newest match is the one the student just made.
      final payments = [
        const TopUpPayment(amountRial: 120000, status: TopUpStatus.paid),
        const TopUpPayment(amountRial: 120000, status: TopUpStatus.failed),
      ];

      final matched = matchTopUpPayment(payments, 120000);
      expect(matched, isNotNull);
      expect(matched!.status, TopUpStatus.paid);
    });

    test('no match when the amount is not in the list', () {
      const payments = [
        TopUpPayment(amountRial: 120000, status: TopUpStatus.paid),
      ];
      expect(matchTopUpPayment(payments, 500000), isNull);
    });

    test('a paid status is a paid status', () {
      expect(TopUpStatus.paid.isPaid, isTrue);
      expect(TopUpStatus.failed.isPaid, isFalse);
      expect(TopUpStatus.pending.isPaid, isFalse);
      expect(TopUpStatus.unknown.isPaid, isFalse);
    });

    test('pending is its own state, not a failure', () {
      // The portal re-queries the bank after the gateway returns, so a
      // payment sits in "pending" for a while. Calling that a failure would
      // tell the student their money was lost when it was not.
      expect(TopUpStatus.pending.isPending, isTrue);
      expect(TopUpStatus.failed.isPending, isFalse);
    });
  });
}
