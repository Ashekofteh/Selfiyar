/// The count of requests the app has actually made, per account.
///
/// ## Why this exists, and why it counts requests and not polls
///
/// The portal is shared infrastructure and the user's account is the thing at
/// risk. The project's hard rule is a **per-account request budget** that ends
/// a run when it is exhausted — the last line of defence, below the interval
/// and the jitter.
///
/// That budget used to count **polls**. It was counting the wrong thing. A
/// poll is not a request: reading the basket is a GET plus, when the page's
/// default date is not the one wanted, a date-filter POST; reading the
/// reservations is a GET plus a next-week POST; the portal answers a
/// successful login with a redirect, which is a second request. So a budget
/// of 400 polls was really a budget of 800 requests, and the backstop that
/// exists to prevent a ban was letting through twice the traffic it was
/// written to allow.
///
/// So the count is taken at the only place that knows the truth: the
/// transport, where every request goes. It counts requests, including the
/// redirect hops, because a redirect hop is a request the portal sees.
///
/// ## Why it is per account, and per window
///
/// Accounts are separate: the portal sees one account's traffic, and one
/// account's budget says nothing about another's. The window matters for the
/// same reason the hunt's does — the portal's pressure is a rate, and a
/// count that never resets is not a rate.
///
/// ## What it is not
///
/// It is not a throttle. It does not delay anything and it does not refuse
/// anything: a request that is made is recorded, and the *caller* decides
/// what to do when the budget is gone. The hunt ends its run; a manual
/// refresh is a deliberate act by the student and is allowed to happen. A
/// backstop that silently swallowed a request would produce a read that
/// looks like an empty result, which is the worst shape a limit can have.
library;

import '../meal/models.dart';

/// The window length the budgets are measured over.
///
/// One hour. It is long enough that a burst inside a hunt window does not
/// exhaust it, and short enough that an hour of quiet resets the count.
const Duration requestWindowLength = Duration(hours: 1);

/// The default number of requests allowed per account per window.
///
/// The hunt's own budget is 400 *polls*; at the real ratio of requests to
/// polls that was 800 requests, so the request budget is set deliberately
/// below the poll budget — it is the backstop, and it counts the thing the
/// portal sees.
const int defaultRequestLimit = 400;

/// One request the app made.
class RequestRecord {
  const RequestRecord({
    required this.accountId,
    required this.method,
    required this.path,
    required this.at,
    this.statusCode,
    this.failed = false,
  });

  final AccountId accountId;

  /// `GET` or `POST`.
  final String method;

  /// The portal-relative path, without the query.
  final String path;

  /// When the request was made (UTC).
  final DateTime at;

  /// The portal's answer, when there was one.
  final int? statusCode;

  /// True when the request did not complete.
  final bool failed;

  @override
  String toString() =>
      '${at.toIso8601String()} $accountId $method $path'
      '${statusCode == null ? "" : " -> $statusCode"}';
}

/// A window of requests, for one account.
class AccountRequestWindow {
  AccountRequestWindow({
    required this.accountId,
    required this.windowStart,
    required this.limit,
  });

  final AccountId accountId;

  /// When the window opened.
  final DateTime windowStart;

  /// The number of requests allowed in one window.
  final int limit;

  /// The requests made in this window, oldest first.
  final List<RequestRecord> records = [];

  int get spent => records.length;

  int get remaining => limit - spent;

  bool get isExhausted => spent >= limit;

  /// The number of requests per minute, over the span of the window.
  ///
  /// The rate is what the portal feels, so it is the number worth showing.
  /// It is measured over the span the requests actually cover, not over the
  /// window's nominal length: a window that has been open for five seconds
  /// and holds one request is not "one request per hour", it is one request
  /// right now.
  double get requestsPerMinute {
    if (records.length < 2) return 0;
    final elapsed = records.last.at.difference(records.first.at);
    if (elapsed.inSeconds <= 0) return records.length * 60.0;
    return records.length * 60.0 / elapsed.inSeconds;
  }

