/// A ready-made [PortalClient] for tests that are not about the portal.
///
/// ## Why this exists
///
/// Every fake in the test suite implements the whole [PortalClient]
/// interface, and each one wrote out every method by hand. Every method
/// the interface gains is another method in ten files — and the day the
/// interface grows again, ten more edits.
///
/// The same drift already happened once: the fakes were copy-pasted into
/// several files and a change to [SessionStore] meant changing each copy.
/// So they live here, once.
///
/// The class is **concrete**: it implements every method with a harmless
/// default, so a test fake only overrides the two or three methods it is
/// actually about. The defaults are deliberately inert — a read returns
/// nothing, a write does nothing — because a stub that invented data would
/// make a test pass for the wrong reason.
library;

import 'package:bahonar_nut/core/models.dart';
import 'package:bahonar_nut/core/portal.dart';
import 'package:bahonar_nut/core/top_up.dart';

/// A portal that does nothing, and reports the top-up state a test sets.
///
/// A test fake extends this and overrides what it is about.
class FakePortalClient implements PortalClient {
  FakePortalClient({this.balanceRial = 0});

  /// The balance the portal reports.
  int balanceRial;

  /// The menus the portal reports. Empty until a test sets them.
  List<MealMenu> menus = const [];

  /// The payments the portal reports.
  List<TopUpPayment> topUpPayments = const [];

  /// The gateway the portal hands back.
  Uri topUpGateway =
      Uri.parse('https://sadad.shaparak.ir/VPG/Purchase/Index?token=stub');

  /// The amount the portal was asked to top up, and the bank it was asked for.
  int? topUpRequestedAmountRial;
  TopUpBank? topUpRequestedBank;

  // --- Authentication ---

  @override
  Future<LoginChallenge?> beginLogin(String username) async => null;

  @override
  Future<Session> completeLogin({
    required String username,
    required String password,
    LoginChallengeResponse? challenge,
  }) async =>
      Session(
        account: username,
        cookies: const {},
        establishedAt: DateTime.utc(2026, 10, 21),
      );

  @override
  Future<Session> refresh(Session session) async => session;

  @override
  Future<void> logout(Session session) async {}

  // --- Time ---

  @override
  Future<DateTime> fetchServerTime(Session session) async =>
      DateTime.utc(2026, 10, 21, 12);

  // --- Reads ---

  @override
  Future<Balance> fetchBalance(Session session) async => Balance(
        amountRial: balanceRial,
        fetchedAt: DateTime.utc(2026, 10, 21),
      );

  @override
  Future<List<MealOffering>> fetchOfferings(
    Session session,
    DateTime date,
  ) async =>
      const [];

  @override
  Future<List<MealMenu>> fetchMenu(Session session, DateTime date) async =>
      menus;

  @override
  Future<BookableMenus> fetchBookableMenus(
    Session session, {
    int days = 7,
  }) async =>
      const BookableMenus(dates: [], menus: []);

  @override
  Future<List<Reservation>> fetchReservations(Session session) async =>
      const [];

  @override
  Future<List<Transaction>> fetchTransactions(Session session) async =>
      const [];

  @override
  Future<BasketPage> fetchBasket(Session session, {String? cursor}) async =>
      const BasketPage(listings: []);

  @override
  Future<BasketHoldStatus?> holdingsOnBuyPage(
    Session session, {
    required DateTime date,
    required String optionId,
  }) async =>
      null;

  // --- Writes ---

  @override
  Future<ClaimResult> claim(Session session, ListingId listingId) async =>
      throw UnimplementedError('claim is not used by this test');

  @override
  Future<Reservation> reserve(Session session, MealOffering offering) async =>
      throw UnimplementedError('reserve is not used by this test');

  @override
  Future<CancelOutcome> cancel(Session session, MealRef ref) async =>
      const CancelSucceeded();

  @override
  Future<SaleListingResult> listMealForSale(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  }) async =>
      const SaleListingSucceeded();

  @override
  Future<SaleListingResult> removeFromSale(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  }) async =>
      const SaleListingSucceeded();

  @override
  Future<ForgotReceiptOutcome> requestForgotReceipt(
    Session session, {
    required DateTime date,
    required MealSlot slot,
    ReserveType reserveType = ReserveType.weekly,
  }) async =>
      ForgotReceiptSucceeded(
        date: date,
        slot: slot,
        code: '12345',
        message: 'فیش فراموشی با موفقیت صادر شد.',
      );

  // --- Top-up ---

  @override
  Future<TopUpPage> fetchTopUpPage(Session session) async => TopUpPage(
        balanceRial: balanceRial,
        banks: const [
          TopUpBank(
            id: r'ctl00$cphMain$dataLstBank$ctl00$imgBankLogo',
            name: 'درگاه سداد',
            logoPath: null,
          ),
        ],
        defaultAmountRial: balanceRial,
      );

  @override
  Future<Uri> beginTopUp(
    Session session,
    int amountRial,
    TopUpBank bank,
  ) async {
    topUpRequestedAmountRial = amountRial;
    topUpRequestedBank = bank;
    return topUpGateway;
  }

  @override
  Future<List<TopUpPayment>> fetchTopUpPayments(Session session) async =>
      topUpPayments;

  @override
  Future<List<TopUpPayment>> verifyTopUpPayment(Session session) async =>
      topUpPayments;

  // --- Navigation ---

  @override
  Uri? topUpUrl(Session session) => null;
}
