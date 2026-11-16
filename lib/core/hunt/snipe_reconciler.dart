import '../meal/models.dart';
import '../portal/portal.dart';

/// What reconciliation concluded about an ambiguous claim.
enum ReconciliationOutcome {
  /// The claim did land: the account now holds the reservation.
  claimed,

  /// The claim did not land: the listing is not ours.
  notClaimed,

  /// Still unknown, because the re-read also failed.
  ///
  /// The safe answer. The caller must tombstone the listing and not retry,
  /// because a second claim on a listing that might already be ours is the
  /// double-purchase this whole path exists to prevent.
  indeterminate,
}

/// Resolves an ambiguous claim by re-reading ground truth.
///
/// The rule this enforces, from the spec: **never retry an ambiguous claim.**
/// A blind retry can buy two meals and charge twice. Instead, re-read the only
/// page that knows and ask whether the meal is now ours.
///
/// ## Why the buy page, and not the reservation grid
///
/// A basket purchase does **not** appear in the weekly reservation grid —
/// verified by a live purchase (2026-10-19), where the grids were byte-for-byte
/// identical before and after. It appears only in the transaction ledger and as
/// a held row on the buy page itself.
///
/// So a reconciler that re-read the reservation grid would conclude
/// `notClaimed` for every *successful* basket purchase, and the engine would
/// hunt on into a second, irreversible one. That is the exact failure this
/// class exists to prevent, so it reads the buy page.
class ClaimReconciler {
  const ClaimReconciler();

  /// Determines whether [listing] became a held meal.
  ///
  /// [client] must support [PortalClient.holdingsOnBuyPage]; the adapter
  /// reports what the buy page says about the listing's row.
  Future<ReconciliationOutcome> reconcile({
    required PortalClient client,
    required Session session,
    required Listing listing,
  }) async {
    try {
      final hold = await client.holdingsOnBuyPage(
        session,
        date: listing.date,
        optionId: listing.option.id,
      );

      // No row at all means the portal no longer shows this listing. It could
      // have been sold to someone else or withdrawn — either way it is not
      // ours, and the caller must not retry it.
      if (hold == null) return ReconciliationOutcome.notClaimed;

      return hold.isHeld
          ? ReconciliationOutcome.claimed
          : ReconciliationOutcome.notClaimed;
    } catch (_) {
      // The re-read failed. We genuinely do not know, and inventing an answer
      // here would be worse than admitting ignorance.
      return ReconciliationOutcome.indeterminate;
    }
  }
}
