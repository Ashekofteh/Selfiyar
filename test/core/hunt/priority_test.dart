import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/hunt/priority.dart';
import 'package:test/test.dart';

const central = Hall(id: '1', name: 'مرکزی برادران');
const technical = Hall(id: '2', name: 'فنی برادران');

MenuOption opt(String id, int price) =>
    MenuOption(id: id, name: 'dish $id', priceRial: price);

final optA = opt('62702', 350000);
final optB = opt('62714', 500000);

Listing listing({
  required String id,
  required Hall hall,
  required MenuOption option,
  MealSlot slot = MealSlot.lunch,
}) =>
    Listing(
      id: id,
      date: DateTime.utc(2026, 10, 20),
      slot: slot,
      hall: hall,
      option: option,
    );

/// Preferences: Central/A first, then Central/B, then Technical/A.
/// Preferred dishes before the less-preferred hall, exercising the exact
/// conflict the user described (preferred dish in the less-preferred hall).
SlotPreference lunchPreference({Set<int> rejectedRanks = const {}}) {
  final pairs = [
    PreferencePair(hallId: central.id, optionId: optA.id),
    PreferencePair(hallId: central.id, optionId: optB.id),
    PreferencePair(hallId: technical.id, optionId: optA.id),
    PreferencePair(hallId: technical.id, optionId: optB.id),
  ];
  for (final r in rejectedRanks) {
    pairs[r] = pairs[r].reject();
  }
  return SlotPreference(slot: MealSlot.lunch, ranked: pairs);
}

