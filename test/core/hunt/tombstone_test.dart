import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/hunt/tombstone.dart';
import 'package:test/test.dart';

const central = Hall(id: '1', name: 'مرکزی برادران');
final option = MenuOption(id: 'o1', name: 'dish', priceRial: 350000);

Listing listing(String id) => Listing(
  id: id,
  date: DateTime.utc(2026, 10, 20),
  slot: MealSlot.lunch,
  hall: central,
  option: option,
);

void main() {
  final t0 = DateTime.utc(2026, 10, 18, 12, 0);

  group('shadowing dead listings', () {
    test('a fresh listing is not tombstoned', () {
      final set = TombstoneSet();
      expect(set.isTombstoned('a1', 'L1', t0), isFalse);
    });

    test('a lost listing is tombstoned and stays tombstoned', () {
      final set = TombstoneSet();
      set.add(
        accountId: 'a1',
        listingId: 'L1',
        reason: TombstoneReason.lostRace,
        now: t0,
      );
      expect(set.isTombstoned('a1', 'L1', t0), isTrue);
      expect(
        set.isTombstoned('a1', 'L1', t0.add(const Duration(hours: 2))),
        isTrue,
      );
    });

    test('tombstones expire after the cooldown by default', () {
      final set = TombstoneSet();
      set.add(
        accountId: 'a1',
        listingId: 'L1',
        reason: TombstoneReason.lostRace,
        now: t0,
      );
      expect(
        set.isTombstoned('a1', 'L1', t0.add(const Duration(days: 2))),
        isFalse,
      );
    });

    test('a lost listing is off-limits for a whole hunting window', () {
      // The spec's rule is that a claimed-and-lost listing is "never
      // re-attempted for the life of that listing". A cooldown measured in
      // minutes would breach it: a hunt running past the cooldown would
      // re-claim a listing it already lost, which is the tight loop against
      // one dead resource that gets an account banned.
      final set = TombstoneSet();
      set.add(
        accountId: 'a1',
        listingId: 'L1',
        reason: TombstoneReason.lostRace,
        now: t0,
      );
      expect(
        set.isTombstoned('a1', 'L1', t0.add(const Duration(hours: 6))),
        isTrue,
        reason: 'an evening hunt must not come back to a listing it lost',
      );
    });

    test('a shorter custom cooldown expires sooner', () {
      final set = TombstoneSet(defaultCooldown: const Duration(minutes: 5));
      set.add(
        accountId: 'a1',
        listingId: 'L1',
        reason: TombstoneReason.claimRejected,
        now: t0,
      );
      expect(
        set.isTombstoned('a1', 'L1', t0.add(const Duration(minutes: 6))),
        isFalse,
      );
    });

    test('a listing expiry is honored when earlier than the default', () {
      final set = TombstoneSet();
      set.add(
        accountId: 'a1',
        listingId: 'L1',
        reason: TombstoneReason.expired,
        now: t0,
        listingExpiresAt: t0.add(const Duration(minutes: 3)),
      );
      expect(set.isTombstoned('a1', 'L1', t0), isTrue);
      expect(
        set.isTombstoned('a1', 'L1', t0.add(const Duration(minutes: 4))),
        isFalse,
      );
    });
  });

  group('per-account scoping', () {
    test(
      'a tombstone for one account does not hide the listing for another',
      () {
        final set = TombstoneSet();
        set.add(
          accountId: 'a1',
          listingId: 'L1',
          reason: TombstoneReason.lostRace,
          now: t0,
        );
        expect(set.isTombstoned('a2', 'L1', t0), isFalse);
      },
    );

    test('filter removes only tombstoned listings for that account', () {
      final set = TombstoneSet();
      set.add(
        accountId: 'a1',
        listingId: 'L1',
        reason: TombstoneReason.lostRace,
        now: t0,
      );
      final listings = [listing('L1'), listing('L2')];
      expect(set.filter('a1', listings, t0).map((l) => l.id), ['L2']);
      expect(set.filter('a2', listings, t0).map((l) => l.id), ['L1', 'L2']);
    });

    test('forAccount lists only that account', () {
      final set = TombstoneSet();
      set.add(
        accountId: 'a1',
        listingId: 'L1',
        reason: TombstoneReason.lostRace,
        now: t0,
      );
      set.add(
        accountId: 'a2',
        listingId: 'L2',
        reason: TombstoneReason.claimRejected,
        now: t0,
      );
      expect(set.forAccount('a1', t0).length, 1);
      expect(set.forAccount('a1', t0).single.listingId, 'L1');
    });
  });

  group('hygiene', () {
    test('adding the same listing twice does not extend the cooldown', () {
      final set = TombstoneSet();
      set.add(
        accountId: 'a1',
        listingId: 'L1',
        reason: TombstoneReason.lostRace,
        now: t0,
      );
      // Re-add near expiry: must not refresh the entry.
      set.add(
        accountId: 'a1',
        listingId: 'L1',
        reason: TombstoneReason.lostRace,
        now: t0.add(const Duration(hours: 20)),
      );
      expect(
        set.isTombstoned('a1', 'L1', t0.add(const Duration(days: 2))),
        isFalse,
        reason: 'the original cooldown must still hold, not be extended',
      );
    });

    test('prune drops expired entries and counts live ones', () {
      final set = TombstoneSet(defaultCooldown: const Duration(minutes: 5));
      set.add(
        accountId: 'a1',
        listingId: 'L1',
        reason: TombstoneReason.lostRace,
        now: t0,
      );
      expect(set.countAt(t0), 1);
      expect(set.countAt(t0.add(const Duration(minutes: 6))), 0);
    });

    test('clear drops everything', () {
      final set = TombstoneSet();
      set.add(
        accountId: 'a1',
        listingId: 'L1',
        reason: TombstoneReason.lostRace,
        now: t0,
      );
      set.clear();
      expect(set.isTombstoned('a1', 'L1', t0), isFalse);
    });
  });
}
