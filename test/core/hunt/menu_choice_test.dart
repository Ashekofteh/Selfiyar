import 'package:bahonar_nut/core/hunt/hunt_config.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:test/test.dart';

/// The hunt's setup reads the **official weekly menu**, and the menu names
/// the halls that *serve* a meal.
///
/// The marketplace (`FoodBasketBuy.aspx`) answers a different question — which
/// meals have been *released* for sale — and its hall list is a strict subset
/// of the menu's. So a hunt built from the marketplace cannot name a hall
/// that has not yet released anything, which is exactly the hall a hunt needs
/// to name: the market fills up *during* the hunt window.
///
/// These tests pin the mapping from a menu to the two lists the screen
/// offers.
void main() {
  const central = Hall(id: '1', name: 'مرکزی برادران');
  const technical = Hall(id: '2', name: 'فنی برادران');

  final lunch = MealMenu(
    date: DateTime.utc(2026, 10, 20),
    slot: MealSlot.lunch,
    halls: const [central, technical],
    dishes: const [
      MenuOption(id: '62738', name: 'چلو اکبرجوجه,دوغ', priceRial: 500000),
      MenuOption(id: '62740', name: 'چلو گوشت,ماست', priceRial: 500000),
    ],
    reservable: true,
  );

  final dinner = MealMenu(
    date: DateTime.utc(2026, 10, 20),
    slot: MealSlot.dinner,
    halls: const [central],
    dishes: const [
      MenuOption(id: '62745', name: 'لوبیا پلو با گوشت,ماست', priceRial: 350000),
    ],
    reservable: true,
  );

  group('the menu becomes the two lists the screen offers', () {
    test('both halls are offered, not just the selected one', () {
      final choice = MenuChoice.from([lunch, dinner], MealSlot.lunch)!;

      // The hall the account had *not* chosen is the one a hunt could not
      // name before, and it is the one a "fall back to Engineering" hunt
      // needs.
      expect(choice.halls.map((h) => h.id), ['1', '2']);
      expect(choice.halls.map((h) => h.name), ['مرکزی برادران', 'فنی برادران']);
    });

    test('the dishes carry the price the menu quoted for that date and slot',
        () {
      final choice = MenuChoice.from([lunch, dinner], MealSlot.lunch)!;

      expect(choice.dishes.map((d) => d.name), [
        'چلو اکبرجوجه,دوغ',
        'چلو گوشت,ماست',
      ]);
      expect(choice.dishes.every((d) => d.priceRial == 500000), isTrue);
    });

    test('the dish key is the normalised name, so it matches across pages', () {
      final choice = MenuChoice.from([lunch], MealSlot.lunch)!;

      // The whitespace is stripped and the separators are unified, because
      // the portal is inconsistent about how it writes a dish name — and the
      // hunt matches on this key, across pages that number the same dish
      // differently.
      expect(choice.dishes.first.dishKey, 'چلواکبرجوجه,دوغ');
    });

    test('a meal served in one hall offers only that hall', () {
      final choice = MenuChoice.from([lunch, dinner], MealSlot.dinner)!;

      expect(choice.halls.map((h) => h.id), ['1']);
      expect(choice.dishes.map((d) => d.name), ['لوبیا پلو با گوشت,ماست']);
    });

    test('a meal the portal does not serve that day is absent, not empty', () {
      // The distinction matters: an empty choice means "the portal serves
      // this meal and offers nothing on it", while null means "there is no
      // such meal" — and a hunt for a meal that is never served can buy
      // nothing at all.
      expect(MenuChoice.from([lunch, dinner], MealSlot.breakfast), isNull);
    });

    test('a menu with no dishes is an empty choice, not a missing one', () {
      final empty = MealMenu(
        date: DateTime.utc(2026, 10, 20),
        slot: MealSlot.breakfast,
        halls: const [central],
        dishes: const [],
        reservable: true,
      );

      final choice = MenuChoice.from([empty], MealSlot.breakfast);
      expect(choice, isNotNull);
      expect(choice!.dishes, isEmpty);
      expect(choice.halls.map((h) => h.id), ['1']);
    });
  });
}
