import 'package:bahonar_nut/core/hunt/hunt_success.dart';
import 'package:bahonar_nut/core/hunt/hunt_success_store.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:test/test.dart';

import '../../helpers/memory_stores.dart';

void main() {
  group('HuntSuccess', () {
    final sampleDate = DateTime.utc(2026, 11, 24);
    final claimedAt = DateTime.utc(2026, 11, 23, 13, 0);

    final success = HuntSuccess(
      accountId: 'acc1',
      dishName: 'چلو کباب کوبیده',
      hallName: 'مرکزی برادران',
      priceRial: 350000,
      date: sampleDate,
      slot: MealSlot.lunch,
      claimedAt: claimedAt,
    );

    test('serializes to and from JSON faithfully', () {
      final json = success.toJson();
      final roundtrip = HuntSuccess.fromJson('acc1', json);

      expect(roundtrip, equals(success));
      expect(roundtrip?.accountId, 'acc1');
      expect(roundtrip?.dishName, 'چلو کباب کوبیده');
      expect(roundtrip?.hallName, 'مرکزی برادران');
      expect(roundtrip?.priceRial, 350000);
      expect(roundtrip?.priceToman, 35000);
      expect(roundtrip?.date, sampleDate);
      expect(roundtrip?.slot, MealSlot.lunch);
      expect(roundtrip?.claimedAt, claimedAt);
    });

    test('fromJson handles missing, null, or malformed data gracefully', () {
      expect(HuntSuccess.fromJson('acc1', {}), isNull);
      expect(HuntSuccess.fromJson('acc1', {'accountId': 'a1'}), isNull);
      expect(
        HuntSuccess.fromJson('acc1', {
          'dishName': 'غذا',
          'hallName': 'سلف',
          'priceRial': 'not_an_int',
          'date': 'invalid-date',
          'slot': 'unknown_slot',
          'claimedAt': 'invalid-date',
        }),
        isNull,
      );
    });

    test('copyWith updates specified fields', () {
      final updated = success.copyWith(
        dishName: 'جوجه کباب',
        priceRial: 400000,
      );
      expect(updated.dishName, 'جوجه کباب');
      expect(updated.priceRial, 400000);
      expect(updated.priceToman, 40000);
      expect(updated.hallName, 'مرکزی برادران');
    });
  });

  group('PreferencesHuntSuccessStore', () {
    late MemoryPlainStore plainStore;
    late PreferencesHuntSuccessStore store;

    setUp(() {
      plainStore = MemoryPlainStore();
      store = PreferencesHuntSuccessStore(plainStore);
    });

    final success1 = HuntSuccess(
      accountId: 'acc1',
      dishName: 'قورمه سبزی',
      hallName: 'مرکزی خواهران',
      priceRial: 250000,
      date: DateTime.utc(2026, 11, 25),
      slot: MealSlot.dinner,
      claimedAt: DateTime.utc(2026, 11, 23, 16, 30),
    );

    final success2 = HuntSuccess(
      accountId: 'acc2',
      dishName: 'قیمه بادمجان',
      hallName: 'سلف زیتون',
      priceRial: 280000,
      date: DateTime.utc(2026, 11, 26),
      slot: MealSlot.lunch,
      claimedAt: DateTime.utc(2026, 11, 23, 10, 0),
    );

    test('returns null when no record exists', () async {
      expect(await store.load('acc1'), isNull);
    });

    test('persists and retrieves records per account', () async {
      await store.save(success1);
      await store.save(success2);

      final loaded1 = await store.load('acc1');
      final loaded2 = await store.load('acc2');

      expect(loaded1, equals(success1));
      expect(loaded2, equals(success2));
      expect(loaded1?.dishName, 'قورمه سبزی');
      expect(loaded2?.dishName, 'قیمه بادمجان');
    });

    test('removes record for specific account without affecting others', () async {
      await store.save(success1);
      await store.save(success2);

      await store.remove('acc1');

      expect(await store.load('acc1'), isNull);
      expect(await store.load('acc2'), equals(success2));
    });

    test('persists across fresh store instances sharing the plainStore', () async {
      await store.save(success1);

      final freshStore = PreferencesHuntSuccessStore(plainStore);
      final loaded = await freshStore.load('acc1');
      expect(loaded, equals(success1));
    });
  });
}
