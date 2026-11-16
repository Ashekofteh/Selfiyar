import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/shared/next_week.dart';
import 'package:bahonar_nut/core/reminder/reminder.dart';
import 'package:bahonar_nut/core/reminder/reminder_compose.dart';
import 'package:test/test.dart';

ReservedMealItem item({
  required MealSlot slot,
  required String dish,
  String hall = 'مرکزی برادران',
  DateTime? date,
  int price = 350000,
}) => ReservedMealItem(
  date: date ?? DateTime.utc(2026, 10, 18),
  slot: slot,
  hallName: hall,
  dishName: dish,
  priceRial: price,
);

AccountDigest account(String id, String name, List<ReservedMealItem> items) =>
    AccountDigest(accountId: id, displayName: name, items: items);

void main() {
  final sunday = DateTime.utc(2026, 10, 18); // 1405/07/26
  final monday = DateTime.utc(2026, 10, 19); // 1405/07/27

  group('evening digest (dinner + tomorrow breakfast)', () {
    test('renders both sections with dishes and halls', () {
      final digest = ReminderDigest(
        slot: ReminderSlot.evening,
        generatedAt: sunday,
        accounts: [
          account('a1', 'مقسمی', [
            item(
              slot: MealSlot.dinner,
              dish: 'خوراک تن ماهی، لیمو ترش',
              date: sunday,
            ),
            item(
              slot: MealSlot.breakfast,
              dish: 'شیر/حلواشکری/نان/چای/قند',
              date: monday,
              price: 150000,
            ),
          ]),
        ],
      );

      final text = composeNotification(digest);

      expect(text.title, '🌙 یادآوری شام امروز');
      expect(text.body, contains('🌙 شام (یکشنبه ۲۶ مهر):'));
      expect(
        text.body,
        contains('• مقسمی — خوراک تن ماهی، لیمو ترش — مرکزی برادران'),
      );
      expect(text.body, contains('🍳 صبحانه فردا (دوشنبه ۲۷ مهر)'));
      expect(text.body, contains('• مقسمی — شیر/حلواشکری/نان/چای/قند'));
    });

    test('breakfast section notes it is collected with dinner', () {
      final digest = ReminderDigest(
        slot: ReminderSlot.evening,
        generatedAt: sunday,
        accounts: [
          account('a1', 'مقسمی', [
            item(slot: MealSlot.breakfast, dish: 'شیر/حلواشکری', date: monday),
          ]),
        ],
      );
      expect(
        composeNotification(digest).body,
        contains('همراه شام امروز تحویل می‌گیرید'),
      );
    });

    test('omits dinner section entirely when nobody holds dinner', () {
      final digest = ReminderDigest(
        slot: ReminderSlot.evening,
        generatedAt: sunday,
        accounts: [
          account('a1', 'مقسمی', [
            item(slot: MealSlot.breakfast, dish: 'شیر/حلواشکری', date: monday),
          ]),
        ],
      );
      final body = composeNotification(digest).body;
      expect(body, isNot(contains('شام (')));
      expect(body, contains('صبحانه فردا'));
    });

    test('lists only accounts holding the meal, per the agreed semantics', () {
      final digest = ReminderDigest(
        slot: ReminderSlot.evening,
        generatedAt: sunday,
        accounts: [
          account('a1', 'مقسمی', [
            item(slot: MealSlot.dinner, dish: 'خوراک تن ماهی', date: sunday),
          ]),
          account('a2', 'حسینی', [
            item(slot: MealSlot.breakfast, dish: 'شیر/حلواشکری', date: monday),
          ]),
        ],
      );
      final body = composeNotification(digest).body;

      // مقسمی appears under dinner, حسینی under breakfast.
      expect(body, contains('• مقسمی — خوراک تن ماهی'));
      expect(body, contains('• حسینی — شیر/حلواشکری'));
    });

    test('multiple accounts under one meal all appear', () {
      final digest = ReminderDigest(
        slot: ReminderSlot.evening,
        generatedAt: sunday,
        accounts: [
          account('a1', 'مقسمی', [
            item(slot: MealSlot.breakfast, dish: 'شیر/حلواشکری', date: monday),
          ]),
          account('a2', 'حسینی', [
            item(slot: MealSlot.breakfast, dish: 'شیر/حلواشکری', date: monday),
          ]),
          account('a3', 'شریفی', [
            item(slot: MealSlot.breakfast, dish: 'شیر/حلواشکری', date: monday),
          ]),
        ],
      );
      final body = composeNotification(digest).body;
      expect(body, contains('• مقسمی —'));
      expect(body, contains('• حسینی —'));
      expect(body, contains('• شریفی —'));
    });
  });

  group('lunch digest', () {
    test('renders the lunch section with the hall', () {
      final digest = ReminderDigest(
        slot: ReminderSlot.lunch,
        generatedAt: sunday,
        accounts: [
          account('a1', 'حسینی', [
            item(
              slot: MealSlot.lunch,
              dish: 'زرشک پلو با مرغ، سس مرغ، ماست',
              price: 500000,
            ),
          ]),
        ],
      );
      final text = composeNotification(digest);
      expect(text.title, '🍽 یادآوری ناهار امروز');
      expect(text.body, contains('🍽 ناهار (یکشنبه ۲۶ مهر):'));
      expect(
        text.body,
        contains('• حسینی — زرشک پلو با مرغ، سس مرغ، ماست — مرکزی برادران'),
      );
    });
  });

  group('empty and partial states', () {
    test('says so explicitly when nothing is reserved', () {
      final digest = ReminderDigest(
        slot: ReminderSlot.lunch,
        generatedAt: sunday,
        accounts: [account('a1', 'مقسمی', const [])],
      );
      expect(
        composeNotification(digest).body,
        contains('امروز هیچ وعده رزروشده‌ای ندارید'),
      );
    });

    test('says so when there are no accounts at all', () {
      final digest = ReminderDigest(
        slot: ReminderSlot.lunch,
        generatedAt: sunday,
        accounts: const [],
      );
      expect(
        composeNotification(digest).body,
        contains('امروز هیچ وعده رزروشده‌ای ندارید'),
      );
    });

    test(
      'NAMES accounts that could not be checked (never silently dropped)',
      () {
        final digest = ReminderDigest(
          slot: ReminderSlot.evening,
          generatedAt: sunday,
          accounts: [
            account('a1', 'مقسمی', [
              item(slot: MealSlot.dinner, dish: 'خوراک تن ماهی', date: sunday),
            ]),
          ],
          failures: const [
            ReminderFailure(
              accountId: 'a3',
              displayName: 'شریفی',
              cause: ReminderFailureCause.authFailed,
            ),
          ],
        );

        final body = composeNotification(digest).body;
        // The reserved meal is still reported...
        expect(body, contains('• مقسمی — خوراک تن ماهی'));
        // ...and the unchecked account is visible.
        expect(body, contains('⚠️ بررسی نشد: شریفی'));
      },
    );

    test('lists several failures together', () {
      final digest = ReminderDigest(
        slot: ReminderSlot.lunch,
        generatedAt: sunday,
        accounts: const [],
        failures: const [
          ReminderFailure(
            accountId: 'a2',
            displayName: 'حسینی',
            cause: ReminderFailureCause.sessionExpired,
          ),
          ReminderFailure(
            accountId: 'a3',
            displayName: 'شریفی',
            cause: ReminderFailureCause.readFailed,
          ),
        ],
      );
      expect(
        composeNotification(digest).body,
        contains('⚠️ بررسی نشد: حسینی، شریفی'),
      );
    });

    test('an empty digest with failures still names them', () {
      final digest = ReminderDigest(
        slot: ReminderSlot.lunch,
        generatedAt: sunday,
        accounts: const [],
        failures: const [
          ReminderFailure(
            accountId: 'a1',
            displayName: 'مقسمی',
            cause: ReminderFailureCause.authFailed,
          ),
        ],
      );
      final body = composeNotification(digest).body;
      expect(body, contains('هیچ وعده رزروشده‌ای ندارید'));
      expect(body, contains('⚠️ بررسی نشد: مقسمی'));
    });
  });

  group('summary line', () {
    test('counts reserved items', () {
      final digest = ReminderDigest(
        slot: ReminderSlot.evening,
        generatedAt: sunday,
        accounts: [
          account('a1', 'مقسمی', [
            item(slot: MealSlot.dinner, dish: 'd', date: sunday),
            item(slot: MealSlot.breakfast, dish: 'b', date: monday),
          ]),
        ],
      );
      expect(composeNotification(digest).summary, '۲ وعده رزرو شده');
    });

    test('reports none when empty', () {
      final digest = ReminderDigest(
        slot: ReminderSlot.lunch,
        generatedAt: sunday,
        accounts: const [],
      );
      expect(composeNotification(digest).summary, 'رزروی ثبت نشده');
    });
  });

  group('next-week nudge', () {
    NextWeekStatus statusWith(List<BookingGap> gaps) => NextWeekStatus(
      weekStart: DateTime.utc(2026, 10, 24), // Saturday 1405/08/02
      weekEnd: DateTime.utc(2026, 10, 30), // Friday 1405/08/08
      deadline: DateTime.utc(2026, 10, 22, 16, 30), // Thu 20:00 local
      gaps: gaps,
      accountCount: 1,
    );

    test('renders the week range and the deadline', () {
      final text = composeNudgeNotification(
        statusWith([
          BookingGap(
            date: DateTime.utc(2026, 10, 24),
            slot: MealSlot.lunch,
            missingAccountIds: const ['a1'],
            totalAccounts: 1,
          ),
        ]),
      );

      expect(text.title, '📅 یادآوری رزرو هفته آینده');
      expect(text.body, contains('هنوز برای هفته آینده رزرو نکرده‌اید'));
      // 2026-10-24 is 1405/08/02 (Aban), not Mehr — Mehr ends on 07/30.
      expect(text.body, contains('۲ آبان تا ۸ آبان'));
      expect(text.body, contains('مهلت اولین وعده'));
      expect(text.body, contains('۲۰:۰۰'));
    });

    test('lists a gap with the Persian date and meal name', () {
      final text = composeNudgeNotification(
        statusWith([
          BookingGap(
            date: DateTime.utc(2026, 10, 24),
            slot: MealSlot.lunch,
            missingAccountIds: const ['a1'],
            totalAccounts: 1,
          ),
        ]),
      );
      expect(text.body, contains('• ۲ آبان — ناهار: رزرو نشده'));
    });

    test('truncates at five gaps and counts the rest', () {
      final gaps = List.generate(
        8,
        (i) => BookingGap(
          date: DateTime.utc(2026, 10, 24 + i),
          slot: MealSlot.lunch,
          missingAccountIds: const ['a1'],
          totalAccounts: 1,
        ),
      );
      final text = composeNudgeNotification(statusWith(gaps));

      // Five bullet lines, then the remainder.
      final bullets = text.body
          .split('\n')
          .where((l) => l.startsWith('• '))
          .length;
      expect(bullets, maxGapsListed);
      expect(text.body, contains('و ۳ وعده دیگر'));
    });

    test('does not truncate below the limit', () {
      final gaps = List.generate(
        3,
        (i) => BookingGap(
          date: DateTime.utc(2026, 10, 24 + i),
          slot: MealSlot.lunch,
          missingAccountIds: const ['a1'],
          totalAccounts: 1,
        ),
      );
      final text = composeNudgeNotification(statusWith(gaps));
      expect(text.body, isNot(contains('وعده دیگر')));
    });

    test('appends failures so a nudge never implies false completeness', () {
      final status = NextWeekStatus(
        weekStart: DateTime.utc(2026, 10, 24),
        weekEnd: DateTime.utc(2026, 10, 30),
        deadline: DateTime.utc(2026, 10, 22, 16, 30),
        gaps: [
          BookingGap(
            date: DateTime.utc(2026, 10, 24),
            slot: MealSlot.lunch,
            missingAccountIds: const ['a1'],
            totalAccounts: 2,
          ),
        ],
        failures: const [
          ReminderFailure(
            accountId: 'a2',
            displayName: 'شریفی',
            cause: ReminderFailureCause.authFailed,
          ),
        ],
        accountCount: 2,
      );
      expect(
        composeNudgeNotification(status).body,
        contains('⚠️ بررسی نشد: شریفی'),
      );
    });

    test('summary states how many meals are unbooked', () {
      final gaps = List.generate(
        4,
        (i) => BookingGap(
          date: DateTime.utc(2026, 10, 24 + i),
          slot: MealSlot.lunch,
          missingAccountIds: const ['a1'],
          totalAccounts: 1,
        ),
      );
      expect(
        composeNudgeNotification(statusWith(gaps)).summary,
        '۴ وعده رزرو نشده است',
      );
    });
  });

  group('failure notification', () {
    test('explains that the reminder did not run', () {
      final text = composeFailureNotification(
        slot: ReminderSlot.lunch,
        reason: 'اتصال به سرور برقرار نشد.',
      );
      expect(text.title, '⚠️ یادآوری انجام نشد');
      expect(text.body, contains('اتصال به سرور برقرار نشد.'));
    });
  });

  group('formatMultiAccountNotification', () {
    test('formats single account notification correctly', () {
      final meals = [
        HeldMealDigest(
          accountId: 'a1',
          displayName: 'حسینی',
          dishName: 'اکبر جوجه با برنج',
          date: sunday,
          slot: MealSlot.lunch,
        ),
      ];
      final text = formatMultiAccountNotification(meals);
      expect(text, 'با اکانت حسینی غذای اکبر جوجه با برنج را رزرو داری');
    });

    test(
      'formats multi-account notification correctly separated by hyphen',
      () {
        final meals = [
          HeldMealDigest(
            accountId: 'a1',
            displayName: 'حسینی',
            dishName: 'اکبر جوجه با برنج',
            date: sunday,
            slot: MealSlot.lunch,
          ),
          HeldMealDigest(
            accountId: 'a2',
            displayName: 'مقسمی',
            dishName: 'چلو کباب کوبیده',
            date: sunday,
            slot: MealSlot.lunch,
          ),
        ];
        final text = formatMultiAccountNotification(meals);
        expect(
          text,
          'با اکانت حسینی غذای اکبر جوجه با برنج را رزرو داری - با اکانت مقسمی غذای چلو کباب کوبیده را رزرو داری',
        );
      },
    );

    test('returns empty string when no meals', () {
      expect(formatMultiAccountNotification([]), '');
    });
  });

  group('output is always Persian', () {
    test('no Latin digits leak into a digest body', () {
      final digest = ReminderDigest(
        slot: ReminderSlot.evening,
        generatedAt: sunday,
        accounts: [
          account('a1', 'مقسمی', [
            item(slot: MealSlot.dinner, dish: 'خوراک تن ماهی', date: sunday),
            item(slot: MealSlot.breakfast, dish: 'شیر/حلواشکری', date: monday),
          ]),
        ],
      );
      final text = composeNotification(digest);
      expect(
        RegExp(r'[0-9]').hasMatch(text.body),
        isFalse,
        reason: 'body should use Persian digits: ${text.body}',
      );
      expect(RegExp(r'[0-9]').hasMatch(text.title), isFalse);
    });
  });
}
