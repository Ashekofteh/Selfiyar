import 'package:bahonar_nut/core/local_menu_store.dart';
import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/platform_stores.dart';
import 'package:test/test.dart';

MealMenu createMenu(
  DateTime date,
  MealSlot slot, {
  bool reservable = true,
  List<Hall>? halls,
  List<MenuOption>? dishes,
}) =>
    MealMenu(
      date: date,
      slot: slot,
      reservable: reservable,
      halls: halls ?? const [Hall(id: 'h1', name: 'سلف برادران')],
      dishes: dishes ??
          const [
            MenuOption(id: 'd1', name: 'چلو قرمه سبزی', priceRial: 500000),
          ],
    );

void main() {
  final now = DateTime.utc(2026, 10, 30);
  final recent = DateTime.utc(2026, 10, 20);
  final obsolete = DateTime.utc(2026, 9, 20); // > 28 days before now

  group('LocalMenuStore basic CRUD', () {
    test('stores and finds a menu by date and slot', () {
      final store = LocalMenuStore();
      final m = createMenu(recent, MealSlot.lunch);
      store.put(m);

      expect(store.count, 1);
      expect(store.isEmpty, isFalse);
      expect(store.isNotEmpty, isTrue);
      expect(store.find(recent, MealSlot.lunch), isNotNull);
      expect(store.find(recent, MealSlot.dinner), isNull);
      expect(store.find(DateTime.utc(2026, 10, 21), MealSlot.lunch), isNull);
    });

    test('all returns menus sorted by date ascending, then slot order', () {
      final store = LocalMenuStore();
      store.put(createMenu(DateTime.utc(2026, 10, 22), MealSlot.dinner));
      store.put(createMenu(DateTime.utc(2026, 10, 21), MealSlot.lunch));
      store.put(createMenu(DateTime.utc(2026, 10, 21), MealSlot.breakfast));

      final all = store.all;
      expect(all.length, 3);
      expect(all[0].date, DateTime.utc(2026, 10, 21));
      expect(all[0].slot, MealSlot.breakfast);
      expect(all[1].date, DateTime.utc(2026, 10, 21));
      expect(all[1].slot, MealSlot.lunch);
      expect(all[2].date, DateTime.utc(2026, 10, 22));
      expect(all[2].slot, MealSlot.dinner);
    });

    test('forDate and forDates filter correctly', () {
      final store = LocalMenuStore();
      store.put(createMenu(DateTime.utc(2026, 10, 21), MealSlot.lunch));
      store.put(createMenu(DateTime.utc(2026, 10, 21), MealSlot.dinner));
      store.put(createMenu(DateTime.utc(2026, 10, 22), MealSlot.lunch));

      expect(store.forDate(DateTime.utc(2026, 10, 21)).length, 2);
      expect(store.forDate(DateTime.utc(2026, 10, 23)).length, 0);

      final multi = store.forDates([
        DateTime.utc(2026, 10, 21),
        DateTime.utc(2026, 10, 22),
      ]);
      expect(multi.length, 3);
    });

    test('remove and clear drop menus', () {
      final store = LocalMenuStore();
      store.put(createMenu(recent, MealSlot.lunch));
      expect(store.remove(recent, MealSlot.lunch), isTrue);
      expect(store.remove(recent, MealSlot.lunch), isFalse);
      expect(store.count, 0);

      store.put(createMenu(recent, MealSlot.dinner));
      store.put(createMenu(recent, MealSlot.breakfast));
      expect(store.count, 2);
      store.clear();
      expect(store.count, 0);
    });
  });

  group('LocalMenuStore upsert and multi-account merge', () {
    test('upsert merges halls from multiple accounts for same slot', () {
      final store = LocalMenuStore();

      // First account (e.g. brother)
      store.upsert([
        createMenu(
          recent,
          MealSlot.lunch,
          halls: [const Hall(id: 'h_brothers', name: 'سلف برادران')],
          dishes: [const MenuOption(id: 'd1', name: 'قرمه', priceRial: 500000)],
        ),
      ]);

      // Second account (e.g. sister)
      store.upsert([
        createMenu(
          recent,
          MealSlot.lunch,
          halls: [const Hall(id: 'h_sisters', name: 'سلف خواهران')],
          dishes: [
            const MenuOption(id: 'd1', name: 'قرمه', priceRial: 500000),
            const MenuOption(id: 'd2', name: 'فسنجان', priceRial: 600000),
          ],
        ),
      ]);

      expect(store.count, 1);
      final merged = store.find(recent, MealSlot.lunch)!;
      expect(merged.halls.map((h) => h.id), containsAll(['h_brothers', 'h_sisters']));
      expect(merged.dishes.map((d) => d.id), containsAll(['d1', 'd2']));
    });

    test('upsert updates reservable status', () {
      final store = LocalMenuStore();
      store.put(createMenu(recent, MealSlot.lunch, reservable: true));

      store.upsert([createMenu(recent, MealSlot.lunch, reservable: false)]);
      expect(store.find(recent, MealSlot.lunch)!.reservable, isFalse);
    });
  });

  group('LocalMenuStore pruning and retention', () {
    test('menus within 28 days are preserved', () {
      final store = LocalMenuStore(retentionDays: 28);
      store.put(createMenu(recent, MealSlot.lunch)); // 10 days old

      final removed = store.prune(now);
      expect(removed, 0);
      expect(store.count, 1);
    });

    test('menus older than 28 days are pruned', () {
      final store = LocalMenuStore(retentionDays: 28);
      store.put(createMenu(obsolete, MealSlot.lunch)); // 40 days old
      store.put(createMenu(recent, MealSlot.lunch));

      final removed = store.prune(now);
      expect(removed, 1);
      expect(store.count, 1);
      expect(store.find(recent, MealSlot.lunch), isNotNull);
      expect(store.find(obsolete, MealSlot.lunch), isNull);
    });

    test('hard cap drops oldest entries when exceeded', () {
      final store = LocalMenuStore(retentionDays: 100, maxEntries: 3);
      for (var i = 0; i < 5; i++) {
        store.put(createMenu(DateTime.utc(2026, 10, 1 + i), MealSlot.lunch));
      }
      expect(store.count, 5);

      final removed = store.prune(now);
      expect(removed, 2);
      expect(store.count, 3);
      // Oldest (Oct 1 and Oct 2) should be removed
      expect(store.find(DateTime.utc(2026, 10, 1), MealSlot.lunch), isNull);
      expect(store.find(DateTime.utc(2026, 10, 2), MealSlot.lunch), isNull);
      expect(store.find(DateTime.utc(2026, 10, 3), MealSlot.lunch), isNotNull);
      expect(store.find(DateTime.utc(2026, 10, 4), MealSlot.lunch), isNotNull);
      expect(store.find(DateTime.utc(2026, 10, 5), MealSlot.lunch), isNotNull);
    });
  });

  group('Serialization and equality', () {
    test('encodeMenuList and decodeMenuList round-trip cleanly', () {
      final menus = [
        createMenu(
          DateTime.utc(2026, 10, 21),
          MealSlot.lunch,
          reservable: true,
          halls: [
            const Hall(id: '1', name: 'مرکزی'),
            const Hall(id: '2', name: 'فنی'),
          ],
          dishes: [
            const MenuOption(id: '10', name: 'زرشک پلو', priceRial: 450000),
            const MenuOption(id: '11', name: 'قیمه', priceRial: 400000),
          ],
        ),
        createMenu(
          DateTime.utc(2026, 10, 22),
          MealSlot.dinner,
          reservable: false,
          halls: [const Hall(id: '1', name: 'مرکزی')],
          dishes: [const MenuOption(id: '20', name: 'سوپ', priceRial: 200000)],
        ),
      ];

      final encoded = encodeMenuList(menus);
      final decoded = decodeMenuList(encoded);

      expect(decoded.length, 2);
      expect(decoded[0].date, DateTime.utc(2026, 10, 21));
      expect(decoded[0].slot, MealSlot.lunch);
      expect(decoded[0].reservable, isTrue);
      expect(decoded[0].halls.length, 2);
      expect(decoded[0].dishes.length, 2);
      expect(decoded[1].date, DateTime.utc(2026, 10, 22));
      expect(decoded[1].slot, MealSlot.dinner);
      expect(decoded[1].reservable, isFalse);

      expect(menusEqual(menus, decoded), isTrue);
    });

    test('decodeMenuList handles malformed and empty JSON gracefully', () {
      expect(decodeMenuList(''), isEmpty);
      expect(decodeMenuList('not-json'), isEmpty);
      expect(decodeMenuList('{}'), isEmpty);
      expect(decodeMenuList('[{"bad": "entry"}]'), isEmpty);
    });

    test('menusEqual detects any difference', () {
      final m1 = createMenu(recent, MealSlot.lunch);
      final m2 = createMenu(recent, MealSlot.lunch, reservable: false);
      final m3 = createMenu(recent, MealSlot.dinner);

      expect(menusEqual([m1], [m1]), isTrue);
      expect(menusEqual([m1], [m2]), isFalse);
      expect(menusEqual([m1], [m3]), isFalse);
      expect(menusEqual([m1], []), isFalse);
    });
  });

  group('LocalMenuStore hasChanges change detection', () {
    test('returns false when incoming matches stored menus exactly', () {
      final store = LocalMenuStore();
      final m = createMenu(recent, MealSlot.lunch);
      store.put(m);

      expect(store.hasChanges([m]), isFalse);
    });

    test('returns false when store contains older past menus but incoming current week is unchanged', () {
      final store = LocalMenuStore();
      final pastMenu = createMenu(DateTime.utc(2026, 10, 10), MealSlot.lunch);
      final currentMenu = createMenu(recent, MealSlot.lunch);
      store.put(pastMenu);
      store.put(currentMenu);

      // Server only returns current week (1 item, while store has 2)
      expect(store.hasChanges([currentMenu]), isFalse);
    });

    test('returns true when incoming includes brand new date (e.g. next week)', () {
      final store = LocalMenuStore();
      final currentMenu = createMenu(recent, MealSlot.lunch);
      store.put(currentMenu);

      final nextWeekMenu = createMenu(DateTime.utc(2026, 10, 27), MealSlot.lunch);
      expect(store.hasChanges([currentMenu, nextWeekMenu]), isTrue);
    });

    test('returns true when dish name or price changes', () {
      final store = LocalMenuStore();
      final original = createMenu(
        recent,
        MealSlot.lunch,
        dishes: [const MenuOption(id: 'd1', name: 'قیمه', priceRial: 400000)],
      );
      store.put(original);

      final updatedDish = createMenu(
        recent,
        MealSlot.lunch,
        dishes: [const MenuOption(id: 'd1', name: 'قیمه بادمجان', priceRial: 450000)],
      );
      expect(store.hasChanges([updatedDish]), isTrue);
    });

    test('returns true when reservable status changes', () {
      final store = LocalMenuStore();
      final original = createMenu(recent, MealSlot.lunch, reservable: true);
      store.put(original);

      final locked = createMenu(recent, MealSlot.lunch, reservable: false);
      expect(store.hasChanges([locked]), isTrue);
    });

    test('returns false when incoming list is empty', () {
      final store = LocalMenuStore();
      store.put(createMenu(recent, MealSlot.lunch));
      expect(store.hasChanges([]), isFalse);
    });
  });
}
