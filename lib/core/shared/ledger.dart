/// The audit ledger: an append-only record of what a run decided and did.
///
/// This exists because auto-buy spends real money without asking. When the user
/// wonders why a meal was or was not bought, "it polled and found nothing" is
/// not an acceptable answer — the ledger records the ranking decision, the
/// listing considered, and the outcome, so any purchase can be explained after
/// the fact.
///
/// It is also what makes dry-run honest: a dry run writes the same entries as a
/// real one, marked as simulated, so the user can read exactly what the rule
/// would have done before letting it spend anything.
library;

import '../meal/models.dart';

/// What happened at one moment of a run.
enum LedgerEventKind {
  /// The run started.
  started,

  /// Preconditions were checked.
  preflightPassed,
  preflightFailed,

  /// A poll cycle completed, with or without a match.
  polled,

  /// The ranker selected a listing.
  matched,

  /// A listing was rejected by the ranker, with the reason.
  skipped,

  /// A claim was attempted.
  claimAttempted,

  /// The claim succeeded.
  claimSucceeded,

  /// The claim failed, and the listing is now dead.
  claimLost,

  /// The claim outcome was unknown, so the engine reconciled rather than retried.
  claimAmbiguous,

  /// Reconciliation established ground truth after an ambiguous claim.
  reconciled,

  /// The run is waiting for its window to open, and is sending no requests.
  ///
  /// A distinct kind rather than a `runEnded`, because the run has not ended:
  /// it is alive and will start polling when its window opens.
  waiting,

  /// The run reached a terminal state.
  runEnded,
}

/// One immutable entry in the ledger.
class LedgerEntry {
  const LedgerEntry({
    required this.at,
    required this.ruleId,
    required this.kind,
    required this.message,
    this.listingId,
    this.simulated = false,
  });

  final DateTime at;
  final String ruleId;
  final LedgerEventKind kind;

  /// Human-readable explanation, Persian, suitable for the run log screen.
  final String message;

  final ListingId? listingId;

  /// True when this entry describes what a dry run *would* have done.
  ///
  /// Kept explicit rather than implied so a log can never be mistaken for a
  /// record of real purchases.
  final bool simulated;

  @override
  String toString() =>
      '[${at.toIso8601String()}] ${simulated ? "DRY " : ""}'
      '${kind.name} $message${listingId == null ? "" : " ($listingId)"}';
}

/// Append-only ledger for one run.
class SnipeLedger {
  SnipeLedger(this.ruleId);

  final String ruleId;

  /// Cap on retained entries. A long hunt polls a lot, and an unbounded log is
  /// a memory leak with extra steps.
  static const int maxEntries = 500;

  final List<LedgerEntry> _entries = [];

  List<LedgerEntry> get entries => List.unmodifiable(_entries);

  /// Real (non-simulated) purchases recorded.
  int get purchaseCount => _entries
      .where((e) => e.kind == LedgerEventKind.claimSucceeded && !e.simulated)
      .length;

  /// Purchases the rule *would* have made, in dry-run mode.
  int get simulatedPurchaseCount => _entries
      .where((e) => e.kind == LedgerEventKind.claimSucceeded && e.simulated)
      .length;

  void record({
    required DateTime at,
    required LedgerEventKind kind,
    required String message,
    ListingId? listingId,
    bool simulated = false,
  }) {
    _entries.add(LedgerEntry(
      at: at,
      ruleId: ruleId,
      kind: kind,
      message: message,
      listingId: listingId,
      simulated: simulated,
    ));
    // Drop the oldest rather than the newest: the tail of a run is what matters
    // when diagnosing it.
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
  }

  /// Entries of a given kind, for focused queries in the UI.
  List<LedgerEntry> ofKind(LedgerEventKind kind) =>
      _entries.where((e) => e.kind == kind).toList();

  void clear() => _entries.clear();
}