import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/reminder/reminder.dart';
import 'package:bahonar_nut/core/reminder/reminder_compose.dart';
import 'package:test/test.dart';

/// Tests for the offline reminder composers.
///
/// The reminder reads the LOCAL store, so these compose from plain meal records
/// rather than a live digest. The message is the deliverable, so the exact
/// Persian text is asserted rather than eyeballed.
void main() {
  final sunday = DateTime.utc(2026, 10, 18);
  final monday = DateTime.utc(2026, 10, 19);

  HeldMealDigest meal(
    String account,
    String name,
    DateTime date,
    MealSlot slot, {
    String? dish,
    String? hall = 'مرکزی برادران',
  }) => HeldMealDigest(
    accountId: account,
    displayName: name,
    date: date,
    slot: slot,
    dishName: dish,
    hallName: hall,
  );

  group('the daily reminder', () {
    test('lists each account with its dish and hall', () {
      final text = composeReminderText(
        slot: ReminderSlot.lunch,
        meals: [
          meal('a1', 'مقسمی', sunday, MealSlot.lunch, dish: 'چلو خورشت قیمه'),
          meal('a2', 'حسینی', sunday, MealSlot.lunch, dish: 'زرشک پلو با مرغ'),
        ],
        now: sunday,
      );

      expect(text.title, contains('ناهار'));
      expect(text.body, contains('• مقسمی — چلو خورشت قیمه — مرکزی برادران'));
      expect(text.body, contains('• حسینی — زرشک پلو با مرغ — مرکزی برادران'));
      // 2026-10-18 is 1405/07/26, which the composer renders in Jalali.
      expect(text.body, contains('۲۶ مهر'), reason: 'the date is shown');
    });

    test('the evening slot covers dinner and breakfast together', () {
      final text = composeReminderText(
        slot: ReminderSlot.evening,
        meals: [
          meal(
            'a1',
            'مقسمی',
            sunday,
            MealSlot.dinner,
            dish: 'خوراک سالاد الویه',
          ),
          meal('a1', 'مقسمی', monday, MealSlot.breakfast, dish: 'شیر/حلواشکری'),
        ],
        now: sunday,
      );

      expect(text.body, contains('🌙 شام'));
      expect(text.body, contains('🍳 صبحانه'));
      expect(text.body, contains('خوراک سالاد الویه'));
      expect(text.body, contains('شیر/حلواشکری'));
    });

    test('a meal with no holder is left out entirely', () {
      final text = composeReminderText(
        slot: ReminderSlot.evening,
        meals: [
          meal(
            'a1',
            'مقسمی',
            sunday,
            MealSlot.dinner,
            dish: 'خوراک سالاد الویه',
          ),
        ],
        now: sunday,
      );

      expect(
        text.body,
        isNot(contains('صبحانه')),
        reason: 'a section with nothing in it is omitted, not shown empty',
      );
    });

    test('an account with nothing gets no line', () {
      final text = composeReminderText(
        slot: ReminderSlot.lunch,
        meals: [meal('a1', 'مقسمی', sunday, MealSlot.lunch, dish: 'چلو')],
        now: sunday,
      );
      expect(text.body, isNot(contains('حسینی')));
    });

    test('the hall is omitted when unknown', () {
      final text = composeReminderText(
        slot: ReminderSlot.lunch,
        meals: [
          meal('a1', 'مقسمی', sunday, MealSlot.lunch, dish: 'چلو', hall: null),
        ],
        now: sunday,
      );
      expect(text.body, contains('• مقسمی — چلو'));
      expect(text.body, isNot(contains('مرکزی')));
    });

    test('a meal with no dish falls back to the meal name', () {
      final text = composeReminderText(
        slot: ReminderSlot.lunch,
        meals: [meal('a1', 'مقسمی', sunday, MealSlot.lunch, dish: null)],
        now: sunday,
      );
      expect(text.body, contains('• مقسمی — ناهار'));
    });

    test('the summary counts the meals', () {
      final text = composeReminderText(
        slot: ReminderSlot.lunch,
        meals: [
          meal('a1', 'مقسمی', sunday, MealSlot.lunch),
          meal('a2', 'حسینی', sunday, MealSlot.lunch),
        ],
        now: sunday,
      );
      expect(text.summary, '۲ وعده');
    });

    test('the body is in Persian and uses Persian digits', () {
      final text = composeReminderText(
        slot: ReminderSlot.lunch,
        meals: [meal('a1', 'مقسمی', sunday, MealSlot.lunch, dish: 'چلو')],
        now: sunday,
      );
      expect(text.body, isNot(contains('ریال')));
      expect(
        RegExp(r'[0-9]').hasMatch(text.body),
        isFalse,
        reason: 'the body should use Persian digits: ${text.body}',
      );
    });
  });

  group('the empty-slot message', () {
    test('lunch says no lunch is reserved today', () {
      final text = composeEmptyReminderText(slot: ReminderSlot.lunch);

      expect(text.title, contains('ناهار'));
      expect(text.body, 'امروز هیچ وعده رزروشده‌ای برای ناهار ندارید.');
      expect(text.summary, 'رزروی ثبت نشده');
    });

    test('evening names dinner and tomorrow breakfast', () {
      final text = composeEmptyReminderText(slot: ReminderSlot.evening);

      expect(text.title, contains('شام'));
      expect(
        text.body,
        'امروز هیچ وعده رزروشده‌ای برای شام یا صبحانه فردا ندارید.',
      );
    });

    test('an enabled slot with no meals uses the empty body', () {
      final text = composeReminderText(
        slot: ReminderSlot.lunch,
        meals: const [],
        now: sunday,
      );

      expect(
        text.body,
        composeEmptyReminderText(slot: ReminderSlot.lunch).body,
      );
      expect(text.body, contains('هیچ وعده رزروشده‌ای'));
    });
  });

  group('the next-week nudge', () {
    test('names the accounts that are missing a meal', () {
      final text = composeNudgeText(
        accountNames: ['مقسمی', 'شریفی'],
        now: sunday,
      );

      expect(text.title, contains('هفته آینده'));
      expect(text.body, contains('مقسمی، شریفی'));
      expect(
        text.body,
        contains('۱۷:۰۰'),
        reason: 'the deadline is 17:00 on Thursday',
      );
    });

    test('the summary counts the accounts', () {
      final text = composeNudgeText(accountNames: ['مقسمی'], now: sunday);
      expect(text.summary, '۱ حساب نیازمند بررسی');
    });

    test('an empty list still produces a usable message', () {
      final text = composeNudgeText(accountNames: const [], now: sunday);
      expect(text.body, contains('حساب شما'));
    });
  });
}
