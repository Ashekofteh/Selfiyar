/// Cooldown tombstones for listings that are known to be dead.
///
/// When a claim is lost — another student got there first, or the portal
/// rejected it — that listing is gone. Re-polling it is the single most
/// attack-looking behaviour available to this app: a tight loop against a
/// specific dead resource, exactly the shape a rate limiter or an abuse
/// detector is built to catch.
///
/// So a claimed-and-lost listing is tombstoned and never attempted again for the
/// life of that listing. The tombstone is scoped per account, because requests
/// are per account: account A losing a race says nothing about whether account
/// B can still see it.
library;

import '../meal/models.dart';

/// Why a listing was tombstoned.
enum TombstoneReason {
  /// Someone else claimed it between our poll and our claim.
  lostRace,

  /// The portal rejected the claim outright.
  claimRejected,

  /// The listing expired while we were looking at it.
  expired,
}

/// A record that a listing must not be attempted again.
class Tombstone {
  const Tombstone({
    required this.accountId,
    required this.listingId,
    required this.reason,
    required this.createdAt,
    required this.expiresAt,
  });

  final AccountId accountId;
  final ListingId listingId;
  final TombstoneReason reason;
  final DateTime createdAt;

  /// When this tombstone may be forgotten. After this the listing is either
  /// gone for good or the space is stale; either way the entry is no longer
  /// useful and is pruned.
  final DateTime expiresAt;

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  @override
  String toString() =>
      'Tombstone($accountId/$listingId, ${reason.name}, until $expiresAt)';
}

/// The set of currently-tombstoned listings.
///
/// Deliberately not a `Set`: tombstone membership is time-dependent, so a plain
/// set would answer "was this ever tombstoned" rather than "is it tombstoned
/// now", and the difference is exactly the bug this guards against.
class TombstoneSet {
  TombstoneSet({this.defaultCooldown = const Duration(days: 1)})
    : assert(defaultCooldown > Duration.zero, 'cooldown must be positive');

  /// How long to tombstone a listing whose own expiry is unknown.
  ///
  /// The portal does not publish a listing's expiry, so this fallback decides
  /// how long a lost listing is off-limits. The spec's rule is that a
  /// claimed-and-lost listing is "never re-attempted for the life of that
  /// listing", and a life measured in minutes would breach it: a hunt that
  /// runs past the fallback would re-claim a listing it already lost, which
  /// is the exact request pattern — a tight loop against one dead resource —
  /// that gets an account banned.
  ///
  /// A day is long enough to cover any window a hunt runs in, and short
  /// enough that the set cannot grow without bound.
  final Duration defaultCooldown;

  final List<Tombstone> _entries = [];

  /// Number of live entries (pruning expired ones first).
  int countAt(DateTime now) {
    prune(now);
    return _entries.length;
  }

  /// Records that [listingId] must not be re-attempted for [accountId].
  ///
  /// [listingExpiresAt] is used when the portal published one; otherwise
  /// [defaultCooldown] applies from [now].
  void add({
    required AccountId accountId,
    required ListingId listingId,
    required TombstoneReason reason,
    required DateTime now,
    DateTime? listingExpiresAt,
  }) {
    // Already tombstoned: keep the existing entry rather than extending it.
    if (isTombstoned(accountId, listingId, now)) return;

    final fallback = now.add(defaultCooldown);
    final expiry = listingExpiresAt != null && listingExpiresAt.isAfter(now)
        ? listingExpiresAt
        : fallback;

    _entries.add(
      Tombstone(
        accountId: accountId,
        listingId: listingId,
        reason: reason,
        createdAt: now,
        expiresAt: expiry,
      ),
    );
  }

  /// True when [listingId] is currently tombstoned for [accountId].
  ///
  /// Prunes expired entries first, so a stale tombstone never blocks a listing
  /// that has legitimately become available again.
  bool isTombstoned(AccountId accountId, ListingId listingId, DateTime now) {
    prune(now);
    return _entries.any(
      (t) => t.accountId == accountId && t.listingId == listingId,
    );
  }

  /// Removes entries whose cooldown has elapsed.
  void prune(DateTime now) {
    _entries.removeWhere((t) => t.isExpiredAt(now));
  }

  /// Drops all tombstones. Used when a run ends: a fresh run starts with no
  /// history, since the listings it will see are new.
  void clear() => _entries.clear();

  /// Tombstones recorded for [accountId], for diagnostics.
  List<Tombstone> forAccount(AccountId accountId, DateTime now) {
    prune(now);
    return _entries.where((t) => t.accountId == accountId).toList();
  }

  /// Filters [listings] down to those not tombstoned for [accountId].
  List<Listing> filter(
    AccountId accountId,
    Iterable<Listing> listings,
    DateTime now,
  ) {
    prune(now);
    return listings.where((l) => !isTombstoned(accountId, l.id, now)).toList();
  }
}
