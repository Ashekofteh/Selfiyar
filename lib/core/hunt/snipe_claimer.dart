/// Claim execution: the one place that is allowed to spend money.
///
/// Kept apart from the engine loop so that the dangerous part has a small,
/// reviewable surface. The loop decides *when* to claim; this file decides
/// *what a claim means*.
///
/// Three rules are encoded here, and none of them may move:
///
///   1. **One claim at a time per run.** [SnipeClaimer.execute] is called only
///      from the engine's sequential loop, and it never starts work of its own.
///      Two claims in flight for one account is the double purchase.
///   2. **Ambiguity is never a failure.** A thrown claim, a timeout, or a
///      transport error goes through [ClaimReconciler], never through a retry.
///   3. **A reconciled purchase is a purchase.** If the re-read says the meal
///      is ours, the ledger records it and the run ends claimed — the student
///      was charged, so the app must say so.
///
/// The claimer reports what happened through [ClaimExecution] and leaves the
/// notifications to the engine: the listener is settable after construction, so
/// a collaborator that captured it would post an outcome to the wrong place.
library;

import '../meal/models.dart';
import '../portal/portal.dart';
import '../shared/ledger.dart';
import 'snipe.dart';
import 'snipe_reconciler.dart';
import 'tombstone.dart';

/// The slice of one live run that claim execution needs.
///
/// An interface rather than the engine's private run type, so this file can be
/// tested with a plain fake and cannot reach into loop state it does not own.
abstract class ClaimRunContext {
  /// The rule being hunted.
  SnipeRule get rule;

  /// Where claim decisions are recorded for the user to read afterwards.
  SnipeLedger get ledger;

  /// Listings that must never be attempted again.
  TombstoneSet get tombstones;

  /// True when the user has stopped the run.
  bool get isCancelled;

  /// Moves the run to [next], unless it has been cancelled.
  void transitionTo(SnipeState next);

  /// Ends the run in [state], with [reason] shown to the student.
  void finishWith(SnipeState state, String reason);

  /// Records that [listingId] became the run's purchase.
  void markClaimed(ListingId listingId);

  /// Counts one purchase at [at].
  void countPurchase(DateTime at);
}

/// What one call to [SnipeClaimer.execute] produced.
///
/// The engine turns this into the listener callback, because only the engine
/// owns the listener.
class ClaimExecution {
  const ClaimExecution._({this.reservation, this.endedState, this.endedReason});

  /// A claim that did not end the run: it was rejected, or it was ambiguous
  /// and reconciliation found no purchase. The hunt continues.
  const ClaimExecution.ongoing() : this._();

  /// A dry run: nothing was written, but the run ends as it would have.
  const ClaimExecution.dryRun()
    : this._(endedState: SnipeState.claimed, endedReason: 'dry run match');

  /// A confirmed purchase. [reservation] is what the listener reports.
  const ClaimExecution.claimed(
    Reservation reservation, {
    String reason = 'claimed',
  }) : this._(
         reservation: reservation,
         endedState: SnipeState.claimed,
         endedReason: reason,
       );

  /// The reservation, when a purchase is confirmed. Null for a dry run and
  /// for a claim that did not land.
  final Reservation? reservation;

  /// The terminal state, when this claim ended the run.
  final SnipeState? endedState;

  /// Why the run ended, in words for the student.
  final String? endedReason;

  /// Whether this claim ended the run.
  bool get ended => endedState != null;
}

/// Executes claims and reconciles them when the outcome is unknown.
///
/// Stateless apart from its collaborators: the run's mutable state arrives in
/// each call as a [ClaimRunContext], so the executor cannot remember a listing
/// and cannot retry one by accident.
class SnipeClaimer {
  const SnipeClaimer({
    required this._client,
    this._reconciler = const ClaimReconciler(),
    required this._now,
  });

  final PortalClient _client;
  final ClaimReconciler _reconciler;
  final DateTime Function() _now;

