/// A [PortalClient] that runs one portal operation at a time per account.
///
/// ## Why the portal needs this
///
/// The portal is ASP.NET WebForms, and the state a POST acts on is carried in
/// the page's `__VIEWSTATE`. The weekly reservation page chains its weeks
/// through that state: a next-week post advances the chain, and the page it
/// returns is the one the next post will be answered against.
///
/// So an operation is **not** one request. Reading the reservations is a GET
/// followed by a next-week POST. Booking is a GET, a write POST, and a
/// confirming GET. Two operations for the same account that overlap can
/// interleave those requests, and the second one then works against a chain
/// the first one has already moved along.
///
/// The failure is silent, and it costs money. A read that lands on the wrong
/// week misses a meal the student holds, and the mirror — which the table,
/// the reminders and the one-meal check are all built on — then says the slot
/// is free. A booking that lands on the wrong week is worse still: the
/// request is accepted, the confirmation reads a different week, and the app
/// reports a failure for a booking that really happened.
///
/// ## Why per account
///
/// The accounts are separate: separate cookies, separate viewstates, separate
/// chains. Two accounts never interfere, and making the second one wait for
/// the first would be a latency the student pays for nothing.
///
/// ## What this does not cover
///
/// The login is two calls — [PortalClient.beginLogin] and
/// [PortalClient.completeLogin] — and a read may run between them.
///
/// That is **not** safe, and the reason is worth stating because it was
/// believed to be the opposite for a long time. The CAPTCHA answer is judged
/// against the **session** the image was fetched in, and the portal mints a
/// new `ASP.NET_SessionId` every time it renders the login page. So an
/// intervening read of the login page replaces that session, and a correct
/// answer is then refused. Verified live 2026-10-21 (F77).
///
/// The answer survives it anyway, because the challenge carries its session id
/// and the client restores it before the POST. What this class must not do is
/// add a **second** challenge fetch to the sequence — that replaces the
/// challenge itself, so the digits the student read would be judged against a
/// challenge that is not theirs.
library;

import 'dart:async';

import 'models.dart';
import 'portal.dart';
import 'top_up.dart';

/// A [PortalClient] that serialises its operations per account.
class SerialisedPortalClient implements PortalClient {
  SerialisedPortalClient(this._inner);

  final PortalClient _inner;

  /// Tail of the per-account operation queue.
  ///
  /// Each operation chains onto the previous one for that account, so the
  /// requests of two operations for the same account are never interleaved.
  /// Accounts have separate queues and proceed independently.
  final Map<AccountId, Future<void>> _queues = {};

