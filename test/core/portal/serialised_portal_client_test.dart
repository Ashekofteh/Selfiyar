import 'dart:async';

import 'package:bahonar_nut/core/meal/models.dart';
import 'package:bahonar_nut/core/portal/portal.dart';
import 'package:bahonar_nut/core/portal/serialised_portal_client.dart';
import 'package:test/test.dart';

import '../../helpers/portal_stubs.dart' as stubs;

/// A stub that records when each operation starts and ends.
///
/// The delay is what the assertions are about: an operation is "in flight"
/// from its first line to its last, and two operations for **one** account
/// must never be in flight at the same time.
class _RecordingClient extends stubs.FakePortalClient {
  final List<String> events = [];

  /// The operations in flight, per account.
  final Map<String, List<String>> inFlight = {};

  /// How long each operation takes.
  Duration delay = const Duration(milliseconds: 20);

  /// When set, the next operation of this name throws it.
  Object? failWith;

  int _counter = 0;

  Future<T> _record<T>(String account, String name, T value) async {
    final id = '$name#${_counter++}';
    final live = inFlight.putIfAbsent(account, () => <String>[]);
    live.add(id);
    events.add('start $id');
    expect(
      live.length,
      lessThanOrEqualTo(1),
      reason: 'two operations for one account overlapped: $live',
    );
    await Future<void>.delayed(delay);
    live.remove(id);
    events.add('end $id');
    if (failWith != null) {
      final error = failWith!;
      failWith = null;
      throw error;
    }
    return value;
  }

  @override
  Future<Balance> fetchBalance(Session session) => _record(
        session.account,
        'balance',
        Balance(amountRial: 1, fetchedAt: DateTime.utc(2026)),
      );

  @override
  Future<List<Reservation>> fetchReservations(Session session) =>
      _record(session.account, 'reservations', const <Reservation>[]);

  @override
  Future<BookableMenus> fetchBookableMenus(
    Session session, {
    int days = 7,
  }) =>
      _record(
        session.account,
        'menus',
        const BookableMenus(dates: [], menus: []),
      );

  @override
  Future<CancelOutcome> cancel(Session session, MealRef ref) =>
      _record(session.account, 'cancel', const CancelSucceeded());
}

void main() {
  final session = Session(
    account: 'a1',
    cookies: const {},
    establishedAt: DateTime.utc(2026, 10, 21),
  );

  final other = Session(
    account: 'a2',
    cookies: const {},
    establishedAt: DateTime.utc(2026, 10, 21),
  );

  group('operations for one account', () {
    test('do not overlap', () async {
      final inner = _RecordingClient();
      final client = SerialisedPortalClient(inner);

      await Future.wait([
        client.fetchBalance(session),
        client.fetchReservations(session),
        client.fetchBookableMenus(session),
        client.cancel(
          session,
          MealRef(date: DateTime.utc(2026, 10, 25), slot: MealSlot.lunch),
        ),
      ]);

      // The recorder asserts the non-overlap on every operation; this checks
      // that all four actually ran.
      expect(inner.events.where((e) => e.startsWith('start')).length, 4);
    });

    test('run one after another, in the order they were started', () async {
      final inner = _RecordingClient();
      final client = SerialisedPortalClient(inner);

      await Future.wait([
        client.fetchBalance(session),
        client.fetchReservations(session),
      ]);

      final events = inner.events;
      // The balance must be finished before the reservations start.
      expect(
        events.indexOf('end balance#0'),
        lessThan(events.indexOf('start reservations#1')),
      );
    });

    test('a failing operation does not block the next one', () async {
      final inner = _RecordingClient()..failWith = StateError('boom');
      final client = SerialisedPortalClient(inner);

      await expectLater(
        client.fetchReservations(session),
        throwsA(isA<StateError>()),
      );

      // The account's queue must not be poisoned: the next operation runs.
      final balance = await client.fetchBalance(session);
      expect(balance.amountRial, 1);
    });
  });

  group('operations for different accounts', () {
    test('may overlap', () async {
      final inner = _RecordingClient();
      final client = SerialisedPortalClient(inner);

      final first = client.fetchBalance(session);
      final second = client.fetchBalance(other);

      // Both are in flight at the same moment: the second did not wait for
      // the first. Two accounts have separate cookies, separate viewstates
      // and separate week chains, so making one wait for the other would be a
      // latency the student pays for nothing.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(inner.inFlight['a1'], isNotNull);
      expect(inner.inFlight['a2'], isNotNull);

      await Future.wait([first, second]);
    });
  });
}
