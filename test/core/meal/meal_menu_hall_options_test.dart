import 'package:bahonar_nut/core/meal/local_menu_store.dart';
import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/shared/platform_stores.dart';
import 'package:test/test.dart';

/// Hall-specific dish identities (optimization plan C3) and reservation
/// substitution detection (C4).
///
/// ## What these pin
///
/// The portal publishes one `drpFood` list per rendered row, and that list
/// belongs to **one** hall. The same lunch is `64574`/`64576` in hall 1 and
/// `64639`/`64641` in hall 2 — same names, same prices, different ids. Posting
/// a hall-1 id with hall 2 makes the portal silently save hall 2's first
/// option, so an id is only meaningful together with the hall that produced
/// it.
///
/// [MealMenu.optionsByHall] records which list came from which hall, and
/// [MealMenu.dishesForHall] is the only safe way to ask what a hall offers. A
/// hall whose list was never read has no entry; filling it in from another
/// hall's ids is exactly the bug these tests exist to prevent.
void main() {
  final date = DateTime.utc(2026, 11, 25);
  const hall1 = Hall(id: '1', name: 'مرکزی');
  const hall2 = Hall(id: '2', name: 'فنی');

  const hall1Dishes = [
    MenuOption(id: '64574', name: 'چلو اکبرجوجه', priceRial: 500000),
    MenuOption(id: '64576', name: 'شوید پلو', priceRial: 350000),
  ];
  const hall2Dishes = [
    MenuOption(id: '64639', name: 'چلو اکبرجوجه', priceRial: 500000),
    MenuOption(id: '64641', name: 'شوید پلو', priceRial: 350000),
  ];

  group('MealMenu.dishesForHall', () {
    test('returns the list actually read for the hall', () {
      final menu = MealMenu(
        date: date,
        slot: MealSlot.lunch,
        halls: const [hall1, hall2],
        dishes: hall1Dishes,
        reservable: true,
        optionsByHall: const {'1': hall1Dishes, '2': hall2Dishes},
      );

      expect(menu.dishesForHall('1').map((d) => d.id), ['64574', '64576']);
      expect(menu.dishesForHall('2').map((d) => d.id), ['64639', '64641']);
    });

    test('a hall that was not read has no dishes, not another hall\'s', () {
      final menu = MealMenu(
        date: date,
        slot: MealSlot.lunch,
        halls: const [hall1, hall2],
        dishes: hall1Dishes,
        reservable: true,
        // Only hall 1 was read.
        optionsByHall: const {'1': hall1Dishes},
      );

      expect(
        menu.dishesForHall('2'),
        isEmpty,
        reason:
            'hall 2\'s ids were never read; handing back hall 1\'s ids would '
            'pair a hall with a dish it does not own (C3)',
      );
    });

    test('a legacy menu without per-hall ids shares its one list', () {
      // Menus built before hall-specific ids were modelled carry an empty map.
      // Falling back to `dishes` keeps them working; the fallback is the old
      // assumption, and it only applies when nothing hall-specific is known.
      final menu = MealMenu(
        date: date,
        slot: MealSlot.lunch,
        halls: const [hall1, hall2],
        dishes: hall1Dishes,
        reservable: true,
      );

      expect(menu.hasHallOptions, isFalse);
      expect(menu.dishesForHall('1'), same(hall1Dishes));
      expect(menu.dishesForHall('2'), same(hall1Dishes));
    });
  });

  group('MealMenu.offers / optionFor', () {
    final menu = MealMenu(
      date: date,
      slot: MealSlot.lunch,
      halls: const [hall1, hall2],
      dishes: hall1Dishes,
      reservable: true,
      optionsByHall: const {'1': hall1Dishes, '2': hall2Dishes},
    );

    test('accepts a pair the portal read for that hall', () {
      expect(menu.offers('2', '64641'), isTrue);
      expect(menu.optionFor('2', '64641')?.name, 'شوید پلو');
    });

    test('rejects a dish id read for a different hall', () {
      expect(
        menu.offers('2', '64576'),
        isFalse,
        reason:
            '64576 is hall 1\'s id; hall 2 never offered it, so posting the '
            'pair would let the portal substitute (C3)',
      );
      expect(menu.optionFor('2', '64576'), isNull);
    });

    test('rejects a hall whose list was never read', () {
      final partial = MealMenu(
        date: date,
        slot: MealSlot.lunch,
        halls: const [hall1, hall2],
        dishes: hall1Dishes,
        reservable: true,
        optionsByHall: const {'1': hall1Dishes},
      );
      expect(partial.offers('2', '64574'), isFalse);
    });
  });

  group('MealOffering.matches', () {
    final offering = MealOffering(
      date: date,
      slot: MealSlot.lunch,
      hall: hall2,
      option: hall2Dishes[1],
      reservable: true,
    );

    Reservation reservation({
      DateTime? on,
      MealSlot slot = MealSlot.lunch,
      Hall hall = hall2,
      MenuOption? option,
    }) => Reservation(
      id: 'r1',
      date: on ?? date,
      slot: slot,
      hall: hall,
      option: option ?? hall2Dishes[1],
      state: ReservationState.active,
    );

    test('matches the same date, slot, hall and dish', () {
      expect(offering.matches(reservation()), isTrue);
    });

    test('does not match the same row holding a different dish (C4)', () {
      expect(
        offering.matches(reservation(option: hall2Dishes[0])),
        isFalse,
        reason:
            'a different dish in the same row is a substitution, not a clean '
            'success',
      );
    });

    test('does not match the same row in a different hall (C4)', () {
      expect(
        offering.matches(reservation(hall: hall1)),
        isFalse,
        reason: 'the portal can save another hall; that is not this offering',
      );
    });

    test('does not match a different slot', () {
      expect(offering.matches(reservation(slot: MealSlot.dinner)), isFalse);
    });

    test('does not match a different day', () {
      expect(
        offering.matches(reservation(on: DateTime.utc(2026, 11, 26))),
        isFalse,
      );
    });
  });

  group('LocalMenuStore optionsByHall persistence and merging (B1)', () {
    test('upsert merges optionsByHall from multiple hall reads without data loss', () {
      final store = LocalMenuStore();
      final menuHall1 = MealMenu(
        date: date,
        slot: MealSlot.lunch,
        halls: const [hall1, hall2],
        dishes: hall1Dishes,
        optionsByHall: const {'1': hall1Dishes},
        reservable: true,
      );

      store.upsert([menuHall1]);
      var stored = store.find(date, MealSlot.lunch);
      expect(stored, isNotNull);
      expect(stored!.optionsByHall.containsKey('1'), isTrue);
      expect(stored.optionsByHall['1'], hall1Dishes);
      expect(stored.optionsByHall.containsKey('2'), isFalse);

      // Now read hall 2 and upsert: optionsByHall must merge, not overwrite or drop
      final menuHall2 = MealMenu(
        date: date,
        slot: MealSlot.lunch,
        halls: const [hall1, hall2],
        dishes: hall2Dishes,
        optionsByHall: const {'2': hall2Dishes},
        reservable: true,
      );

      store.upsert([menuHall2]);
      stored = store.find(date, MealSlot.lunch);
      expect(stored, isNotNull);
      expect(stored!.optionsByHall.containsKey('1'), isTrue, reason: 'hall 1 options must survive');
      expect(stored.optionsByHall['1'], hall1Dishes);
      expect(stored.optionsByHall.containsKey('2'), isTrue, reason: 'hall 2 options must be merged');
      expect(stored.optionsByHall['2'], hall2Dishes);
    });

    test('hasChanges detects newly read hall options', () {
      final store = LocalMenuStore();
      final menu1 = MealMenu(
        date: date,
        slot: MealSlot.lunch,
        halls: const [hall1, hall2],
        dishes: hall1Dishes,
        optionsByHall: const {'1': hall1Dishes},
        reservable: true,
      );
      store.upsert([menu1]);

      final menuWithHall2 = MealMenu(
        date: date,
        slot: MealSlot.lunch,
        halls: const [hall1, hall2],
        dishes: hall1Dishes,
        optionsByHall: const {'1': hall1Dishes, '2': hall2Dishes},
        reservable: true,
      );
      expect(store.hasChanges([menuWithHall2]), isTrue);
    });

    test('encodeMenuList and decodeMenuList round-trip preserves optionsByHall', () {
      final menu = MealMenu(
        date: date,
        slot: MealSlot.lunch,
        halls: const [hall1, hall2],
        dishes: hall1Dishes,
        optionsByHall: const {
          '1': hall1Dishes,
          '2': hall2Dishes,
        },
        reservable: true,
      );

      final encoded = encodeMenuList([menu]);
      final decoded = decodeMenuList(encoded);

      expect(decoded, hasLength(1));
      final restored = decoded.single;
      expect(restored.date, menu.date);
      expect(restored.slot, menu.slot);
      expect(restored.optionsByHall, hasLength(2));
      expect(restored.optionsByHall['1']?.map((o) => o.id), ['64574', '64576']);
      expect(restored.optionsByHall['2']?.map((o) => o.id), ['64639', '64641']);
      expect(restored.dishesForHall('1'), hasLength(2));
      expect(restored.dishesForHall('2'), hasLength(2));
    });
  });
}
