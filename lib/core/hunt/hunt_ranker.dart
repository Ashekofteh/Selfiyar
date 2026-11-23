/// Ranking for the hunt: which market listing, if any, to buy.
///
/// ## Why this is not [PriorityRanker]
///
/// The reservation ranker matches on `(hallId, optionId)`. The hunt cannot,
/// because **the market renumbers option ids**: the same dish on the same
/// date is option `62737` in the weekly reservation grid and option `62798` on
/// the Food Basket buy page — the same name, the same price, a different id.
/// A hunt that matched on ids would therefore never fire on the very dish the
/// user picked.
///
/// So the hunt matches on the **dish name** and applies the **hall** as a
/// separate filter. The buy page, however, renders the food dropdown for one
/// selected hall at a time: the food ids belong to that hall, and the other
/// halls are postback targets, not options in the same response. The adapter
/// therefore emits listings only for the hall it actually read, and the ranker
/// can only choose among those. A hall the poll did not read is invisible, not
/// fabricated; reading it requires a separate postback.
///
/// ## The ordering
///
/// Dish first, hall second. "Akbar Joojeh in Central, else Akbar Joojeh in
/// Engineering, else the second dish" is the order a user reads their own
/// preference list in, and the order that spends the least money for the most
/// preferred outcome. The two lists are a cartesian product, ordered
/// dish-major.
///
/// ## Everything is a strict whitelist
///
/// The hunt spends real money on an irreversible purchase, so a listing the
/// user did not name is never bought. A dish not on the list is skipped; a
/// hall not on the list is skipped. An empty hall list means "any hall the
/// portal offers", which is the one exception, because there the user has
/// expressed no opinion about halls at all.
library;

import 'dart:math' as math;

import 'hunt_config.dart';
import '../meal/models.dart';

/// Why a market listing was not bought.
enum HuntSkipReason {
  /// The listing's dish is not on the priority list.
  dishNotWanted,

  /// The listing's hall is not on the priority list.
  hallNotWanted,

  /// The listing is dearer than the hunt's ceiling.
  overMaxPrice,

  /// The portal has closed the row: the cutoff passed, the row is full, or the
  /// account already holds that meal. The page does not say which.
  rowClosed,
}

/// A listing the hunt considered, with the reason it was skipped.
class HuntCandidate {
  const HuntCandidate({required this.listing, this.rank, this.skipReason});

  final Listing listing;

  /// The position in the hunt's preference order, or null when skipped.
  final int? rank;

  /// Why the listing was skipped, or null when it is eligible.
  final HuntSkipReason? skipReason;

  bool get isEligible => skipReason == null && rank != null;

  @override
  String toString() =>
      'HuntCandidate(${listing.option.name}, rank=$rank, $skipReason)';
}

/// The outcome of ranking one basket page.
class HuntRankResult {
  const HuntRankResult({required this.best, required this.considered});

  /// The listing to buy, or null when nothing on the page qualifies.
  final Listing? best;

  /// Every listing examined, eligible first, with skip reasons.
  final List<HuntCandidate> considered;

  bool get hasMatch => best != null;
}

/// Selects the listing a hunt should buy from a basket page.
class HuntRanker {
  const HuntRanker();

  /// Ranks [listings] against [config].
  ///
  /// [maxPriceRial] is the hunt's price ceiling. A listing above it is
  /// skipped, not clamped: a meal that costs more than the user allowed is
  /// not a cheaper meal, it is a different meal.
  HuntRankResult selectBest({
    required HuntConfig config,
    required Iterable<Listing> listings,
    int? maxPriceRial,
  }) {
    final considered = <HuntCandidate>[];

    // The hall list, when the user chose one, is a whitelist of hall ids.
    // An empty list means any hall.
    final allowedHalls = config.hallPriority.map((h) => h.id).toSet();
    final hallRestricted = config.hallPriority.isNotEmpty;

    for (final listing in listings) {
      if (listing.slot != config.targetSlot) continue;

      // A closed row is never a purchase candidate, whatever its dish or
      // price. The parser normally omits these; this check is the ranker's own
      // guarantee, independent of how the listing was produced.
      if (!listing.buyable) {
        considered.add(
          HuntCandidate(listing: listing, skipReason: HuntSkipReason.rowClosed),
        );
        continue;
      }

      // The dish is checked first, and on its own: a listing whose dish is
      // not wanted is reported as such, whatever its hall. Conflating the two
      // would tell the user "that hall is not allowed" when the truth is
      // "that food is not on your list".
      final dishIndex = _dishIndexOf(config, listing);
      if (dishIndex == null) {
        considered.add(
          HuntCandidate(
            listing: listing,
            skipReason: HuntSkipReason.dishNotWanted,
          ),
        );
        continue;
      }

      if (hallRestricted && !allowedHalls.contains(listing.hall.id)) {
        considered.add(
          HuntCandidate(
            listing: listing,
            skipReason: HuntSkipReason.hallNotWanted,
          ),
        );
        continue;
      }

      final rank = _rankOf(config, listing, dishIndex);

      final perDish = config.dishPriority[dishIndex].priceRial;
      final ceiling = maxPriceRial == null
          ? perDish
          : math.min(perDish, maxPriceRial);
      if (listing.priceRial > ceiling) {
        considered.add(
          HuntCandidate(
            listing: listing,
            rank: rank,
            skipReason: HuntSkipReason.overMaxPrice,
          ),
        );
        continue;
      }

      considered.add(HuntCandidate(listing: listing, rank: rank));
    }

    final eligible = <HuntCandidate>[];
    final skipped = <HuntCandidate>[];
    for (final c in considered) {
      if (c.isEligible) {
        eligible.add(c);
      } else {
        skipped.add(c);
      }
    }
    eligible.sort(_byRankThenPrice);
    skipped.sort((a, b) => a.listing.priceRial.compareTo(b.listing.priceRial));

    return HuntRankResult(
      best: eligible.isEmpty ? null : eligible.first.listing,
      considered: [...eligible, ...skipped],
    );
  }

  /// The position of a listing in the hunt's preference order.
  ///
  /// The order is dish-major: the first dish in every allowed hall comes
  /// before the second dish in any hall.
  int _rankOf(HuntConfig config, Listing listing, int dishIndex) {
    final halls = config.hallPriority;
    if (halls.isEmpty) {
      // Any hall: the dish order alone decides.
      return dishIndex;
    }

    final hallIndex = halls.indexWhere((h) => h.id == listing.hall.id);
    if (hallIndex < 0) return dishIndex;

    return dishIndex * halls.length + hallIndex;
  }

  /// The index of the listing's dish in the priority list, or null.
  int? _dishIndexOf(HuntConfig config, Listing listing) {
    final key = listing.option.dishKey;
    for (var i = 0; i < config.dishPriority.length; i++) {
      if (config.dishPriority[i].dishKey == key) return i;
    }
    return null;
  }

  static int _byRankThenPrice(HuntCandidate a, HuntCandidate b) {
    final byRank = a.rank!.compareTo(b.rank!);
    if (byRank != 0) return byRank;
    return a.listing.priceRial.compareTo(b.listing.priceRial);
  }
}