  /// Claims [listing] for [run]'s rule in [session], or explains why not.
  ///
  /// Never throws for a portal failure: a thrown claim is ambiguous, and an
  /// ambiguous claim is reconciled rather than retried. The caller must await
  /// this before starting any other claim — that is the one-in-flight rule.
  Future<ClaimExecution> execute(
    ClaimRunContext run,
    Session session,
    Listing listing,
  ) async {
    final rule = run.rule;
    final now = _now();

    // --- Dry run: record and stop, without ever calling the write path. ---
    if (rule.dryRun) {
      run.ledger.record(
        at: now,
        kind: LedgerEventKind.claimSucceeded,
        message: 'شبیه‌سازی: این آگهی خریداری می‌شد.',
        listingId: listing.id,
        simulated: true,
      );
      run.countPurchase(now);
      run.finishWith(SnipeState.claimed, 'dry run match');
      return const ClaimExecution.dryRun();
    }

    run.transitionTo(SnipeState.claiming);
    run.ledger.record(
      at: now,
      kind: LedgerEventKind.claimAttempted,
      message: 'تلاش برای خرید ${listing.option.name}',
      listingId: listing.id,
    );

    final ClaimResult result;
    try {
      result = await _client.claim(session, listing.id);
    } catch (error) {
      // A thrown claim is ambiguous by definition: we do not know whether the
      // server processed it before the connection failed.
      return _handleAmbiguous(run, session, listing, error.toString());
    }

    switch (result) {
      case ClaimSucceeded(:final reservation):
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.claimSucceeded,
          message: 'خرید انجام شد: ${reservation.option.name}',
          listingId: listing.id,
        );
        run.markClaimed(listing.id);
        run.countPurchase(_now());
        run.finishWith(SnipeState.claimed, 'claimed');
        // The purchase is final, so the run ends here. Continuing would risk a
        // second, unwanted meal — and a basket purchase cannot be cancelled,
        // so there is no undo for that.
        return ClaimExecution.claimed(reservation);

      case ClaimRejected(:final reason):
        run.tombstones.add(
          accountId: rule.account,
          listingId: listing.id,
          reason: TombstoneReason.claimRejected,
          now: _now(),
          listingExpiresAt: listing.expiresAt,
        );
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.claimLost,
          message: 'خرید انجام نشد: $reason',
          listingId: listing.id,
        );
        run.transitionTo(SnipeState.lost);
        run.transitionTo(SnipeState.hunting);
        return const ClaimExecution.ongoing();

      case ClaimAmbiguous(:final diagnostic):
        return _handleAmbiguous(run, session, listing, diagnostic);
    }
  }

  /// Resolves an ambiguous claim by re-reading, then never retries it.
  Future<ClaimExecution> _handleAmbiguous(
    ClaimRunContext run,
    Session session,
    Listing listing,
    String diagnostic,
  ) async {
    final rule = run.rule;

    run.ledger.record(
      at: _now(),
      kind: LedgerEventKind.claimAmbiguous,
      message: 'نتیجه خرید نامشخص بود، بررسی مجدد انجام می‌شود.',
      listingId: listing.id,
    );

    final outcome = await _reconciler.reconcile(
      client: _client,
      session: session,
      listing: listing,
    );

    // Whatever the outcome, this listing is never claimed again. If it did land,
    // retrying buys a second meal; if it did not, retrying is the dead-listing
    // poll pattern. Nothing good comes from a second attempt.
    run.tombstones.add(
      accountId: rule.account,
      listingId: listing.id,
      reason: TombstoneReason.lostRace,
      now: _now(),
      listingExpiresAt: listing.expiresAt,
    );

    switch (outcome) {
      case ReconciliationOutcome.claimed:
        // The purchase did happen — the claim landed and only our knowledge was
        // late. Record it as a purchase, not just a reconciliation note, or the
        // ledger understates what the user was charged.
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.claimSucceeded,
          message: 'بررسی مجدد نشان داد خرید انجام شده است.',
          listingId: listing.id,
        );
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.reconciled,
          message: 'نتیجه نامشخص بود و با بررسی مجدد تأیید شد.',
          listingId: listing.id,
        );
        run.markClaimed(listing.id);
        run.countPurchase(_now());
        run.finishWith(SnipeState.claimed, 'reconciled as claimed');
        return ClaimExecution.claimed(
          Reservation(
            id: 'reconciled-${listing.id}',
            date: listing.date,
            slot: listing.slot,
            hall: listing.hall,
            option: listing.option,
            state: ReservationState.active,
          ),
          reason: 'reconciled as claimed',
        );

      case ReconciliationOutcome.notClaimed:
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.reconciled,
          message: 'بررسی مجدد نشان داد خرید انجام نشده است.',
          listingId: listing.id,
        );
        run.transitionTo(SnipeState.lost);
        run.transitionTo(SnipeState.hunting);
        return const ClaimExecution.ongoing();

      case ReconciliationOutcome.indeterminate:
        // Still unknown. Treat as lost and move on: continuing to hunt risks
        // more than it gains, and the tombstone prevents the dangerous retry.
        run.ledger.record(
          at: _now(),
          kind: LedgerEventKind.reconciled,
          message: 'بررسی مجدد قطعی نبود؛ این آگهی دیگر تلاش نمی‌شود.',
          listingId: listing.id,
        );
        run.transitionTo(SnipeState.lost);
        run.transitionTo(SnipeState.hunting);
        return const ClaimExecution.ongoing();
    }
  }
}
