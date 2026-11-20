import 'package:bahonar_nut/core/hunt/hunt_config.dart';
import 'package:bahonar_nut/core/hunt/hunt_ranker.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:test/test.dart';

const central = Hall(id: '1', name: 'مرکزی برادران');
const technical = Hall(id: '2', name: 'فنی برادران');

/// A market listing.
///
/// The [optionId] deliberately differs from the official menu's id for the
/// same dish: the market renumbers ids, and that is the fact the hunt has to
/// survive.
Listing marketListing({
  required String optionId,
  required String name,
  int priceRial = 350000,
  Hall hall = central,
  MealSlot slot = MealSlot.dinner,
  DateTime? date,
}) => Listing.composite(
  date: date ?? DateTime.utc(2026, 10, 28),
  slot: slot,
  hall: hall,
  option: MenuOption(id: optionId, name: name, priceRial: priceRial),
);

HuntConfig huntConfig({
  List<HuntDish>? dishes,
  List<HuntHall>? halls,
  MealSlot slot = MealSlot.dinner,
  int? maxPriceRial,
}) => HuntConfig(
  targetSlot: slot,
  dishPriority:
      dishes ??
      [HuntDish(optionId: '62742', name: 'لوبیا پلو', priceRial: 350000)],
  hallPriority: halls ?? const [],
);

