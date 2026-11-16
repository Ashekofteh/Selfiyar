/// The Cullinan portal adapter: the only code that knows this particular
/// website exists.
///
/// Everything above this layer reasons in domain terms (listings,
/// reservations, meals) and everything below it moves bytes. When the
/// university redesigns their site, this layer is what breaks — and it is the
/// only thing that should.
///
/// ## Shape
///
/// The portal is one site but many pages, and each page family has its own
/// rules. So the adapter is split by page area, and this class is the
/// composition root: it owns one transport, one clock, and one collaborator per
/// area, and it delegates every [PortalClient] call to the collaborator that
/// speaks that page.
///
///  * [CullinanAuth] — login, CAPTCHA, refresh, logout, server time;
///  * [CullinanReservation] — weekly menus, held reservations, reserve/cancel;
///  * [CullinanBasketBuy] — buy-page listings, the date filter, the purchase;
///  * [CullinanBasketSale] — listing a held meal for sale and taking it back;
///  * [CullinanReceipt] — the forgot-card slip;
///  * [CullinanTransactions] — the transaction history;
///  * [CullinanTopUp] — the ePay amount form, bank hand-off, and history.
///
/// The collaborators never call each other. They share only the transport and
/// the clock, which is what keeps a change in one page area from rippling
/// through the others.
///
/// ## What the portal's pages actually look like
///
/// `FoodBasketBuy.aspx` renders one row per (date, meal slot) for a single
/// date, chosen by the `txtDate` filter. Each row carries a `chkReserve`
/// checkbox, a hall dropdown, a **food dropdown holding the purchasable
/// options**, a count dropdown, a price, and a shared `btnSave`.
///
/// The important consequence: **the individual listings live in the food
/// dropdown, not in the grid rows.** A row for lunch carried two options
/// (`62726` and `62729`), each with its own menu item and price. A "listing" is
/// therefore `(date, slot, option id)` — which is why
/// [Listing.compositeListingId] exists.
///
/// `Reservation.aspx` renders three grids (breakfast, lunch, dinner) of seven
/// days each, with a per-grid `btnSaveBreakfast` / `btnSaveLunch` /
/// `btnSaveDinner`.
///
/// The portal is ASP.NET WebForms: every POST must carry `__VIEWSTATE` from the
/// page it came from, and `__EVENTVALIDATION` is absent, so option ids come
/// from the live dropdowns rather than from constants.
library;

import '../../core/finance/top_up.dart';
import '../../core/meal/models.dart';
import '../../core/portal/portal.dart';
import '../../transport/http_transport.dart';
import 'cullinan_auth.dart';
import 'cullinan_basket_buy.dart';
import 'cullinan_basket_sale.dart';
import 'cullinan_receipt.dart';
import 'cullinan_reservation.dart';
import 'cullinan_top_up.dart';
import 'cullinan_transactions.dart';

/// The Cullinan implementation of [PortalClient].
class CullinanClient implements PortalClient {
  CullinanClient({required this.transport, DateTime Function()? now})
    : _now = now ?? (() => DateTime.now().toUtc()) {
    auth = CullinanAuth(transport: transport, clock: _now);
    reservation = CullinanReservation(transport: transport, clock: _now);
    basketBuy = CullinanBasketBuy(transport: transport, clock: _now);
    basketSale = CullinanBasketSale(transport: transport, clock: _now);
    receipt = CullinanReceipt(transport: transport, clock: _now);
    transactions = CullinanTransactions(transport: transport, clock: _now);
    topUp = CullinanTopUp(transport: transport, clock: _now);
  }

  final PortalTransport transport;
  final DateTime Function() _now;

  // One collaborator per portal page family.
  late final CullinanAuth auth;
  late final CullinanReservation reservation;
  late final CullinanBasketBuy basketBuy;
  late final CullinanBasketSale basketSale;
  late final CullinanReceipt receipt;
  late final CullinanTransactions transactions;
  late final CullinanTopUp topUp;

