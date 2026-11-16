import 'package:bahonar_nut/core/portal/request_ledger.dart';
import 'package:test/test.dart';

void main() {
  group('the request ledger', () {
    test('counts the requests it is told about', () {
      final ledger = RequestLedger(now: () => DateTime.utc(2026, 10, 21, 12));

      ledger.record(
        accountId: 'a1',
        method: 'GET',
        path: '/Reservation/Reservation.aspx',
      );
      ledger.record(
        accountId: 'a1',
        method: 'POST',
        path: '/Reservation/Reservation.aspx',
      );

      expect(ledger.spentFor('a1'), 2);
      expect(ledger.totalFor('a1'), 2);
    });

    test('keeps the accounts apart', () {
      final ledger = RequestLedger(now: () => DateTime.utc(2026, 10, 21, 12));

      ledger.record(accountId: 'a1', method: 'GET', path: '/x');
      ledger.record(accountId: 'a2', method: 'GET', path: '/x');

      expect(ledger.spentFor('a1'), 1);
      expect(ledger.spentFor('a2'), 1);
    });

    test('reports the budget as exhausted at the limit', () {
      final ledger = RequestLedger(
        limit: 2,
        now: () => DateTime.utc(2026, 10, 21, 12),
      );

      expect(ledger.isExhaustedFor('a1'), isFalse);
      ledger.record(accountId: 'a1', method: 'GET', path: '/x');
      expect(ledger.isExhaustedFor('a1'), isFalse);
      ledger.record(accountId: 'a1', method: 'GET', path: '/x');
      expect(ledger.isExhaustedFor('a1'), isTrue);
    });
  });

  group('the window', () {
    test('rolls over when it is older than the window length', () {
      var now = DateTime.utc(2026, 10, 21, 12);
      final ledger = RequestLedger(
        windowLength: const Duration(minutes: 30),
        now: () => now,
      );

      ledger.record(accountId: 'a1', method: 'GET', path: '/x');
      ledger.record(accountId: 'a1', method: 'GET', path: '/x');
      expect(ledger.spentFor('a1'), 2);

      // Just inside the window: the count carries over.
      now = now.add(const Duration(minutes: 29));
      expect(ledger.spentFor('a1'), 2);

      // Past it: a fresh window opens.
      now = now.add(const Duration(minutes: 2));
      expect(ledger.spentFor('a1'), 0);
    });

    test('is rolling, so a burst cannot straddle the boundary', () {
      // A fixed wall-clock window would reset on the hour, and a burst that
      // straddled the boundary would get two full allowances. The window is
      // measured from the account's first request instead — so a window
      // opened at 12:30 closes at 13:30, not at 13:00.
      var now = DateTime.utc(2026, 10, 21, 12, 30);
      final ledger = RequestLedger(
        windowLength: const Duration(hours: 1),
        now: () => now,
      );

      ledger.record(accountId: 'a1', method: 'GET', path: '/x');

      // Half an hour later: still inside the window, so the count carries.
      now = now.add(const Duration(minutes: 30));
      expect(ledger.spentFor('a1'), 1);

      // Just past the hour: the window closes, and a new one opens — the
      // count resets exactly one hour after the first request, not on the
      // wall-clock hour.
      now = now.add(const Duration(minutes: 31));
      expect(ledger.spentFor('a1'), 0);
    });

    test('the total is monotonic and never reset by the clock', () {
      var now = DateTime.utc(2026, 10, 21, 12);
      final ledger = RequestLedger(
        windowLength: const Duration(minutes: 30),
        now: () => now,
      );

      ledger.record(accountId: 'a1', method: 'GET', path: '/x');
      ledger.record(accountId: 'a1', method: 'GET', path: '/x');
      expect(ledger.totalFor('a1'), 2);

      // The window rolls over, so the *window* count resets...
      now = now.add(const Duration(minutes: 31));
      expect(ledger.spentFor('a1'), 0);

      // ...but the total does not. A run's budget must not be handed a fresh
      // allowance because the clock moved.
      expect(ledger.totalFor('a1'), 2);
    });
  });

  group('the rate', () {
    test('is measured over the span the requests cover', () {
      var now = DateTime.utc(2026, 10, 21, 12, 0, 0);
      final ledger = RequestLedger(now: () => now);

      ledger.record(accountId: 'a1', method: 'GET', path: '/x');
      now = now.add(const Duration(seconds: 1));
      ledger.record(accountId: 'a1', method: 'GET', path: '/x');
      now = now.add(const Duration(seconds: 1));
      ledger.record(accountId: 'a1', method: 'GET', path: '/x');

      // Three requests over two seconds is 90 a minute.
      expect(
        ledger.windowFor('a1').requestsPerMinute,
        closeTo(90, 0.1),
      );
    });

    test('is zero for an account that has made no requests', () {
      final ledger = RequestLedger(now: () => DateTime.utc(2026, 10, 21, 12));
      expect(ledger.windowFor('a1').requestsPerMinute, 0);
    });
  });

  group('the history', () {
    test('is bounded, dropping the oldest first', () {
      final ledger = RequestLedger(now: () => DateTime.utc(2026, 10, 21, 12));

      for (var i = 0; i < RequestLedger.maxHistory + 10; i++) {
        ledger.record(accountId: 'a1', method: 'GET', path: '/x$i');
      }

      expect(ledger.history.length, RequestLedger.maxHistory);
      // The tail is what matters when diagnosing the traffic, so the *newest*
      // is what survives.
      expect(ledger.history.last.path, endsWith('/x${RequestLedger.maxHistory + 9}'));
    });
  });
}