void main() {
  const ranker = HuntRanker();

  group('matching across the renumbered market', () {
    // The verified fact (2026-10-20): the same dish, on the same date and
    // slot, is option 62737 in the weekly reservation grid and option 62798 on
    // the Food Basket buy page. Same name, same price, different id.
    test('a dish is found despite the market using a different option id', () {
      final config = huntConfig(
        dishes: [
          HuntDish(
            optionId: '62737',
            name: 'پنیر /گوجه /نان / چای /قند',
            priceRial: 150000,
          ),
        ],
        slot: MealSlot.breakfast,
      );

      final result = ranker.selectBest(
        config: config,
        listings: [
          marketListing(
            optionId: '62798',
            name: 'پنیر /گوجه /نان / چای /قند',
            priceRial: 150000,
            slot: MealSlot.breakfast,
          ),
        ],
      );

      expect(
        result.hasMatch,
        isTrue,
        reason: 'an id-based match would never fire on the wanted dish',
      );
      expect(result.best!.option.id, '62798');
    });

    test('the separator style does not hide a wanted dish', () {
      // The portal writes the same dish as "پنیر /گوجه" in one grid and
      // "پنیر/گوجه" in another, and uses both "," and "/" as separators.
      final config = huntConfig(
        dishes: [
          HuntDish(optionId: '62737', name: 'پنیر/گوجه/نان', priceRial: 150000),
        ],
      );

      final result = ranker.selectBest(
        config: config,
        listings: [
          marketListing(
            optionId: '62798',
            name: 'پنیر /گوجه /نان',
            priceRial: 150000,
          ),
        ],
      );

      expect(result.hasMatch, isTrue);
    });

    test('a dish nobody asked for is not bought', () {
      final config = huntConfig(
        dishes: [
          HuntDish(optionId: '62742', name: 'لوبیا پلو', priceRial: 350000),
        ],
      );

      final result = ranker.selectBest(
        config: config,
        listings: [
          marketListing(optionId: '99999', name: 'چلو گوشت', priceRial: 500000),
        ],
      );

      expect(result.hasMatch, isFalse);
      expect(result.considered.single.skipReason, HuntSkipReason.dishNotWanted);
    });
  });

  group('dish priority', () {
    test('the first choice wins over the second', () {
      final config = huntConfig(
        dishes: [
          HuntDish(optionId: 'a', name: 'لوبیا پلو', priceRial: 350000),
          HuntDish(optionId: 'b', name: 'چلو گوشت', priceRial: 500000),
        ],
      );

      final result = ranker.selectBest(
        config: config,
        listings: [
          marketListing(optionId: 'x', name: 'چلو گوشت', priceRial: 500000),
          marketListing(optionId: 'y', name: 'لوبیا پلو', priceRial: 350000),
        ],
      );

      expect(result.best!.option.name, 'لوبیا پلو');
    });

    test('the second choice is taken when the first is unavailable', () {
      final config = huntConfig(
        dishes: [
          HuntDish(optionId: 'a', name: 'لوبیا پلو', priceRial: 350000),
          HuntDish(optionId: 'b', name: 'چلو گوشت', priceRial: 500000),
        ],
      );

      final result = ranker.selectBest(
        config: config,
        listings: [
          marketListing(optionId: 'x', name: 'چلو گوشت', priceRial: 500000),
        ],
      );

      expect(result.best!.option.name, 'چلو گوشت');
    });

    test('a cheaper second choice does not outrank a dearer first choice', () {
      // The user asked for a dish, and the price is a ceiling, not a ranking
      // input. Sorting by price would buy the wrong food.
      final config = huntConfig(
        dishes: [
          HuntDish(optionId: 'a', name: 'لوبیا پلو', priceRial: 350000),
          HuntDish(optionId: 'b', name: 'چلو گوشت', priceRial: 500000),
        ],
      );

      final result = ranker.selectBest(
        config: config,
        listings: [
          marketListing(optionId: 'x', name: 'چلو گوشت', priceRial: 500000),
          marketListing(optionId: 'y', name: 'لوبیا پلو', priceRial: 350000),
        ],
      );

      expect(result.best!.option.name, 'لوبیا پلو');
    });
  });

  group('hall priority', () {
    test('only the chosen hall is bought', () {
      final config = huntConfig(
        dishes: [HuntDish(optionId: 'a', name: 'لوبیا پلو', priceRial: 350000)],
        halls: const [HuntHall(id: '2', name: 'فنی برادران')],
      );

      final result = ranker.selectBest(
        config: config,
        listings: [
          marketListing(optionId: 'x', name: 'لوبیا پلو', hall: central),
          marketListing(optionId: 'y', name: 'لوبیا پلو', hall: technical),
        ],
      );

      expect(result.best!.hall.id, '2');
    });

    test('the preferred hall wins when both offer the dish', () {
      final config = huntConfig(
        dishes: [HuntDish(optionId: 'a', name: 'لوبیا پلو', priceRial: 350000)],
        halls: const [
          HuntHall(id: '1', name: 'مرکزی برادران'),
          HuntHall(id: '2', name: 'فنی برادران'),
        ],
      );

      final result = ranker.selectBest(
        config: config,
        listings: [
          marketListing(optionId: 'x', name: 'لوبیا پلو', hall: technical),
          marketListing(optionId: 'y', name: 'لوبیا پلو', hall: central),
        ],
      );

      expect(result.best!.hall.id, '1');
    });

    test('the first dish outranks the second even in the better hall', () {
      // Dish-major ordering: "the first dish, then the second" means the
      // second dish in Central does not beat the first dish in Engineering.
      final config = huntConfig(
        dishes: [
          HuntDish(optionId: 'a', name: 'لوبیا پلو', priceRial: 350000),
          HuntDish(optionId: 'b', name: 'چلو گوشت', priceRial: 500000),
        ],
        halls: const [
          HuntHall(id: '1', name: 'مرکزی برادران'),
          HuntHall(id: '2', name: 'فنی برادران'),
        ],
      );

      final result = ranker.selectBest(
        config: config,
        listings: [
          marketListing(optionId: 'x', name: 'چلو گوشت', hall: central),
          marketListing(optionId: 'y', name: 'لوبیا پلو', hall: technical),
        ],
      );

      expect(result.best!.option.name, 'لوبیا پلو');
    });

    test('an empty hall list means any hall the market offers', () {
      final config = huntConfig(
        dishes: [HuntDish(optionId: 'a', name: 'لوبیا پلو', priceRial: 350000)],
        halls: const [],
      );

      final result = ranker.selectBest(
        config: config,
        listings: [
          marketListing(optionId: 'x', name: 'لوبیا پلو', hall: technical),
        ],
      );

      expect(result.hasMatch, isTrue);
      expect(result.best!.hall.id, '2');
    });

    test('a hall the user did not list is skipped, with its own reason', () {
      final config = huntConfig(
        dishes: [HuntDish(optionId: 'a', name: 'لوبیا پلو', priceRial: 350000)],
        halls: const [HuntHall(id: '1', name: 'مرکزی برادران')],
      );

      final result = ranker.selectBest(
        config: config,
        listings: [
          marketListing(optionId: 'x', name: 'لوبیا پلو', hall: technical),
        ],
      );

      expect(result.hasMatch, isFalse);
      expect(result.considered.single.skipReason, HuntSkipReason.hallNotWanted);
    });

    test('halls are matched by id, never by name', () {
      // The portal names halls per account, so the same id may arrive with a
      // different name. Matching on the name would buy nothing.
      final renamed = const Hall(id: '1', name: 'مرکزی خواهران');
      final config = huntConfig(
        dishes: [HuntDish(optionId: 'a', name: 'لوبیا پلو', priceRial: 350000)],
        halls: const [HuntHall(id: '1', name: 'مرکزی برادران')],
      );

      final result = ranker.selectBest(
        config: config,
        listings: [
          marketListing(optionId: 'x', name: 'لوبیا پلو', hall: renamed),
        ],
      );

      expect(result.hasMatch, isTrue);
    });
  });

  group('the price ceiling', () {
    test('a listing above the ceiling is skipped', () {
      final config = huntConfig(
        dishes: [HuntDish(optionId: 'a', name: 'لوبیا پلو', priceRial: 350000)],
      );

      final result = ranker.selectBest(
        config: config,
        listings: [
          marketListing(optionId: 'x', name: 'لوبیا پلو', priceRial: 500000),
        ],
        maxPriceRial: 350000,
      );

      expect(result.hasMatch, isFalse);
      expect(result.considered.single.skipReason, HuntSkipReason.overMaxPrice);
    });

    test('a listing at exactly the ceiling is bought', () {
      final config = huntConfig(
        dishes: [HuntDish(optionId: 'a', name: 'لوبیا پلو', priceRial: 350000)],
      );

      final result = ranker.selectBest(
        config: config,
        listings: [
          marketListing(optionId: 'x', name: 'لوبیا پلو', priceRial: 350000),
        ],
        maxPriceRial: 350000,
      );

      expect(result.hasMatch, isTrue);
    });

    test('per-dish ceiling is enforced when maxPriceRial is higher', () {
      final config = huntConfig(
        dishes: [
          HuntDish(optionId: 'a', name: 'عدسی', priceRial: 150000),
          HuntDish(optionId: 'b', name: 'کباب', priceRial: 600000),
        ],
      );

      // maxPriceRial is 600,000 (from the dearer dish), but adasi is listed at 250,000
      final result = ranker.selectBest(
        config: config,
        listings: [
          marketListing(optionId: 'x', name: 'عدسی', priceRial: 250000),
        ],
        maxPriceRial: 600000,
      );

      expect(result.hasMatch, isFalse);
      expect(result.considered.single.skipReason, HuntSkipReason.overMaxPrice);
    });
  });

  group('scope', () {
    test('a listing in another slot is not considered', () {
      final config = huntConfig(
        dishes: [HuntDish(optionId: 'a', name: 'لوبیا پلو', priceRial: 350000)],
        slot: MealSlot.dinner,
      );

      final result = ranker.selectBest(
        config: config,
        listings: [
          marketListing(optionId: 'x', name: 'لوبیا پلو', slot: MealSlot.lunch),
        ],
      );

      expect(result.hasMatch, isFalse);
      expect(result.considered, isEmpty);
    });
  });
}