  // ---------------------------------------------------------------- auth

  @override
  Future<LoginChallenge?> beginLogin(String username) =>
      auth.beginLogin(username);

  @override
  Future<Session> completeLogin({
    required String username,
    required String password,
    LoginChallengeResponse? challenge,
  }) => auth.completeLogin(
    username: username,
    password: password,
    challenge: challenge,
  );

  @override
  Future<Session> refresh(Session session) => auth.refresh(session);

  @override
  Future<void> logout(Session session) => auth.logout(session);

  // ---------------------------------------------------------------- time

  @override
  Future<DateTime> fetchServerTime(Session session) =>
      auth.fetchServerTime(session);

  // ---------------------------------------------------------------- reads

  @override
  Future<Balance> fetchBalance(Session session) =>
      reservation.fetchBalance(session);

  @override
  Future<List<MealOffering>> fetchOfferings(Session session, DateTime date) =>
      reservation.fetchOfferings(session, date);

  @override
  Future<List<MealMenu>> fetchMenu(Session session, DateTime date) =>
      reservation.fetchMenu(session, date);

  @override
  Future<BookableMenus> fetchBookableMenus(Session session, {int days = 7}) =>
      reservation.fetchBookableMenus(session, days: days);

  @override
  Future<List<Reservation>> fetchReservations(Session session) =>
      reservation.fetchReservations(session);

  @override
  Future<List<Transaction>> fetchTransactions(Session session) =>
      transactions.fetchTransactions(session);

  @override
  Future<BasketPage> fetchBasket(Session session, {String? cursor}) =>
      basketBuy.fetchBasket(session, cursor: cursor);

  @override
  Future<BasketHoldStatus?> holdingsOnBuyPage(
    Session session, {
    required DateTime date,
    required String optionId,
  }) => basketBuy.holdingsOnBuyPage(session, date: date, optionId: optionId);

  // ---------------------------------------------------------------- writes

  @override
  Future<ClaimResult> claim(Session session, ListingId listingId) =>
      basketBuy.claim(session, listingId);

  @override
  Future<Reservation> reserve(Session session, MealOffering offering) =>
      reservation.reserve(session, offering);

  @override
  Future<List<Reservation>> reserveAll(
    Session session,
    List<MealOffering> offerings,
  ) => reservation.reserveAll(session, offerings);

  @override
  Future<CancelOutcome> cancel(Session session, MealRef ref) =>
      reservation.cancel(session, ref);

  @override
  Future<SaleListingResult> listMealForSale(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  }) => basketSale.listMealForSale(
    session,
    date: date,
    slot: slot,
    reserveType: reserveType,
  );

  @override
  Future<SaleListingResult> removeFromSale(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  }) => basketSale.removeFromSale(
    session,
    date: date,
    slot: slot,
    reserveType: reserveType,
  );

  @override
  Future<ForgotReceiptOutcome> requestForgotReceipt(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  }) => receipt.requestForgotReceipt(
    session,
    date: date,
    slot: slot,
    reserveType: reserveType,
  );

  // ---------------------------------------------------------------- top-up

  @override
  Future<TopUpPage> fetchTopUpPage(Session session) =>
      topUp.fetchTopUpPage(session);

  @override
  Future<Uri> beginTopUp(Session session, int amountRial, TopUpBank bank) =>
      topUp.beginTopUp(session, amountRial, bank);

  @override
  Future<List<TopUpPayment>> fetchTopUpPayments(Session session) =>
      topUp.fetchTopUpPayments(session);

  @override
  Future<List<TopUpPayment>> verifyTopUpPayment(Session session) =>
      topUp.verifyTopUpPayment(session);

  @override
  Uri? topUpUrl(Session session) => topUp.topUpUrl(session);
}

/// The adapter's historical name.
///
/// Callers and tests instantiate the client by this name, so it stays as an
/// alias for the composed [CullinanClient].
typedef CullinanPortalClient = CullinanClient;
