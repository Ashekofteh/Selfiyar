import 'package:bahonar_nut/core/meal/local_meal_store.dart';
import 'package:bahonar_nut/core/meal/meal_invariant.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:test/test.dart';

StoredMeal meal(
  String account,
  DateTime date,
  MealSlot slot, {
  MealSource source = MealSource.weeklyReservation,
  DateTime? capturedAt,
}) => StoredMeal(
  accountId: account,
  date: date,
  slot: slot,
  source: source,
  capturedAt: capturedAt ?? DateTime.utc(2026, 10, 18),
  dishName: 'dish',
);

void main() {
  final now = DateTime.utc(2026, 10, 20);
  final recent = DateTime.utc(2026, 10, 19);
  final old = DateTime.utc(2026, 10, 1);

  group('storage and lookup', () {
    test('stores and finds a meal', () {
      final store = LocalMealStore();
      store.put(meal('a1', recent, MealSlot.lunch));

      expect(store.count, 1);
      expect(store.find('a1', recent, MealSlot.lunch), isNotNull);
      expect(store.find('a1', recent, MealSlot.dinner), isNull);
      expect(store.find('a2', recent, MealSlot.lunch), isNull);
    });

    test('put replaces the record for the same slot', () {
      final store = LocalMealStore();
      store.put(
        meal(
          'a1',
          recent,
          MealSlot.lunch,
          source: MealSource.weeklyReservation,
        ),
      );
      store.put(
        meal('a1', recent, MealSlot.lunch, source: MealSource.basketPurchase),
      );

      expect(store.count, 1);
      expect(
        store.find('a1', recent, MealSlot.lunch)!.source,
        MealSource.basketPurchase,
      );
    });

    test('forAccount lists only that account, newest first', () {
      final store = LocalMealStore();
      store.put(meal('a1', old, MealSlot.lunch));
      store.put(meal('a1', recent, MealSlot.lunch));
      store.put(meal('a2', recent, MealSlot.dinner));

      final a1 = store.forAccount('a1');
      expect(a1.length, 2);
      expect(a1.first.date, recent, reason: 'newest first');
    });

    test('remove drops one meal', () {
      final store = LocalMealStore();
      store.put(meal('a1', recent, MealSlot.lunch));
      expect(store.remove('a1', recent, MealSlot.lunch), isTrue);
      expect(store.remove('a1', recent, MealSlot.lunch), isFalse);
      expect(store.count, 0);
    });
  });

  group('retention and pruning', () {
    test('a meal inside the window is kept', () {
      final store = LocalMealStore(retentionDays: 14);
      store.put(meal('a1', recent, MealSlot.lunch));
      expect(store.prune(now), 0);
      expect(store.count, 1);
    });

    test('a meal older than the window is dropped', () {
      final store = LocalMealStore(retentionDays: 14);
      store.put(meal('a1', old, MealSlot.lunch));
      expect(store.prune(now), 1);
      expect(store.count, 0);
    });

    test('pruning is by the meal\'s date, not when it was cached', () {
      // A meal for a future date, cached long ago, is still relevant.
      final store = LocalMealStore(retentionDays: 14);
      final future = DateTime.utc(2026, 12, 1);
      store.put(
        meal(
          'a1',
          future,
          MealSlot.lunch,
          capturedAt: DateTime.utc(2020, 1, 1),
        ),
      );
      expect(store.prune(now), 0);
      expect(store.count, 1);
    });

    test('the hard cap drops the oldest when the window is not enough', () {
      final store = LocalMealStore(retentionDays: 3650, maxEntries: 3);
      for (var i = 0; i < 6; i++) {
        store.put(meal('a1', DateTime.utc(2026, 10, 1 + i), MealSlot.lunch));
      }
      expect(store.count, 6);

      final removed = store.prune(now);
      expect(removed, 3);
      expect(store.count, 3);
      // The survivors are the three newest.
      final dates = store.all.map((m) => m.date.day).toList()..sort();
      expect(dates, [4, 5, 6]);
    });

    test('the cap never lets the store grow past its limit', () {
      final store = LocalMealStore(retentionDays: 3650, maxEntries: 10);
      for (var i = 0; i < 100; i++) {
        store.put(
          meal(
            'a1',
            DateTime.utc(2026, 1, 1).add(Duration(days: i)),
            MealSlot.lunch,
          ),
        );
      }
      store.prune(now);
      expect(store.count, lessThanOrEqualTo(10));
    });

    test('the retention cutoff is reported for the UI', () {
      final store = LocalMealStore(retentionDays: 14);
      expect(store.retentionCutoff(now), DateTime.utc(2026, 10, 6));
    });

    test('pruning is idempotent', () {
      final store = LocalMealStore(retentionDays: 14);
      store.put(meal('a1', old, MealSlot.lunch));
      expect(store.prune(now), 1);
      expect(store.prune(now), 0);
    });
  });

  group('reconciling with the portal', () {
    test('replaceForAccount drops meals that vanished upstream', () {
      final store = LocalMealStore();
      store.put(meal('a1', recent, MealSlot.lunch));
      store.put(meal('a1', recent, MealSlot.dinner));
      store.put(meal('a2', recent, MealSlot.lunch));

      store.replaceForAccount('a1', [meal('a1', recent, MealSlot.dinner)]);

      expect(store.forAccount('a1').length, 1);
      expect(store.find('a1', recent, MealSlot.lunch), isNull);
      expect(
        store.forAccount('a2').length,
        1,
        reason: 'other accounts are untouched',
      );
    });

    test('purgeAccount removes everything for one account', () {
      final store = LocalMealStore();
      store.put(meal('a1', recent, MealSlot.lunch));
      store.put(meal('a2', recent, MealSlot.lunch));

      store.purgeAccount('a1');
      expect(store.forAccount('a1'), isEmpty);
      expect(store.forAccount('a2').length, 1);
    });
  });

  group('the invariant against the local store', () {
    test('a cached weekly reservation blocks a basket purchase', () {
      final store = LocalMealStore();
      store.put(
        meal(
          'a1',
          recent,
          MealSlot.lunch,
          source: MealSource.weeklyReservation,
        ),
      );

      final ledger = store.toLedger();
      final verdict = ledger.check(
        accountId: 'a1',
        date: recent,
        slot: MealSlot.lunch,
        source: MealSource.basketPurchase,
      );
      expect(
        verdict.allowed,
        isFalse,
        reason: 'the offline mirror must enforce the same rule',
      );
    });

    test('a cached basket purchase blocks a weekly reservation', () {
      final store = LocalMealStore();
      store.put(
        meal('a1', recent, MealSlot.dinner, source: MealSource.basketPurchase),
      );

      final verdict = store.toLedger().check(
        accountId: 'a1',
        date: recent,
        slot: MealSlot.dinner,
        source: MealSource.weeklyReservation,
      );
      expect(verdict.allowed, isFalse);
    });

    test('the ledger reflects every stored meal', () {
      final store = LocalMealStore();
      store.put(meal('a1', recent, MealSlot.lunch));
      store.put(meal('a1', recent, MealSlot.dinner));
      store.put(meal('a2', recent, MealSlot.breakfast));

      final ledger = store.toLedger();
      expect(ledger.count, 3);
      expect(ledger.holds('a1', recent, MealSlot.lunch), isTrue);
      expect(ledger.holds('a2', recent, MealSlot.breakfast), isTrue);
    });
  });
}
