import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/core/finance/spend_summary.dart';
import 'package:test/test.dart';

const booking = 'رزرو غذا';
const withdrawal = 'انصراف از رزرو غذا';
const modification = 'تغییر سلف، نوع یا تعداد غذا';

Transaction tx(
  String account,
  String date,
  MealSlot slot,
  int amount, {
  String type = booking,
  String food = 'چلو اکبرجوجه,دوغ',
  int count = 1,
}) => Transaction(
  accountId: account,
  type: type,
  foodName: food,
  slot: slot,
  weekday: 'سه شنبه',
  date: date,
  count: count,
  amountRial: amount,
);

void main() {
  // The live ledger's own shape: newest first, and 1405/07/30 lunch was
  // booked, released, then booked again.
  final live = [
    tx('a1', '1405/08/03', MealSlot.breakfast, 150000, type: withdrawal),
    tx('a1', '1405/08/03', MealSlot.breakfast, 150000),
    tx('a1', '1405/07/30', MealSlot.lunch, 500000),
    tx('a1', '1405/07/30', MealSlot.lunch, 500000, type: withdrawal),
    tx('a1', '1405/07/30', MealSlot.lunch, 500000),
    tx('a1', '1405/07/28', MealSlot.dinner, 350000),
    tx('a1', '1405/07/28', MealSlot.lunch, 500000),
    tx('a1', '1405/07/27', MealSlot.breakfast, 150000),
  ];

  group('the counting rule', () {
    test('a re-booked meal is counted once, not twice', () {
      final summary = summarise(transactions: live);
      final lunch30 = summary.entries
          .where((e) => e.date.toIso8601String().startsWith('2026-10-22'))
          .toList();
      expect(
        lunch30.length,
        1,
        reason: '1405/07/30 lunch was booked twice in the log; it is one meal',
      );
    });

    test('a released meal is excluded', () {
      final summary = summarise(transactions: live);
      // 1405/08/03 breakfast was withdrawn, so it must not count.
      expect(summary.excludedWithdrawn, 1);
      final breakfast = summary.entries
          .where((e) => e.slot == MealSlot.breakfast)
          .toList();
      expect(
        breakfast.length,
        1,
        reason: 'only the 1405/07/27 breakfast, not the released 08/03 one',
      );
    });

    test('the newest event wins', () {
      // Booked, then released: the release is newer, so it is not held.
      final summary = summarise(
        transactions: [
          tx('a1', '1405/07/28', MealSlot.lunch, 500000, type: withdrawal),
          tx('a1', '1405/07/28', MealSlot.lunch, 500000),
        ],
      );
      expect(summary.entries, isEmpty);
      expect(summary.excludedWithdrawn, 1);
    });

    test('a naive sum would have been wrong', () {
      // The sum of every booking row, which is what a careless implementation
      // would report: 1405/07/30 lunch booked twice, and 1405/08/03 breakfast
      // booked then released.
      final naive = live
          .where((t) => t.isAcquisition)
          .fold(0, (sum, t) => sum + t.amountRial);
      final correct = summarise(transactions: live).totalRial;

      expect(naive, 2150000, reason: 'what a careless sum would report');
      expect(correct, 1500000, reason: 'what the meals actually held cost');
      expect(correct, lessThan(naive));
      // A 30% overstatement on this history.
      expect(naive - correct, 650000);
    });
  });

  group('totals', () {
    test('sums the amounts of the meals held', () {
      final summary = summarise(transactions: live);
      // 150000 (07/27 breakfast) + 500000 (07/30 lunch) + 350000 (07/28 dinner)
      // + 500000 (07/28 lunch) = 1500000
      expect(summary.totalRial, 1500000);
      expect(summary.totalMeals, 4);
    });

    test('breaks down by slot', () {
      final summary = summarise(transactions: live);
      expect(summary.bySlot.totals[MealSlot.breakfast], 150000);
      expect(summary.bySlot.totals[MealSlot.lunch], 1000000);
      expect(summary.bySlot.totals[MealSlot.dinner], 350000);
      expect(summary.bySlot.totalRial, 1500000);
      expect(summary.bySlot.counts[MealSlot.lunch], 2);
    });

    test('breaks down by account', () {
      final summary = summarise(transactions: live);
      expect(summary.byAccount['a1'], 1500000);
    });

    test('averages the cost of a meal', () {
      final summary = summarise(transactions: live);
      expect(summary.totalMeals, 4);
      expect(summary.averageMealRial, 375000);
    });

    test('an empty history totals zero and does not divide by zero', () {
      final summary = summarise(transactions: const []);
      expect(summary.totalRial, 0);
      expect(summary.totalMeals, 0);
      expect(summary.averageMealRial, 0);
    });
  });

  group('account filter', () {
    final two = [
      tx('a1', '1405/07/27', MealSlot.breakfast, 150000),
      tx('a2', '1405/07/27', MealSlot.breakfast, 150000),
    ];

    test('an empty filter means all accounts', () {
      final summary = summarise(transactions: two);
      expect(summary.totalRial, 300000);
      expect(summary.entries.length, 2);
    });

    test('a selected account narrows the total', () {
      final summary = summarise(
        transactions: two,
        filter: const SpendFilter(accountIds: {'a1'}),
      );
      expect(summary.totalRial, 150000);
      expect(summary.entries.length, 1);
      expect(summary.entries.single.accountId, 'a1');
    });

    test('several accounts can be selected at once', () {
      final summary = summarise(
        transactions: two,
        filter: const SpendFilter(accountIds: {'a1', 'a2'}),
      );
      expect(summary.totalRial, 300000);
    });

    test('an account with no transactions contributes nothing', () {
      final summary = summarise(
        transactions: two,
        filter: const SpendFilter(accountIds: {'a3'}),
      );
      expect(summary.totalRial, 0);
      expect(summary.entries, isEmpty);
    });
  });

  group('slot filter', () {
    final mixed = [
      tx('a1', '1405/07/27', MealSlot.breakfast, 150000),
      tx('a1', '1405/07/28', MealSlot.lunch, 500000),
      tx('a1', '1405/07/28', MealSlot.dinner, 350000),
    ];

    test('an empty filter means all slots', () {
      expect(summarise(transactions: mixed).totalRial, 1000000);
    });

    test('a selected slot narrows the total', () {
      final summary = summarise(
        transactions: mixed,
        filter: const SpendFilter(slots: {MealSlot.lunch}),
      );
      expect(summary.totalRial, 500000);
    });

    test('several slots can be selected at once', () {
      final summary = summarise(
        transactions: mixed,
        filter: const SpendFilter(slots: {MealSlot.lunch, MealSlot.dinner}),
      );
      expect(summary.totalRial, 850000);
    });
  });

  group('both filters together', () {
    final grid = [
      tx('a1', '1405/07/27', MealSlot.breakfast, 150000),
      tx('a1', '1405/07/28', MealSlot.lunch, 500000),
      tx('a2', '1405/07/27', MealSlot.breakfast, 150000),
      tx('a2', '1405/07/28', MealSlot.lunch, 500000),
      tx('a2', '1405/07/28', MealSlot.dinner, 350000),
    ];

    test('accounts and slots intersect', () {
      final summary = summarise(
        transactions: grid,
        filter: const SpendFilter(accountIds: {'a2'}, slots: {MealSlot.lunch}),
      );
      expect(summary.totalRial, 500000);
      expect(summary.entries.length, 1);
      expect(summary.entries.single.accountId, 'a2');
      expect(summary.entries.single.slot, MealSlot.lunch);
    });

    test('a wider selection aggregates more', () {
      final summary = summarise(
        transactions: grid,
        filter: const SpendFilter(
          accountIds: {'a1', 'a2'},
          slots: {MealSlot.breakfast, MealSlot.lunch},
        ),
      );
      // a1: 150000 + 500000, a2: 150000 + 500000
      expect(summary.totalRial, 1300000);
      expect(summary.entries.length, 4);
    });
  });

  group('filter toggling', () {
    test('toggling an account on and off', () {
      var filter = const SpendFilter();
      expect(filter.isUnfiltered, isTrue);

      filter = filter.toggleAccount('a1');
      expect(filter.accountIds, {'a1'});
      expect(filter.isUnfiltered, isFalse);

      filter = filter.toggleAccount('a1');
      expect(filter.accountIds, isEmpty);
      expect(filter.isUnfiltered, isTrue);
    });

    test('toggling a slot on and off', () {
      var filter = const SpendFilter();
      filter = filter.toggleSlot(MealSlot.dinner);
      expect(filter.slots, {MealSlot.dinner});

      filter = filter.toggleSlot(MealSlot.dinner);
      expect(filter.slots, isEmpty);
    });

    test('toggling one dimension leaves the other alone', () {
      var filter = const SpendFilter(slots: {MealSlot.dinner});
      filter = filter.toggleAccount('a1');
      expect(filter.slots, {MealSlot.dinner});
      expect(filter.accountIds, {'a1'});
    });
  });

  group('transaction classification', () {
    test('a booking is an acquisition', () {
      final t = tx('a1', '1405/07/28', MealSlot.lunch, 500000);
      expect(t.isAcquisition, isTrue);
      expect(t.isWithdrawal, isFalse);
    });

    test('a withdrawal is not an acquisition', () {
      final t = tx(
        'a1',
        '1405/07/28',
        MealSlot.lunch,
        500000,
        type: withdrawal,
      );
      expect(t.isAcquisition, isFalse);
      expect(t.isWithdrawal, isTrue);
    });

    test('an unknown type is neither, and is not counted as held', () {
      final t = tx(
        'a1',
        '1405/07/28',
        MealSlot.lunch,
        500000,
        type: 'افزایش اعتبار',
      );
      expect(t.isAcquisition, isFalse);
      expect(t.isWithdrawal, isFalse);
      expect(t.isModification, isFalse);
    });

    test('a modification is its own kind of event', () {
      final t = tx(
        'a1',
        '1405/07/28',
        MealSlot.lunch,
        -150000,
        type: modification,
        count: 0,
      );
      expect(t.isModification, isTrue);
      expect(t.isAcquisition, isFalse);
      expect(t.isWithdrawal, isFalse);
    });
  });

  group('event-sourced edits', () {
    // The incoming ledger is newest first, as the portal serves it.
    // The edit row amount is the signed balance effect: negative means the
    // meal became more expensive (so it was charged), positive means cheaper.
    test('booking 350k then -150k then +150k nets 350k', () {
      final summary = summarise(
        transactions: [
          tx(
            'a1',
            '1405/07/28',
            MealSlot.lunch,
            150000,
            type: modification,
            count: 0,
          ),
          tx(
            'a1',
            '1405/07/28',
            MealSlot.lunch,
            -150000,
            type: modification,
            count: 0,
          ),
          tx('a1', '1405/07/28', MealSlot.lunch, 350000),
        ],
      );

      expect(summary.entries, hasLength(1));
      expect(summary.entries.single.amountRial, 350000);
      expect(summary.totalRial, 350000);
      expect(summary.totalMeals, 1);
      expect(summary.excludedWithdrawn, 0);
    });

    test('booking 350k then -150k edit (upgrade) leaves a 500k meal with the new food', () {
      final summary = summarise(
        transactions: [
          tx(
            'a1',
            '1405/07/28',
            MealSlot.lunch,
            -150000,
            type: modification,
            food: 'چلو اکبرجوجه',
            count: 0,
          ),
          tx(
            'a1',
            '1405/07/28',
            MealSlot.lunch,
            350000,
            food: 'شوید پلو با ماهی قزل',
          ),
        ],
      );

      expect(summary.entries, hasLength(1));
      expect(summary.entries.single.amountRial, 500000);
      expect(summary.entries.single.foodName, 'چلو اکبرجوجه');
      expect(summary.totalRial, 500000);
      expect(summary.excludedWithdrawn, 0);
    });

    test('booking 500k then +150k edit (downgrade) leaves a 350k meal with the new food', () {
      final summary = summarise(
        transactions: [
          tx(
            'a1',
            '1405/07/28',
            MealSlot.lunch,
            150000,
            type: modification,
            food: 'شوید پلو با ماهی قزل',
            count: 0,
          ),
          tx('a1', '1405/07/28', MealSlot.lunch, 500000, food: 'چلو اکبرجوجه'),
        ],
      );

      expect(summary.entries, hasLength(1));
      expect(summary.entries.single.amountRial, 350000);
      expect(summary.entries.single.foodName, 'شوید پلو با ماهی قزل');
      expect(summary.totalRial, 350000);
      expect(summary.excludedWithdrawn, 0);
    });

    test('booking 700k (count 2) then +350k edit (count 0) preserves count 2 and nets 350k', () {
      final summary = summarise(
        transactions: [
          tx(
            'a1',
            '1405/07/28',
            MealSlot.lunch,
            350000,
            type: modification,
            count: 0,
          ),
          tx('a1', '1405/07/28', MealSlot.lunch, 700000, count: 2),
        ],
      );

      expect(summary.entries, hasLength(1));
      expect(summary.entries.single.amountRial, 350000);
      expect(summary.entries.single.count, 2);
      expect(summary.totalRial, 350000);
      expect(summary.totalMeals, 2);
      expect(summary.excludedWithdrawn, 0);
    });

    test(
      'booking 350k then 0 then -150k then +150k matches real portal sequence',
      () {
        final summary = summarise(
          transactions: [
            tx(
              'a1',
              '1405/07/28',
              MealSlot.lunch,
              150000,
              type: modification,
              food: 'شوید پلو',
              count: 0,
            ),
            tx(
              'a1',
              '1405/07/28',
              MealSlot.lunch,
              0,
              type: modification,
              food: 'چلو اکبرجوجه',
              count: 0,
            ),
            tx(
              'a1',
              '1405/07/28',
              MealSlot.lunch,
              -150000,
              type: modification,
              food: 'چلو اکبرجوجه',
              count: 0,
            ),
            tx('a1', '1405/07/28', MealSlot.lunch, 350000, food: 'شوید پلو'),
          ],
        );

        expect(summary.entries, hasLength(1));
        expect(summary.entries.single.amountRial, 350000);
        expect(summary.entries.single.foodName, 'شوید پلو');
        expect(summary.totalRial, 350000);
        expect(summary.excludedWithdrawn, 0);
      },
    );

    test('orphan edit in truncated ledger initializes entry with count 1', () {
      final summary = summarise(
        transactions: [
          tx(
            'a1',
            '1405/07/28',
            MealSlot.lunch,
            -150000,
            type: modification,
            food: 'چلو اکبرجوجه',
            count: 0,
          ),
        ],
      );

      expect(summary.entries, hasLength(1));
      expect(summary.entries.single.amountRial, 150000);
      expect(summary.entries.single.count, 1);
      expect(summary.entries.single.foodName, 'چلو اکبرجوجه');
      expect(summary.totalRial, 150000);
      expect(summary.totalMeals, 1);
      expect(summary.excludedWithdrawn, 0);
    });

    test('a modified meal that is then withdrawn is excluded, not held', () {
      final summary = summarise(
        transactions: [
          tx(
            'a1',
            '1405/07/28',
            MealSlot.lunch,
            350000,
            type: withdrawal,
            food: '',
            count: 0,
          ),
          tx(
            'a1',
            '1405/07/28',
            MealSlot.lunch,
            -150000,
            type: modification,
            count: 0,
          ),
          tx('a1', '1405/07/28', MealSlot.lunch, 350000),
        ],
      );

      expect(summary.entries, isEmpty);
      expect(summary.totalRial, 0);
      expect(summary.totalMeals, 0);
      expect(summary.excludedWithdrawn, 1);
    });

    test('a booking without an edit stays a 350k meal', () {
      final summary = summarise(
        transactions: [tx('a1', '1405/07/28', MealSlot.lunch, 350000)],
      );

      expect(summary.entries, hasLength(1));
      expect(summary.entries.single.amountRial, 350000);
      expect(summary.totalRial, 350000);
      expect(summary.totalMeals, 1);
      expect(summary.excludedWithdrawn, 0);
    });

    test('re-booking after a withdrawal keeps the final booking', () {
      final summary = summarise(
        transactions: [
          tx('a1', '1405/07/28', MealSlot.lunch, 400000, food: 'قیمه,دوغ'),
          tx('a1', '1405/07/28', MealSlot.lunch, 350000, type: withdrawal),
          tx('a1', '1405/07/28', MealSlot.lunch, 350000),
        ],
      );

      expect(summary.entries, hasLength(1));
      expect(summary.entries.single.amountRial, 400000);
      expect(summary.entries.single.foodName, 'قیمه,دوغ');
      expect(summary.totalRial, 400000);
      expect(summary.totalMeals, 1);
      expect(summary.excludedWithdrawn, 0);
    });
  });

  group('period filter', () {
    // 1405/07/28 is 2026-10-20 (Tuesday in week 1405/07/25 - 1405/08/01)
    // 1405/08/03 is 2026-10-25 (Sunday in week 1405/08/02 - 1405/08/08)
    final ref = DateTime.utc(2026, 10, 20); // 1405/07/28

    final multiWeekTx = [
      tx('a1', '1405/08/03', MealSlot.lunch, 500000), // Next week, Aban
      tx('a1', '1405/07/28', MealSlot.lunch, 350000), // Current week, Mehr
      tx('a1', '1405/07/20', MealSlot.lunch, 200000), // Previous week, Mehr
    ];

    test('all period includes all transactions', () {
      final summary = summarise(
        transactions: multiWeekTx,
        filter: SpendFilter(
          periodType: SpendPeriodType.all,
          referenceDate: ref,
        ),
      );
      expect(summary.totalRial, 1050000);
      expect(summary.totalMeals, 3);
    });

    test('week period with offset 0 covers only current week', () {
      final summary = summarise(
        transactions: multiWeekTx,
        filter: SpendFilter(
          periodType: SpendPeriodType.week,
          weekOffset: 0,
          referenceDate: ref,
        ),
      );
      expect(summary.totalRial, 350000);
      expect(summary.totalMeals, 1);
      expect(summary.entries.first.amountRial, 350000);
    });

    test('week period with offset 1 covers next week', () {
      final summary = summarise(
        transactions: multiWeekTx,
        filter: SpendFilter(
          periodType: SpendPeriodType.week,
          weekOffset: 1,
          referenceDate: ref,
        ),
      );
      expect(summary.totalRial, 500000);
      expect(summary.totalMeals, 1);
    });

    test('week period with offset -1 covers previous week', () {
      final summary = summarise(
        transactions: multiWeekTx,
        filter: SpendFilter(
          periodType: SpendPeriodType.week,
          weekOffset: -1,
          referenceDate: ref,
        ),
      );
      expect(summary.totalRial, 200000);
      expect(summary.totalMeals, 1);
    });

    test('month period covers the entire Jalali month', () {
      // Current month for ref (1405/07/28) is Mehr (month 7)
      final summaryMehr = summarise(
        transactions: multiWeekTx,
        filter: SpendFilter(
          periodType: SpendPeriodType.month,
          monthOffset: 0,
          referenceDate: ref,
        ),
      );
      // Mehr has 350,000 + 200,000 = 550,000
      expect(summaryMehr.totalRial, 550000);
      expect(summaryMehr.totalMeals, 2);

      // Next month is Aban (month 8, offset 1)
      final summaryAban = summarise(
        transactions: multiWeekTx,
        filter: SpendFilter(
          periodType: SpendPeriodType.month,
          monthOffset: 1,
          referenceDate: ref,
        ),
      );
      expect(summaryAban.totalRial, 500000);
      expect(summaryAban.totalMeals, 1);
    });

    test('period methods update filter correctly', () {
      var filter = const SpendFilter();
      expect(filter.isUnfiltered, isTrue);

      filter = filter.withPeriod(SpendPeriodType.week);
      expect(filter.periodType, SpendPeriodType.week);
      expect(filter.isUnfiltered, isFalse);

      filter = filter.withWeekOffset(2);
      expect(filter.weekOffset, 2);

      filter = filter.withMonthOffset(-1);
      expect(filter.monthOffset, -1);
    });
  });
}
