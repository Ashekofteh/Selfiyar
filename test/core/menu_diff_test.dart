import 'package:bahonar_nut/core/local_menu_store.dart';
import 'package:bahonar_nut/core/models.dart';
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
      halls: halls ?? const [Hall(id: 'h1', name: 'سلف مرکزی')],
      dishes: dishes ??
          const [
            MenuOption(id: 'd1', name: 'چلو قورمه سبزی', priceRial: 500000),
          ],
    );

void main() {
  // Let now be a Wednesday: 2026-10-21.
  // The current week Saturday is 2026-10-17.
  // The next week Saturday is 2026-10-24.
  final now = DateTime.utc(2026, 10, 21);
  final currentWeekDay = DateTime.utc(2026, 10, 20); // Tuesday
  final nextWeekSat = DateTime.utc(2026, 10, 24); // Saturday of next week
  final nextWeekDay = DateTime.utc(2026, 10, 26); // Monday of next week

  group('LocalMenuStore.diff', () {
    test('returns empty diff when incoming is empty', () {
      final store = LocalMenuStore();
      store.put(createMenu(currentWeekDay, MealSlot.lunch));

      final result = store.diff([], now);
      expect(result.nextWeekPublished, isFalse);
      expect(result.changedMenus, isEmpty);
      expect(result.hasMeaningfulChanges, isFalse);
    });

    test('returns empty diff when store is empty (initial cold start)', () {
      final store = LocalMenuStore();
      final incoming = [createMenu(currentWeekDay, MealSlot.lunch)];

      final result = store.diff(incoming, now);
      expect(result.nextWeekPublished, isFalse);
      expect(result.changedMenus, isEmpty);
      expect(result.hasMeaningfulChanges, isFalse);
    });

    test('returns empty diff when incoming matches store exactly', () {
      final store = LocalMenuStore();
      final m = createMenu(currentWeekDay, MealSlot.lunch);
      store.put(m);

      final result = store.diff([m], now);
      expect(result.hasMeaningfulChanges, isFalse);
    });

    test('returns empty diff when only dining halls differ (no false alarm across accounts)', () {
      final store = LocalMenuStore();
      store.put(createMenu(
        currentWeekDay,
        MealSlot.lunch,
        halls: [const Hall(id: 'h_brothers', name: 'سلف برادران')],
      ));

      // Sister account returns the same dishes and prices but with a different hall
      final incoming = [
        createMenu(
          currentWeekDay,
          MealSlot.lunch,
          halls: [const Hall(id: 'h_sisters', name: 'سلف خواهران')],
        ),
      ];

      final result = store.diff(incoming, now);
      expect(result.hasMeaningfulChanges, isFalse);
    });

    test('detects dish name change in existing menu', () {
      final store = LocalMenuStore();
      store.put(createMenu(
        currentWeekDay,
        MealSlot.lunch,
        dishes: [const MenuOption(id: 'd1', name: 'چلو قورمه سبزی', priceRial: 500000)],
      ));

      final updated = [
        createMenu(
          currentWeekDay,
          MealSlot.lunch,
          dishes: [const MenuOption(id: 'd1', name: 'زرشک پلو با مرغ', priceRial: 500000)],
        ),
      ];

      final result = store.diff(updated, now);
      expect(result.nextWeekPublished, isFalse);
      expect(result.changedMenus.length, 1);
      expect(result.changedMenus.first.date, currentWeekDay);
      expect(result.changedMenus.first.slot, MealSlot.lunch);
      expect(result.hasMeaningfulChanges, isTrue);
    });

    test('detects dish price change in existing menu', () {
      final store = LocalMenuStore();
      store.put(createMenu(
        currentWeekDay,
        MealSlot.lunch,
        dishes: [const MenuOption(id: 'd1', name: 'زرشک پلو با مرغ', priceRial: 500000)],
      ));

      final updated = [
        createMenu(
          currentWeekDay,
          MealSlot.lunch,
          dishes: [const MenuOption(id: 'd1', name: 'زرشک پلو با مرغ', priceRial: 600000)],
        ),
      ];

      final result = store.diff(updated, now);
      expect(result.changedMenus.length, 1);
      expect(result.hasMeaningfulChanges, isTrue);
    });

    test('detects dish count change in existing menu', () {
      final store = LocalMenuStore();
      store.put(createMenu(
        currentWeekDay,
        MealSlot.lunch,
        dishes: [const MenuOption(id: 'd1', name: 'زرشک پلو', priceRial: 500000)],
      ));

      final updated = [
        createMenu(
          currentWeekDay,
          MealSlot.lunch,
          dishes: [
            const MenuOption(id: 'd1', name: 'زرشک پلو', priceRial: 500000),
            const MenuOption(id: 'd2', name: 'چلو قیمه', priceRial: 450000),
          ],
        ),
      ];

      final result = store.diff(updated, now);
      expect(result.changedMenus.length, 1);
      expect(result.hasMeaningfulChanges, isTrue);
    });

    test('detects next week meal schedule published when store had none', () {
      final store = LocalMenuStore();
      store.put(createMenu(currentWeekDay, MealSlot.lunch));

      final incoming = [
        createMenu(currentWeekDay, MealSlot.lunch),
        createMenu(nextWeekSat, MealSlot.lunch),
        createMenu(nextWeekDay, MealSlot.dinner),
      ];

      final result = store.diff(incoming, now);
      expect(result.nextWeekPublished, isTrue);
      expect(result.hasMeaningfulChanges, isTrue);
    });

    test('does not report nextWeekPublished if store already had next week menus', () {
      final store = LocalMenuStore();
      store.put(createMenu(currentWeekDay, MealSlot.lunch));
      store.put(createMenu(nextWeekSat, MealSlot.lunch));

      final incoming = [
        createMenu(currentWeekDay, MealSlot.lunch),
        createMenu(nextWeekSat, MealSlot.lunch),
        createMenu(nextWeekDay, MealSlot.dinner),
      ];

      final result = store.diff(incoming, now);
      // nextWeekSat was already in store, so not a new publishing event
      expect(result.nextWeekPublished, isFalse);
    });
  });
}