void main() {
  const ranker = PriorityRanker();

  group('basic selection', () {
    test('picks the highest-ranked available listing', () {
      final result = ranker.selectBest(
        preference: lunchPreference(),
        listings: [
          listing(id: 'L3', hall: technical, option: optA), // rank 2
          listing(id: 'L1', hall: central, option: optA), // rank 0  <- best
          listing(id: 'L2', hall: central, option: optB), // rank 1
        ],
      );
      expect(result.best?.id, 'L1');
      expect(result.hasMatch, isTrue);
    });

    test('returns no match on empty inventory', () {
      final result =
          ranker.selectBest(preference: lunchPreference(), listings: const []);
      expect(result.best, isNull);
      expect(result.hasMatch, isFalse);
      expect(result.considered, isEmpty);
    });

    test('skips listings from other meal slots', () {
      final result = ranker.selectBest(
        preference: lunchPreference(),
        listings: [
          listing(id: 'B1', hall: central, option: optA, slot: MealSlot.breakfast),
          listing(id: 'L1', hall: central, option: optB),
        ],
      );
      expect(result.best?.id, 'L1');
      expect(result.considered.length, 1, reason: 'breakfast filtered out entirely');
    });
  });

  group('rejection (veto)', () {
    test('never buys a vetoed pair even if it is the only option', () {
      final result = ranker.selectBest(
        preference: lunchPreference(rejectedRanks: {0}),
        listings: [listing(id: 'L1', hall: central, option: optA)], // rank 0, vetoed
      );
      expect(result.best, isNull);
      expect(
        result.considered.single.rejection,
        RejectionReason.vetoed,
      );
    });

    test('falls through to the next rank when the top is vetoed', () {
      final result = ranker.selectBest(
        preference: lunchPreference(rejectedRanks: {0}),
        listings: [
          listing(id: 'L1', hall: central, option: optA), // vetoed
          listing(id: 'L2', hall: central, option: optB), // rank 1 -> wins
        ],
      );
      expect(result.best?.id, 'L2');
    });
  });

  group('price ceiling', () {
    test('excludes listings above maxPriceRial', () {
      final result = ranker.selectBest(
        preference: lunchPreference(),
        listings: [
          listing(id: 'expensive', hall: central, option: optB), // 500000
          listing(id: 'cheap', hall: technical, option: optA), // 350000
        ],
        maxPriceRial: 400000,
      );
      expect(result.best?.id, 'cheap');
      expect(
        result.considered
            .firstWhere((c) => c.listing.id == 'expensive')
            .rejection,
        RejectionReason.overMaxPrice,
      );
    });

    test('price ceiling beats preference rank', () {
      // Rank 0 is over budget; must not be bought even though it outranks everything.
      final result = ranker.selectBest(
        preference: lunchPreference(),
        listings: [listing(id: 'L1', hall: central, option: optA)],
        maxPriceRial: 1,
      );
      expect(result.best, isNull);
    });

    test('null ceiling means no price limit', () {
      final result = ranker.selectBest(
        preference: lunchPreference(),
        listings: [listing(id: 'L1', hall: central, option: optB)],
      );
      expect(result.best?.id, 'L1');
    });
  });

  group('unlisted pairs', () {
    test('requireListed=true refuses pairs the user never ranked', () {
      final unknownOption = opt('99999', 350000);
      final result = ranker.selectBest(
        preference: lunchPreference(),
        listings: [listing(id: 'X', hall: central, option: unknownOption)],
      );
      expect(result.best, isNull);
      expect(
        result.considered.single.rejection,
        RejectionReason.notInPreferenceList,
      );
    });

    test('requireListed=false allows unlisted pairs, ranked last', () {
      final unknownOption = opt('99999', 350000);
      final result = ranker.selectBest(
        preference: lunchPreference(),
        listings: [
          listing(id: 'X', hall: central, option: unknownOption),
          listing(id: 'L2', hall: central, option: optB), // rank 1
        ],
        requireListed: false,
      );
      expect(result.best?.id, 'L2', reason: 'listed pair outranks unlisted');
    });
  });

  group('determinism', () {
    test('tie on rank breaks toward the cheaper listing', () {
      // Two listings, same (hall, option) pair, different prices.
      final cheap = MenuOption(
          id: optA.id, name: 'dish', priceRial: 300000);
      final pricey = MenuOption(
          id: optA.id, name: 'dish', priceRial: 400000);
      final result = ranker.selectBest(
        preference: lunchPreference(),
        listings: [
          listing(id: 'pricey', hall: central, option: pricey),
          listing(id: 'cheap', hall: central, option: cheap),
        ],
      );
      expect(result.best?.id, 'cheap');
    });
  });

  group('property: the ranker always picks the highest-ranked eligible listing', () {
    test('holds across every subset of a 4-listing inventory', () {
      final all = [
        listing(id: 'L0', hall: central, option: optA), // rank 0
        listing(id: 'L1', hall: central, option: optB), // rank 1
        listing(id: 'L2', hall: technical, option: optA), // rank 2
        listing(id: 'L3', hall: technical, option: optB), // rank 3
      ];

      // Every one of the 16 subsets.
      for (var mask = 0; mask < 16; mask++) {
        final subset = <Listing>[];
        for (var bit = 0; bit < 4; bit++) {
          if (mask & (1 << bit) != 0) subset.add(all[bit]);
        }

        // No vetoes: expectation is simply the lowest index present.
        final result =
            ranker.selectBest(preference: lunchPreference(), listings: subset);
        if (subset.isEmpty) {
          expect(result.best, isNull, reason: 'mask=$mask');
        } else {
          final expectedRank = subset
              .map((l) => int.parse(l.id.substring(1)))
              .reduce((a, b) => a < b ? a : b);
          expect(result.best?.id, 'L$expectedRank', reason: 'mask=$mask');
        }
      }
    });

    test('holds when the top-ranked pair is vetoed', () {
      for (var topRank = 0; topRank < 4; topRank++) {
        final all = [
          listing(id: 'L0', hall: central, option: optA),
          listing(id: 'L1', hall: central, option: optB),
          listing(id: 'L2', hall: technical, option: optA),
          listing(id: 'L3', hall: technical, option: optB),
        ];
        final result = ranker.selectBest(
          preference: lunchPreference(rejectedRanks: {topRank}),
          listings: all,
        );
        // Buy the lowest-ranked-eligible: the first index that is not vetoed.
        final expected =
            List.generate(4, (i) => i).firstWhere((i) => i != topRank);
        expect(result.best?.id, 'L$expected', reason: 'vetoed rank $topRank');
      }
    });
  });

  group('SlotPreference queries', () {
    test('rankOf finds pairs and returns null for unknown ones', () {
      final p = lunchPreference();
      expect(p.rankOf(hallId: central.id, optionId: optA.id), 0);
      expect(p.rankOf(hallId: technical.id, optionId: optB.id), 3);
      expect(p.rankOf(hallId: 'nope', optionId: 'nope'), isNull);
    });

    test('isRejected is false for unlisted pairs (absence is not a veto)', () {
      final p = lunchPreference();
      expect(p.isRejected(hallId: 'nope', optionId: 'nope'), isFalse);
    });
  });
}