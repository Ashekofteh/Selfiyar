/// The portal adapter contract: the single boundary between this app and the
/// university's Cullinan portal.
///
/// This is the only portal-aware layer. Everything below it is generic transport;
/// everything above it is site-independent. When the university redesigns the
/// site, exactly this layer breaks — and the frozen interface here is what lets
/// the domain core and UI be built and tested without the live portal.
///
/// The data types this interface speaks live in `portal_models.dart`; both are
/// re-exported by `portal.dart`, so callers can keep importing one path.
library;

import '../finance/top_up.dart';
import '../meal/models.dart';
import 'portal_models.dart';

/// The portal adapter.
///
/// Implementations must:
///  - keep cookies per account with zero cross-talk between accounts;
///  - perform login as one atomic sequence (GET page -> GET challenge -> answer
///    -> POST) because the challenge binds to the session at fetch time;
///  - never emit option or hall identifiers the live page did not offer.
///
/// ## The challenge and the session
///
/// The CAPTCHA answer is judged against the **session** the image was fetched
/// in, and the portal mints a new `ASP.NET_SessionId` every time it renders
/// the login page. So:
///
///  - [beginLogin] must fetch the challenge in the session it names, and
///    return that session id with it;
///  - [completeLogin] must post the answer in the session the response names,
///    restoring it if something has moved it.
///
/// Verified live 2026-10-21 (F77).
abstract class PortalClient {
  // --- Authentication ---

  /// Begins a login and returns a challenge when the portal demands one.
  ///
  /// The returned challenge names the session it is bound to, and that
  /// session is the one the answer has to be posted in.
  Future<LoginChallenge?> beginLogin(String username);

  /// Completes a login. [challenge] is the response to [beginLogin]'s challenge,
  /// if one was issued.
  ///
  /// The answer is posted in the session [LoginChallengeResponse.sessionId]
  /// names, so a challenge the student is answering survives anything that
  /// happened in between.
  Future<Session> completeLogin({
    required String username,
    required String password,
    LoginChallengeResponse? challenge,
  });

  /// Refreshes an existing session, or throws if it cannot be refreshed.
  Future<Session> refresh(Session session);

  Future<void> logout(Session session);

  // --- Time ---

  /// Server time, used to construct a [`ServerClock`]. All cutoff logic depends
  /// on this being authoritative rather than the device clock.
  Future<DateTime> fetchServerTime(Session session);

  // --- Reads ---

  Future<Balance> fetchBalance(Session session);

  Future<List<MealOffering>> fetchOfferings(Session session, DateTime date);

  /// The **official menu** for [date]: the halls that serve each meal and the
  /// dishes on offer for it.
  ///
  /// This is the weekly reservation page, and it is the page the hunt's setup
  /// reads. The marketplace ([fetchBasket]) answers a different question —
  /// which meals have been *released* for sale — and its hall list is a
  /// strict subset of this one's. A hunt must be able to name a hall that has
  /// not yet released anything, because the market fills up during the hunt
  /// window.
  ///
  /// The result is one [MealMenu] per meal slot served on [date]. Slots the
  /// university does not serve that day are absent, not empty.
  Future<List<MealMenu>> fetchMenu(Session session, DateTime date);

  /// The menus for the days that can still be **booked**.
  ///
  /// The days are counted from the **portal's** today, not the device's, and
  /// the portal's today is only known once the clock has been synced — which
  /// is what this read does. So the caller cannot name the dates in
  /// advance; it asks for a number of days, and the adapter works out which
  /// days those are once the response has been read.
  ///
  /// Asking for the days one at a time instead would mean one read per day,
  /// and every request the portal sees is a request pattern.
  ///
  /// The result holds one [MealMenu] per meal slot served on one of the
  /// dates. A date the portal does not serve simply has no menu.
  Future<BookableMenus> fetchBookableMenus(Session session, {int days = 7});

  Future<List<Reservation>> fetchReservations(Session session);

  /// The account's transaction history.
  ///
  /// **Necessary because a Food Basket purchase does not appear in the weekly
  /// reservation grid.** Verified by a live purchase (2026-10-19): the grids
  /// were byte-for-byte identical before and after, and the meal existed only
  /// as a ledger row. A digest that reads only the grids would report "no
  /// lunch" on a day the student had in fact bought one.
  ///
  /// The FULL history must be returned, not just the most recent row: the
  /// page's main grid holds a single row (the newest transaction) while the
  /// history lives in its `grdDetail_N` sub-grids.
  Future<List<Transaction>> fetchTransactions(Session session);

  /// One page of basket listings.
  ///
  /// [halls], when non-empty, names the halls a hunt is willing to buy from,
  /// highest priority first. The buy page renders one hall per row, so an
  /// adapter should re-render the target [slot]'s row for up to two of those
  /// halls (a bounded number of read-only postbacks) and merge the listings it
  /// sees. Without it, every hall but the portal's default is invisible.
  Future<BasketPage> fetchBasket(
    Session session, {
    String? cursor,
    List<HallId> halls = const [],
    MealSlot? slot,
  });

