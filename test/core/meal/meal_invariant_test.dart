import 'package:bahonar_nut/core/meal/meal_invariant.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:test/test.dart';

void main() {
  final date = DateTime.utc(2026, 10, 20); // a Tuesday
  final other = DateTime.utc(2026, 10, 21);

  group('one meal per slot per date', () {
    test('an empty ledger admits anything', () {
      final ledger = MealLedger();
      final verdict = ledger.check(
        accountId: 'a1',
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.basketPurchase,
      );
      expect(verdict.allowed, isTrue);
    });

    test('holding a meal occupies the slot', () {
      final ledger = MealLedger();
      ledger.hold(
        accountId: 'a1',
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
      );
      expect(ledger.holds('a1', date, MealSlot.lunch), isTrue);
      expect(
        ledger.heldFor('a1', date, MealSlot.lunch)!.source,
        MealSource.weeklyReservation,
      );
    });

    test('a different slot on the same date is fine', () {
      final ledger = MealLedger();
      ledger.hold(
        accountId: 'a1',
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
      );
      final verdict = ledger.check(
        accountId: 'a1',
        date: date,
        slot: MealSlot.dinner,
        source: MealSource.basketPurchase,
      );
      expect(verdict.allowed, isTrue);
    });

    test('the same slot on a different date is fine', () {
      final ledger = MealLedger();
      ledger.hold(
        accountId: 'a1',
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
      );
      final verdict = ledger.check(
        accountId: 'a1',
        date: other,
        slot: MealSlot.lunch,
        source: MealSource.basketPurchase,
      );
      expect(verdict.allowed, isTrue);
    });
  });

  group('the cross-source rule', () {
    test('a basket purchase is refused when a weekly reservation holds it', () {
      final ledger = MealLedger();
      ledger.hold(
        accountId: 'a1',
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
      );

      final verdict = ledger.check(
        accountId: 'a1',
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.basketPurchase,
      );
      expect(verdict.allowed, isFalse);
      expect(
        verdict.conflict!.reason,
        MealConflictReason.alreadyReservedWeekly,
      );
    });

    test('a weekly reservation is refused when a basket purchase holds it', () {
      final ledger = MealLedger();
      ledger.hold(
        accountId: 'a1',
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.basketPurchase,
      );

      final verdict = ledger.check(
        accountId: 'a1',
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
      );
      expect(verdict.allowed, isFalse);
      expect(
        verdict.conflict!.reason,
        MealConflictReason.alreadyPurchasedFromBasket,
      );
    });

    test('a second basket purchase of the same slot and date is refused', () {
      final ledger = MealLedger();
      ledger.hold(
        accountId: 'a1',
        date: date,
        slot: MealSlot.dinner,
        source: MealSource.basketPurchase,
      );

      final verdict = ledger.check(
        accountId: 'a1',
        date: date,
        slot: MealSlot.dinner,
        source: MealSource.basketPurchase,
      );
      expect(verdict.allowed, isFalse);
      expect(
        verdict.conflict!.reason,
        MealConflictReason.alreadyPurchasedFromBasket,
      );
    });
  });

  group('a denied hold does not overwrite the existing meal', () {
    test('the original meal survives a refused second attempt', () {
      final ledger = MealLedger();
      ledger.hold(
        accountId: 'a1',
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
        optionId: '62738',
      );

      final verdict = ledger.hold(
        accountId: 'a1',
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.basketPurchase,
        optionId: '62740',
      );

      expect(verdict.allowed, isFalse);
      final held = ledger.heldFor('a1', date, MealSlot.lunch)!;
      expect(held.source, MealSource.weeklyReservation);
      expect(
        held.optionId,
        '62738',
        reason: 'the refused purchase must not displace the reservation',
      );
    });

    test('the ledger count does not grow on a refusal', () {
      final ledger = MealLedger();
      ledger.hold(
        accountId: 'a1',
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
      );
      ledger.hold(
        accountId: 'a1',
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.basketPurchase,
      );
      expect(ledger.count, 1);
    });
  });

  group('accounts are independent', () {
    test('one account holding a slot does not block another', () {
      final ledger = MealLedger();
      ledger.hold(
        accountId: 'a1',
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
      );
      final verdict = ledger.check(
        accountId: 'a2',
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.basketPurchase,
      );
      expect(verdict.allowed, isTrue, reason: 'each account has its own meals');
    });
  });

  group('release and replacement', () {
    test('releasing frees the slot', () {
      final ledger = MealLedger();
      ledger.hold(
        accountId: 'a1',
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.weeklyReservation,
      );
      ledger.release('a1', date, MealSlot.lunch);

      final verdict = ledger.check(
        accountId: 'a1',
        date: date,
        slot: MealSlot.lunch,
        source: MealSource.basketPurchase,
      );
      expect(verdict.allowed, isTrue);
    });

    test('releasing an empty slot is harmless', () {
      final ledger = MealLedger();
      expect(ledger.release('a1', date, MealSlot.dinner), isNull);
    });

    test('replaceAll drops meals that vanished upstream', () {
      final ledger = MealLedger([
        HeldMeal(
          accountId: 'a1',
          date: date,
          slot: MealSlot.lunch,
          source: MealSource.weeklyReservation,
        ),
        HeldMeal(
          accountId: 'a1',
          date: other,
          slot: MealSlot.dinner,
          source: MealSource.weeklyReservation,
        ),
      ]);
      expect(ledger.count, 2);

      ledger.replaceAll([
        HeldMeal(
          accountId: 'a1',
          date: other,
          slot: MealSlot.dinner,
          source: MealSource.weeklyReservation,
        ),
      ]);
      expect(ledger.count, 1);
      expect(ledger.holds('a1', date, MealSlot.lunch), isFalse);
    });
  });

  group('heldOn', () {
    test('returns only that date, in slot order', () {
      final ledger = MealLedger([
        HeldMeal(
          accountId: 'a1',
          date: date,
          slot: MealSlot.dinner,
          source: MealSource.weeklyReservation,
        ),
        HeldMeal(
          accountId: 'a1',
          date: date,
          slot: MealSlot.breakfast,
          source: MealSource.weeklyReservation,
        ),
        HeldMeal(
          accountId: 'a1',
          date: other,
          slot: MealSlot.lunch,
          source: MealSource.weeklyReservation,
        ),
      ]);

      final onDate = ledger.heldOn('a1', date);
      expect(onDate.length, 2);
      expect(onDate[0].slot, MealSlot.breakfast);
      expect(onDate[1].slot, MealSlot.dinner);
    });
  });

  group('the key format', () {
    test('is date|slot and is stable', () {
      expect(mealKey(date, MealSlot.lunch), '2026-10-20|lunch');
      expect(mealKey(date, MealSlot.lunch), mealKey(date, MealSlot.lunch));
    });

    test('distinguishes slots and dates', () {
      expect(
        mealKey(date, MealSlot.lunch),
        isNot(mealKey(date, MealSlot.dinner)),
      );
      expect(
        mealKey(date, MealSlot.lunch),
        isNot(mealKey(other, MealSlot.lunch)),
      );
    });
  });
}