  @override
  String toString() =>
      'AccountRequestWindow($accountId, $spent/$limit, '
      '${requestsPerMinute.toStringAsFixed(1)}/min)';
}

/// Counts requests per account, over a rolling window.
class RequestLedger {
  RequestLedger({
    this.windowLength = requestWindowLength,
    this.limit = defaultRequestLimit,
    DateTime Function()? now,
  }) : _now = now ?? (() => DateTime.now().toUtc());

  /// How long a window lasts.
  final Duration windowLength;

  /// The number of requests allowed per account per window.
  final int limit;

  final DateTime Function() _now;

  /// The open window per account.
  final Map<AccountId, AccountRequestWindow> _windows = {};

  /// The **monotonic** request count per account.
  ///
  /// Separate from the window, because the two answer different questions.
  /// The window answers "how fast is this account talking right now?"; the
  /// total answers "how many requests has this run spent?" — and a run's
  /// budget must not be reset by the clock. A rolling window that expired
  /// mid-hunt would hand the run a fresh allowance and let it go on.
  final Map<AccountId, int> _totals = {};

  /// Every request ever recorded, oldest first.
  ///
  /// Capped: an unbounded record of every request is a memory leak, and the
  /// recent tail is what any question about the traffic actually needs.
  final List<RequestRecord> _history = [];

  /// Cap on the retained history.
  static const int maxHistory = 2000;

  /// The window for [accountId], opening one if it is not open.
  AccountRequestWindow windowFor(AccountId accountId) {
    final now = _now();
    final existing = _windows[accountId];

    if (existing == null) {
      return _openWindow(accountId, now);
    }

    // The window is **rolling**, not fixed: it opens when the account's first
    // request lands and closes one window-length later. A fixed wall-clock
    // window would reset on the hour regardless of when the traffic
    // happened, which would let a burst straddle the boundary and double
    // the effective allowance.
    if (now.difference(existing.windowStart) >= windowLength) {
      return _openWindow(accountId, now);
    }

    return existing;
  }

  AccountRequestWindow _openWindow(AccountId accountId, DateTime now) {
    final fresh = AccountRequestWindow(
      accountId: accountId,
      windowStart: now,
      limit: limit,
    );
    _windows[accountId] = fresh;
    return fresh;
  }

  /// Records a request. Returns the window it was counted in.
  AccountRequestWindow record({
    required AccountId accountId,
    required String method,
    required String path,
    int? statusCode,
    bool failed = false,
  }) {
    final record = RequestRecord(
      accountId: accountId,
      method: method,
      path: path,
      at: _now(),
      statusCode: statusCode,
      failed: failed,
    );
    _history.add(record);
    if (_history.length > maxHistory) {
      _history.removeRange(0, _history.length - maxHistory);
    }

    _totals[accountId] = (_totals[accountId] ?? 0) + 1;

    final window = windowFor(accountId);
    window.records.add(record);
    return window;
  }

  /// The number of requests [accountId] has made in total, since the app
  /// started.
  ///
  /// Monotonic: it never goes down and the clock never resets it. This is
  /// the number a run's budget is measured against.
  int totalFor(AccountId accountId) => _totals[accountId] ?? 0;

  /// The number of requests [accountId] has made in the open window.
  int spentFor(AccountId accountId) => windowFor(accountId).spent;

  /// Whether [accountId] has exhausted its budget in the open window.
  bool isExhaustedFor(AccountId accountId) => windowFor(accountId).isExhausted;

  /// The requests made in the open window, oldest first.
  List<RequestRecord> recentFor(AccountId accountId) =>
      List.unmodifiable(windowFor(accountId).records);

  /// The whole recent history, oldest first.
  List<RequestRecord> get history => List.unmodifiable(_history);

  /// The accounts with an open window.
  Iterable<AccountId> get accounts => _windows.keys;
}
