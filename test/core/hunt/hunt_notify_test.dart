import 'package:bahonar_nut/core/hunt/hunt_notify.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:test/test.dart';

void main() {
  group('the success notification', () {
    final notification = composeHuntSuccess(
      slot: MealSlot.lunch,
      date: DateTime.utc(2026, 10, 20),
      dishName: 'چلو اکبرجوجه,دوغ',
      hallName: 'مرکزی برادران',
      priceRial: 500000,
    );

    test('names the meal, the hall and the amount', () {
      expect(notification.body, contains('چلو اکبرجوجه,دوغ'));
      expect(notification.body, contains('مرکزی برادران'));
      expect(notification.body, contains('تومان'));
    });

    test('shows the amount in Toman, never Rial', () {
      // 500,000 Rial is 50,000 Toman. The word "Rial" must never reach the
      // user — the currency guard test enforces this across lib/, and this
      // is the message the guard is protecting.
      expect(notification.body, contains('۵۰٬۰۰۰'));
      expect(notification.body, isNot(contains('ریال')));
    });

    test('names the meal slot in the portal\'s own words', () {
      expect(notification.body, contains('ناهار'));
    });

    test('shows the date in Persian', () {
      expect(notification.body, contains('مهر'));
    });

    test('has a one-line summary for the collapsed shade', () {
      expect(notification.summary, isNotNull);
      expect(notification.summary, contains('ناهار'));
    });

    test('uses no Latin digits', () {
      // A Persian notification with Latin digits in it reads as a bug to the
      // student, and it is the kind of bug nobody reports.
      expect(notification.body, isNot(matches(RegExp(r'[0-9]'))));
      expect(notification.summary, isNot(matches(RegExp(r'[0-9]'))));
    });
  });

  group('the "ended" notification', () {
    test('states the reason plainly', () {
      final notification = composeHuntEnded(
        reason: 'بازه زمانی به پایان رسید.',
      );
      expect(notification.body, contains('بازه زمانی به پایان رسید.'));
      expect(notification.body, contains('بدون خرید'));
    });

    test('says nothing was bought', () {
      // A hunt that found nothing must not read like a failure, and must
      // never read like a purchase.
      final notification = composeHuntEnded(reason: 'چیزی پیدا نشد.');
      expect(notification.body, isNot(contains('خرید موفق')));
    });
  });
}
