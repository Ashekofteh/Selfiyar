import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/shared/time.dart';
import 'package:test/test.dart';

void main() {
  group('SyncedServerClock', () {
    test('is unsynced until its first sync', () {
      final clock = SyncedServerClock();
      expect(clock.isSynced, isFalse);
      expect(clock.staleness, Duration.zero);
      expect(() => clock.nowUtc, throwsA(isA<StateError>()));
    });

    test('reading before syncing throws rather than guessing', () {
      // The whole point: a guessed time would produce a briefing about the wrong
      // day and a sniped meal at the wrong moment.
      final clock = SyncedServerClock();
      expect(() => clock.nowUtc, throwsA(isA<StateError>()));
    });

    test('a perfect sync with zero latency reproduces the server time', () {
      final local = DateTime.utc(2026, 10, 18, 12, 0, 0);
      final clock = SyncedServerClock(localNowUtc: () => local);

      clock.syncFrom(
        serverDateUtc: DateTime.utc(2026, 10, 18, 15, 0, 0),
        roundTrip: Duration.zero,
        localReceivedAt: local,
      );

      expect(clock.isSynced, isTrue);
      expect(clock.nowUtc, DateTime.utc(2026, 10, 18, 15, 0, 0));
    });

    test('round-trip latency is compensated by half', () {
      // Server responded at 15:00:00 having received the request 200ms earlier,
      // so at the moment we received it (200ms round trip) the server is 100ms
      // past the header value.
      final local = DateTime.utc(2026, 10, 18, 12, 0, 0);
      final clock = SyncedServerClock(localNowUtc: () => local);

      clock.syncFrom(
        serverDateUtc: DateTime.utc(2026, 10, 18, 15, 0, 0),
        roundTrip: const Duration(milliseconds: 200),
        localReceivedAt: local,
      );

      expect(clock.nowUtc, DateTime.utc(2026, 10, 18, 15, 0, 0, 100));
    });

    test('a fast device clock is corrected', () {
      // Device thinks it is 10:00; server says 09:00. The offset must be -1h.
      final local = DateTime.utc(2026, 10, 18, 10, 0, 0);
      final clock = SyncedServerClock(localNowUtc: () => local);

      clock.syncFrom(
        serverDateUtc: DateTime.utc(2026, 10, 18, 9, 0, 0),
        roundTrip: Duration.zero,
        localReceivedAt: local,
      );

      expect(clock.offset, const Duration(hours: -1));
      expect(clock.nowUtc, DateTime.utc(2026, 10, 18, 9, 0, 0));
    });

    test('a slow device clock is corrected', () {
      final local = DateTime.utc(2026, 10, 18, 8, 0, 0);
      final clock = SyncedServerClock(localNowUtc: () => local);

      clock.syncFrom(
        serverDateUtc: DateTime.utc(2026, 10, 18, 12, 0, 0),
        roundTrip: Duration.zero,
        localReceivedAt: local,
      );

      expect(clock.offset, const Duration(hours: 4));
      expect(clock.nowUtc, DateTime.utc(2026, 10, 18, 12, 0, 0));
    });

    test('advances with the local clock between syncs', () {
      var local = DateTime.utc(2026, 10, 18, 12, 0, 0);
      final clock = SyncedServerClock(localNowUtc: () => local);

      clock.syncFrom(
        serverDateUtc: DateTime.utc(2026, 10, 18, 15, 0, 0),
        roundTrip: Duration.zero,
        localReceivedAt: local,
      );
      expect(clock.nowUtc, DateTime.utc(2026, 10, 18, 15, 0, 0));

      // Five minutes of wall time passes locally.
      local = local.add(const Duration(minutes: 5));
      expect(clock.nowUtc, DateTime.utc(2026, 10, 18, 15, 5, 0));
    });

    test('staleness grows from the last sync', () {
      var local = DateTime.utc(2026, 10, 18, 12, 0, 0);
      final clock = SyncedServerClock(localNowUtc: () => local);

      clock.syncFrom(
        serverDateUtc: DateTime.utc(2026, 10, 18, 15, 0, 0),
        roundTrip: Duration.zero,
        localReceivedAt: local,
      );
      expect(clock.staleness, Duration.zero);

      local = local.add(const Duration(minutes: 20));
      expect(clock.staleness, const Duration(minutes: 20));
    });

    test('a resync updates the offset', () {
      var local = DateTime.utc(2026, 10, 18, 12, 0, 0);
      final clock = SyncedServerClock(localNowUtc: () => local);

      clock.syncFrom(
        serverDateUtc: DateTime.utc(2026, 10, 18, 15, 0, 0),
        roundTrip: Duration.zero,
        localReceivedAt: local,
      );
      expect(clock.offset, const Duration(hours: 3));

      local = local.add(const Duration(minutes: 1));
      clock.syncFrom(
        serverDateUtc: DateTime.utc(2026, 10, 18, 15, 1, 0),
        roundTrip: Duration.zero,
        localReceivedAt: local,
      );
      expect(clock.offset, const Duration(hours: 3));
    });

    test('invalidate makes the clock untrusted again', () {
      final local = DateTime.utc(2026, 10, 18, 12, 0, 0);
      final clock = SyncedServerClock(localNowUtc: () => local);
      clock.syncFrom(
        serverDateUtc: DateTime.utc(2026, 10, 18, 15, 0, 0),
        roundTrip: Duration.zero,
        localReceivedAt: local,
      );
      expect(clock.isSynced, isTrue);

      clock.invalidate();
      expect(clock.isSynced, isFalse);
      expect(() => clock.nowUtc, throwsA(isA<StateError>()));
    });
  });

  group('cutoff logic works off a synced clock', () {
    test('a synced clock drives the 17:00 two-days-before-delivery wall', () {
      // Server says 2026-10-18 17:30 portal-local -> 14:00 UTC, past the
      // 17:00 cutoff, so a meal on the 20th is locked.
      final local = DateTime.utc(2026, 10, 18, 14, 0, 0);
      final clock = SyncedServerClock(localNowUtc: () => local);
      clock.syncFrom(
        serverDateUtc: DateTime.utc(2026, 10, 18, 14, 0, 0),
        roundTrip: Duration.zero,
        localReceivedAt: local,
      );

      expect(clock.isLocked(DateTime.utc(2026, 10, 20)), isTrue);
      expect(clock.isReservable(DateTime.utc(2026, 10, 21)), isTrue);
    });

    test('a badly skewed device clock still yields the correct boundary', () {
      // Device is a full day slow. Without server sync this would compute the
      // wrong cutoff; with it, the answer is right.
      final local = DateTime.utc(2026, 10, 17, 14, 0, 0);
      final clock = SyncedServerClock(localNowUtc: () => local);
      clock.syncFrom(
        serverDateUtc: DateTime.utc(2026, 10, 18, 14, 0, 0),
        roundTrip: Duration.zero,
        localReceivedAt: local,
      );

      expect(clock.portalTodayUtc, DateTime.utc(2026, 10, 18));
      expect(clock.isLocked(DateTime.utc(2026, 10, 20)), isTrue);
    });

    test('breakfast uses its delivery day, so it locks a day earlier', () {
      // Sunday 2026-10-18 17:30 portal-local = 14:00 UTC.
      final local = DateTime.utc(2026, 10, 18, 14, 0, 0);
      final clock = SyncedServerClock(localNowUtc: () => local);
      clock.syncFrom(
        serverDateUtc: DateTime.utc(2026, 10, 18, 14, 0, 0),
        roundTrip: Duration.zero,
        localReceivedAt: local,
      );

      final wednesday = DateTime.utc(2026, 10, 21);
      expect(clock.isLockedFor(wednesday, MealSlot.breakfast), isTrue);
      expect(clock.isLockedFor(wednesday, MealSlot.lunch), isFalse);
    });
  });

  group('FixedServerClock still behaves', () {
    test('reports synced and the given instant', () {
      final clock = FixedServerClock.now(DateTime.utc(2026, 10, 18, 12, 0));
      expect(clock.isSynced, isTrue);
      expect(clock.nowUtc, DateTime.utc(2026, 10, 18, 12, 0));
    });
  });
}