  /// Runs [body] with the account's queue to itself.
  Future<T> _exclusive<T>(
    AccountId accountId,
    Future<T> Function() body,
  ) {
    final previous = _queues[accountId];
    final completer = Completer<T>();

    Future<void> run() async {
      try {
        completer.complete(await body());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    }

    final chained = (previous ?? Future<void>.value()).then((_) => run());

    // Record this as the queue tail, but never let a failure poison the
    // chain: the next operation must still get a chance to run.
    final tail = chained.then((_) {}, onError: (_) {});
    _queues[accountId] = tail;
    tail.whenComplete(() {
      if (identical(_queues[accountId], tail)) _queues.remove(accountId);
    });

    return completer.future;
  }

  // --- Authentication ---

  @override
  Future<LoginChallenge?> beginLogin(String username) =>
      _exclusive(username, () => _inner.beginLogin(username));

  @override
  Future<Session> completeLogin({
    required String username,
    required String password,
    LoginChallengeResponse? challenge,
  }) =>
      _exclusive(
        username,
        () => _inner.completeLogin(
          username: username,
          password: password,
          challenge: challenge,
        ),
      );

  @override
  Future<Session> refresh(Session session) =>
      _exclusive(session.account, () => _inner.refresh(session));

  @override
  Future<void> logout(Session session) =>
      _exclusive(session.account, () => _inner.logout(session));

  // --- Time ---

  @override
  Future<DateTime> fetchServerTime(Session session) =>
      _exclusive(session.account, () => _inner.fetchServerTime(session));

  // --- Reads ---

  @override
  Future<Balance> fetchBalance(Session session) =>
      _exclusive(session.account, () => _inner.fetchBalance(session));

  @override
  Future<List<MealOffering>> fetchOfferings(
    Session session,
    DateTime date,
  ) =>
      _exclusive(
        session.account,
        () => _inner.fetchOfferings(session, date),
      );

  @override
  Future<List<MealMenu>> fetchMenu(Session session, DateTime date) =>
      _exclusive(session.account, () => _inner.fetchMenu(session, date));

  @override
  Future<BookableMenus> fetchBookableMenus(
    Session session, {
    int days = 7,
  }) =>
      _exclusive(
        session.account,
        () => _inner.fetchBookableMenus(session, days: days),
      );

  @override
  Future<List<Reservation>> fetchReservations(Session session) =>
      _exclusive(session.account, () => _inner.fetchReservations(session));

  @override
  Future<List<Transaction>> fetchTransactions(Session session) =>
      _exclusive(session.account, () => _inner.fetchTransactions(session));

  @override
  Future<BasketPage> fetchBasket(Session session, {String? cursor}) =>
      _exclusive(
        session.account,
        () => _inner.fetchBasket(session, cursor: cursor),
      );

  @override
  Future<BasketHoldStatus?> holdingsOnBuyPage(
    Session session, {
    required DateTime date,
    required String optionId,
  }) =>
      _exclusive(
        session.account,
        () => _inner.holdingsOnBuyPage(
          session,
          date: date,
          optionId: optionId,
        ),
      );

  // --- Writes ---

  @override
  Future<ClaimResult> claim(Session session, ListingId listingId) =>
      _exclusive(session.account, () => _inner.claim(session, listingId));

  @override
  Future<Reservation> reserve(Session session, MealOffering offering) =>
      _exclusive(session.account, () => _inner.reserve(session, offering));

  @override
  Future<List<Reservation>> reserveAll(
    Session session,
    List<MealOffering> offerings,
  ) =>
      _exclusive(session.account, () => _inner.reserveAll(session, offerings));

  @override
  Future<CancelOutcome> cancel(Session session, MealRef ref) =>
      _exclusive(session.account, () => _inner.cancel(session, ref));

  @override
  Future<SaleListingResult> listMealForSale(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  }) =>
      _exclusive(
        session.account,
        () => _inner.listMealForSale(
          session,
          date: date,
          slot: slot,
          reserveType: reserveType,
        ),
      );

  @override
  Future<SaleListingResult> removeFromSale(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  }) =>
      _exclusive(
        session.account,
        () => _inner.removeFromSale(
          session,
          date: date,
          slot: slot,
          reserveType: reserveType,
        ),
      );

  @override
  Future<ForgotReceiptOutcome> requestForgotReceipt(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  }) =>
      _exclusive(
        session.account,
        () => _inner.requestForgotReceipt(
          session,
          date: date,
          slot: slot,
          reserveType: reserveType,
        ),
      );

  // --- Top-up ---

  @override
  Future<TopUpPage> fetchTopUpPage(Session session) =>
      _exclusive(session.account, () => _inner.fetchTopUpPage(session));

  @override
  Future<Uri> beginTopUp(
    Session session,
    int amountRial,
    TopUpBank bank,
  ) =>
      _exclusive(
        session.account,
        () => _inner.beginTopUp(session, amountRial, bank),
      );

  @override
  Future<List<TopUpPayment>> fetchTopUpPayments(Session session) =>
      _exclusive(session.account, () => _inner.fetchTopUpPayments(session));

  @override
  Future<List<TopUpPayment>> verifyTopUpPayment(Session session) =>
      _exclusive(session.account, () => _inner.verifyTopUpPayment(session));

  // --- Navigation ---

  @override
  Uri? topUpUrl(Session session) => _inner.topUpUrl(session);
}