  /// What the basket buy page says about one option's row.
  ///
  /// **This is the only way to establish whether a basket purchase landed.**
  /// A purchase does not appear in the weekly reservation grid (verified live
  /// 2026-10-19), so [fetchReservations] cannot reconcile an ambiguous claim
  /// on the basket. Returns null when the portal no longer lists the option.
  Future<BasketHoldStatus?> holdingsOnBuyPage(
    Session session, {
    required DateTime date,
    required String optionId,
  });

  // --- Writes ---

  /// Claims a listing. The distinction between the three return types is load
  /// bearing; see [ClaimResult].
  Future<ClaimResult> claim(Session session, ListingId listingId);

  Future<Reservation> reserve(Session session, MealOffering offering);

  /// Reserves all offerings in [offerings].
  ///
  /// The default implementation checks [requiredBalanceRial] against a portal
  /// balance read and then sequentially calls [reserve] for backwards
  /// compatibility. Concrete implementations (such as CullinanPortalClient)
  /// can batch submissions into unified WebForms POST requests and check the
  /// balance of the reservation page they read anyway, avoiding the extra read.
  ///
  /// [requiredBalanceRial], when given, is the batch's total price. An
  /// implementation must refuse the whole batch **before the first write** when
  /// the balance is below it, throwing [InsufficientBalanceException]. This is
  /// what keeps a batch atomic: the student is never left with the first slot
  /// booked and the rest refused.
  Future<List<Reservation>> reserveAll(
    Session session,
    List<MealOffering> offerings, {
    int? requiredBalanceRial,
  }) async {
    if (requiredBalanceRial != null) {
      final balance = await fetchBalance(session);
      if (balance.amountRial < requiredBalanceRial) {
        throw InsufficientBalanceException(
          balanceRial: balance.amountRial,
          requiredRial: requiredBalanceRial,
        );
      }
    }
    final results = <Reservation>[];
    for (final offering in offerings) {
      results.add(await reserve(session, offering));
    }
    return results;
  }

  /// Cancels the meal held for [ref].
  ///
  /// ## Why the outcome is a type and not a `void`
  ///
  /// The portal **refuses a locked date silently**: the row renders `disabled`
  /// and the server discards the post with no error label and no state change
  /// (F14). The response is a plain `200`, so a client that inferred the
  /// outcome from the status code would report a success for a cancel that
  /// changed nothing — and then hide a meal the student still holds (F63).
  ///
  /// So the outcome is established by **reading the portal back**, exactly as
  /// [reserve] does, and reported as one of three cases.
  ///
  /// ## Why the meal is named by a [MealRef] and not a string
  ///
  /// A meal id is a `(date, slot)` pair, and the pair used to travel as a
  /// string the adapter parsed back. That parse could land on the **wrong
  /// slot** without anyone noticing (F65), so the pair is carried as values
  /// now.
  Future<CancelOutcome> cancel(Session session, MealRef ref);

  /// Lists the meal held for (date, slot) for sale on the secondary Food Basket
  /// (FoodBasketSale.aspx).
  Future<SaleListingResult> listMealForSale(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  });

  /// Removes a meal held for (date, slot) from sale in the secondary Food Basket
  /// (FoodBasketSale.aspx).
  Future<SaleListingResult> removeFromSale(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  });

  /// Requests a forgot-card slip (فیش فراموشی) for [date] and [slot].
  ///
  /// Maximum quota is 2 slips per meal slot per month per account.
  Future<ForgotReceiptOutcome> requestForgotReceipt(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  });

  // --- Top-up ---

  /// Reads the top-up page: the balance, and the banks that work.
  Future<TopUpPage> fetchTopUpPage(Session session);

  /// Starts a top-up and returns the **bank gateway** the student must pay at.
  ///
  /// The top-up is a three-step portal flow (F54), and this method performs
  /// the first two:
  ///
  ///   1. POST the amount and the chosen bank, which the portal answers with
  ///      a confirmation page;
  ///   2. POST the confirmation's `btnPay`, which the portal answers with a
  ///      **redirect to the bank's gateway**, carrying a token.
  ///
  /// The redirect is read, not followed: the gateway is unreachable from this
  /// transport (F55), and it is a browser page anyway.
  ///
  /// The returned URL must be opened in a WebView, not fetched.
  Future<Uri> beginTopUp(Session session, int amountRial, TopUpBank bank);

  /// The account's internet-payment history, newest first.
  ///
  /// This is the **proof** that a top-up landed, not the balance: the credit
  /// is applied asynchronously, after the portal re-queries the bank (F58).
  Future<List<TopUpPayment>> fetchTopUpPayments(Session session);

  /// Queries the bank to verify a pending top-up payment, newest first.
  Future<List<TopUpPayment>> verifyTopUpPayment(Session session);

  // --- Navigation ---

  /// The top-up URL, or null when the portal offers no constructible link (in
  /// which case the UI navigates instead).
  Uri? topUpUrl(Session session);
}
