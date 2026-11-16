/// Priority ranking: deciding which listing to buy.
///
/// The rule is an *ordered list* of (hall, option) pairs rather than a weighted
/// score. Under auto-buy the purchase spends real money, so the user must be able
/// to read the preference top-to-bottom and know exactly what will be bought.
/// A weighted score forces them to reason about a formula, and a mis-tuned weight
/// silently buys food they did not want.
library;

import '../meal/models.dart';

/// One row of a user's ranked preference for a meal slot.
///
/// [rejected] is an explicit veto, distinct from mere low ranking: a rejected
/// pair is never bought even when it is the only thing available.
class PreferencePair {
  const PreferencePair({
    required this.hallId,
    required this.optionId,
    this.rejected = false,
  });

  final HallId hallId;
  final OptionId optionId;
  final bool rejected;

  PreferencePair reject() =>
      PreferencePair(hallId: hallId, optionId: optionId, rejected: true);

  @override
  String toString() =>
      'PreferencePair($hallId/$optionId${rejected ? ', rejected' : ''})';
}

/// A user's full preference configuration for one meal slot.
///
/// [ranked] is highest-priority-first. Rows are matched by `(hallId, optionId)`;
/// the ranker never relies on list position for anything except ordering.
class SlotPreference {
  SlotPreference({required this.slot, required List<PreferencePair> ranked})
      : ranked = List.unmodifiable(ranked);

  final MealSlot slot;
  final List<PreferencePair> ranked;

  /// Rank of a given pair, or `null` if it is not in the list at all.
  ///
  /// A pair absent from the list is *not* implicitly rejected — see
  /// [PriorityRanker.selectBest] for why that distinction is deliberate.
  int? rankOf({required HallId hallId, required OptionId optionId}) {
    for (var i = 0; i < ranked.length; i++) {
      final p = ranked[i];
      if (p.hallId == hallId && p.optionId == optionId) return i;
    }
    return null;
  }

  bool isRejected({required HallId hallId, required OptionId optionId}) {
    final r = rankOf(hallId: hallId, optionId: optionId);
    return r != null && ranked[r].rejected;
  }
}

/// Why a candidate was not chosen, for logging and dry-run explanations.
enum RejectionReason {
  /// The pair is explicitly vetoed in the preference list.
  vetoed,

  /// The pair is not present in the preference list, and the policy is to only
  /// accept listed pairs.
  notInPreferenceList,

  /// The listing's hall is not one the hunt is willing to buy from.
  ///
  /// Distinct from [notInPreferenceList]: the dish was wanted, the hall was
  /// not, and the user said so explicitly.
  hallNotInPreferenceList,

  /// Above the rule's price ceiling.
  overMaxPrice,
}

/// A listing plus the reason it was considered or skipped.
class RankedCandidate {
  const RankedCandidate({
    required this.listing,
    this.rank,
    this.rejection,
  });

  final Listing listing;
  final int? rank;
  final RejectionReason? rejection;

  bool get isEligible => rejection == null && rank != null;
}

/// The outcome of ranking an inventory snapshot.
class RankResult {
  const RankResult({required this.best, required this.considered});

  /// The listing to buy, or `null` if nothing is eligible.
  final Listing? best;

  /// Every candidate examined, in preference order, with skip reasons.
  /// Kept so the UI and dry-run log can explain a decision.
  final List<RankedCandidate> considered;

  bool get hasMatch => best != null;
}

/// Selects the highest-ranked eligible listing from an inventory snapshot.
class PriorityRanker {
  const PriorityRanker();

  /// Pure selection. No I/O, no clock, no randomness — so it is fully testable
  /// and its behaviour under auto-buy is predictable.
  ///
  /// Ordering is by preference rank, then by price ascending as a deterministic
  /// tie-break (cheaper first — the conservative choice when spending money).
  ///
  /// [requireListed] controls unlisted pairs. Left `true` (the default) the sniper
  /// only buys what the user explicitly ranked: an unlisted pair means the portal
  /// offered something the user never expressed an opinion about, and guessing
  /// there would spend money on an unreviewed choice. This is deliberately
  /// conservative and should stay that way for auto-buy.
  RankResult selectBest({
    required SlotPreference preference,
    required Iterable<Listing> listings,
    int? maxPriceRial,
    bool requireListed = true,
  }) {
    final considered = <RankedCandidate>[];

    for (final listing in listings) {
      if (listing.slot != preference.slot) continue;

      // Price ceiling first: cheapest rejection test, and it is a hard gate.
      if (maxPriceRial != null && listing.priceRial > maxPriceRial) {
        considered.add(RankedCandidate(
            listing: listing, rejection: RejectionReason.overMaxPrice));
        continue;
      }

      final rank = preference.rankOf(
        hallId: listing.hall.id,
        optionId: listing.option.id,
      );

      if (rank == null) {
        // Unlisted pair: eligible only if the caller opted out of the whitelist.
        considered.add(RankedCandidate(
          listing: listing,
          rank: requireListed ? null : preference.ranked.length,
          rejection:
              requireListed ? RejectionReason.notInPreferenceList : null,
        ));
        continue;
      }

      if (preference.ranked[rank].rejected) {
        considered.add(RankedCandidate(
            listing: listing, rank: rank, rejection: RejectionReason.vetoed));
        continue;
      }

      considered.add(RankedCandidate(listing: listing, rank: rank));
    }

    final eligible = considered.where((c) => c.isEligible).toList();
    if (eligible.isEmpty) {
      return RankResult(best: null, considered: _sorted(considered));
    }

    eligible.sort(_byRankThenPrice);
    return RankResult(best: eligible.first.listing, considered: _sorted(considered));
  }

  /// Presentation order: eligible first by rank, then skipped ones.
  static List<RankedCandidate> _sorted(List<RankedCandidate> candidates) {
    final eligible = candidates.where((c) => c.isEligible).toList()
      ..sort(_byRankThenPrice);
    final skipped = candidates.where((c) => !c.isEligible).toList()
      ..sort((a, b) => a.listing.priceRial.compareTo(b.listing.priceRial));
    return [...eligible, ...skipped];
  }

  static int _byRankThenPrice(RankedCandidate a, RankedCandidate b) {
    final byRank = a.rank!.compareTo(b.rank!);
    if (byRank != 0) return byRank;
    return a.listing.priceRial.compareTo(b.listing.priceRial);
  }
}