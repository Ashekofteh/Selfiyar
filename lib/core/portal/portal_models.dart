/// The portal adapter's data types: sessions, challenges, pages, and the
/// sealed result types that make an ambiguous write unrepresentable-as-a-success.
///
/// Kept apart from the interface itself so that a caller which only needs the
/// shapes (the UI, the local stores) does not import the contract, and so the
/// contract file stays readable. This file holds no logic.
library;

import 'dart:typed_data';

import '../meal/models.dart';

/// The portal's balance cannot cover a reservation or a batch, so nothing
/// was sent.
///
/// The balance and the write form are the **same** `Reservation.aspx` page
/// (`lblCredit`). A write path that has to read the page to post can therefore
/// check its total against the page's own balance before the first write,
/// instead of spending a separate read on the same HTML. Throwing before any
/// write is what keeps a multi-slot batch atomic: the student is never left
/// with the first slot booked and the rest refused.
class InsufficientBalanceException implements Exception {
  const InsufficientBalanceException({
    required this.balanceRial,
    required this.requiredRial,
  });

  /// What the page reported.
  final int balanceRial;

  /// The batch's total price.
  final int requiredRial;

  int get deficitRial => requiredRial - balanceRial;

  @override
  String toString() =>
      'InsufficientBalanceException: $balanceRial < $requiredRial';
}

/// The requested (hall, dish) pair is not one the portal page offered.
///
/// `drpFood` belongs to the hall the row was rendered for. A dish id read for
/// another hall is not valid for this one, and posting the pair makes the
/// portal silently save a **different** dish (C3). The adapter refuses before
/// any write, so this exception always means nothing was booked and no money
/// moved.
class ReservationNotOfferedException implements Exception {
  const ReservationNotOfferedException({
    required this.offering,
    this.message = 'این غذا در سلف انتخاب‌شده ارائه نمی‌شود.',
  });

  /// The pair that was refused.
  final MealOffering offering;

  /// Why it was refused, in words for the student.
  final String message;

  @override
  String toString() =>
      'ReservationNotOfferedException: ${offering.hall.id}/${offering.option.id}';
}

/// A reservation was written, but the portal saved a **different** hall or
/// dish than the one requested (C4).
///
/// This is a real booking: money moved, and the meal in [saved] is held. It is
/// not a clean success, though — the student asked for [requested] and must be
/// told what they actually got.
class ReservationSubstitutedException implements Exception {
  const ReservationSubstitutedException({
    required this.requested,
    required this.saved,
  });

  final MealOffering requested;
  final Reservation saved;

  ReservationSubstitution get substitution =>
      ReservationSubstitution(requested: requested, saved: saved);

  @override
  String toString() => 'ReservationSubstitutedException: '
      'asked ${requested.hall.id}/${requested.option.id}, '
      'saved ${saved.hall.id}/${saved.option.id}';
}

/// What was asked for, and what the portal actually saved.
class ReservationSubstitution {
  const ReservationSubstitution({required this.requested, required this.saved});

  final MealOffering requested;
  final Reservation saved;

  /// True when the hall differs from the request.
  bool get hallChanged => saved.hall.id != requested.hall.id;

  /// True when the dish differs from the request.
  bool get dishChanged => saved.option.id != requested.option.id;

  @override
  String toString() => 'ReservationSubstitution(${requested.option.name} -> '
      '${saved.option.name}, ${requested.hall.name} -> ${saved.hall.name})';
}

/// What the buy page reports about one option's row.
///
/// A meal is held when the row is **both** checked and charged. Neither alone
/// is enough: the portal renders every row of a just-saved grid as checked,
/// but only the bought row carries an amount.
class BasketHoldStatus {
  const BasketHoldStatus({required this.checked, required this.amountRial});

  final bool checked;
  final int amountRial;

  /// True when the account actually holds this meal.
  bool get isHeld => checked && amountRial > 0;

  @override
  String toString() =>
      'BasketHoldStatus(checked=$checked, amountRial=$amountRial)';
}

/// An authenticated session. Treated as an opaque bearer credential.
class Session {
  const Session({
    required this.account,
    required this.cookies,
    required this.establishedAt,
  });

  final AccountId account;

  /// Cookie name -> value. Held as data so the transport layer owns the jar.
  final Map<String, String> cookies;
  final DateTime establishedAt;

  @override
  String toString() =>
      'Session($account, established ${establishedAt.toIso8601String()})';
}

/// A login challenge the portal demands before completing authentication.
///
/// The portal uses a 4-digit image CAPTCHA, and the answer is judged against
/// the **session** the image was fetched in — not against the image itself.
///
/// ## Why the session id travels with the challenge
///
/// The portal mints a new `ASP.NET_SessionId` every time it renders the login
/// page, and the CAPTCHA endpoint sets no cookie of its own. So the challenge
/// lives in the session that was current when the image was fetched, and **any
/// other request in between replaces that session** and makes the answer
/// wrong. Verified live 2026-10-21: a read between the image and the answer
/// makes the portal refuse a correct code, and restoring the session id makes
/// it accepted again.
///
/// So the challenge carries the session id it is bound to, and the answer
/// carries it back. That is what lets the student take as long as they like to
/// read the code, and what lets the app keep reading the portal meanwhile.
class LoginChallenge {
  const LoginChallenge({
    required this.imageBytes,
    required this.kind,
    this.sessionId,
  });

  /// Raw image payload as served by the portal.
  ///
  /// A `Uint8List` because the image decoders (and the solver) want bytes,
  /// not a list of boxed ints.
  final Uint8List imageBytes;
  final ChallengeKind kind;

  /// The `ASP.NET_SessionId` the challenge is bound to.
  ///
  /// Null when the portal issued no session id, or when the client cannot
  /// tell. The answer is then posted in whatever session is current, which is
  /// correct as long as nothing was fetched in between.
  final String? sessionId;

  @override
  String toString() =>
      'LoginChallenge(${kind.name}, ${imageBytes.length} bytes)';
}

enum ChallengeKind {
  /// Four digits, as used by the Cullinan portal.
  digits4,

  /// Some other challenge we do not know how to solve automatically.
  unknown,
}

/// The user's answer to a challenge.
class LoginChallengeResponse {
  const LoginChallengeResponse(this.answer, {this.sessionId});

  final String answer;

  /// The session the answer must be posted in.
  ///
  /// The session the challenge was fetched in, carried back so the answer is
  /// judged against the challenge the student actually read. Null when the
  /// challenge did not name a session.
  final String? sessionId;
}

/// One page of basket inventory.
class BasketPage {
  const BasketPage({required this.listings, this.cursor});

  final List<Listing> listings;

  /// Cursor for the next page, when the portal paginates. Null means no more.
  final String? cursor;

  bool get hasMore => cursor != null;
}

/// The outcome of attempting to claim a listing.
///
/// Sealed on purpose. A claim that times out is neither success nor failure, and
/// conflating it with failure is the single most expensive bug available in this
/// project: a blind retry can buy two meals and charge the student twice. Making
/// ambiguity a distinct type means no caller can forget to handle it — the
/// compiler will insist.
sealed class ClaimResult {
  const ClaimResult();
}

/// The claim definitely succeeded.
class ClaimSucceeded extends ClaimResult {
  const ClaimSucceeded(this.reservation);

  final Reservation reservation;
}

/// The claim definitely failed, and the listing was not bought.
class ClaimRejected extends ClaimResult {
  const ClaimRejected(this.reason);

  final String reason;
}

/// We do not know whether the claim landed.
///
/// The engine must reconcile (re-fetch reservations to establish ground truth)
/// and must **never** retry the claim directly.
class ClaimAmbiguous extends ClaimResult {
  const ClaimAmbiguous(this.diagnostic);

  final String diagnostic;
}

/// The outcome of cancelling a weekly meal.
///
/// Sealed for the same reason [ClaimResult] is: a cancel that did not land
/// must never be mistaken for one that did. The three cases are genuinely
/// different, and the caller must say which one it is dealing with.
sealed class CancelOutcome {
  const CancelOutcome();
}

/// The meal is no longer held. The portal says so.
class CancelSucceeded extends CancelOutcome {
  const CancelSucceeded();
}

/// The cancel was refused: the date is past its cutoff, so the portal
/// ignored the post and the meal is still held.
///
/// This is not a failure of the request — the request was fine. It is the
/// portal's rule that a date which has locked cannot be given back (F14).
class CancelRefused extends CancelOutcome {
  const CancelRefused(this.reason);

  /// Why it was refused, in words for the student.
  final String reason;
}

/// We do not know whether the cancel landed.
///
/// The portal could not be read back, so the mirror must be left alone. The
/// meal may have been released, or it may still be held — and the next
/// authoritative read settles it.
class CancelAmbiguous extends CancelOutcome {
  const CancelAmbiguous(this.diagnostic);

  final String diagnostic;
}

/// The outcome of attempting to list a meal for sale in the Food Basket.
///
/// Sealed on purpose for the same reason [CancelOutcome] and [ClaimResult]
/// are: a listing that timed out or was refused must never be confused with
/// one that succeeded.
sealed class SaleListingResult {
  const SaleListingResult();
}

/// The meal was successfully listed for sale in the Food Basket.
class SaleListingSucceeded extends SaleListingResult {
  const SaleListingSucceeded([this.message]);

  /// Optional confirmation or feedback message from the portal.
  final String? message;
}

/// The listing was refused by the portal.
class SaleListingRefused extends SaleListingResult {
  const SaleListingRefused(this.reason);

  /// Why it was refused, in words for the student.
  final String reason;
}

/// We do not know whether the listing landed.
class SaleListingAmbiguous extends SaleListingResult {
  const SaleListingAmbiguous(this.diagnostic);

  final String diagnostic;
}

/// The type of reservation for forgot receipt request.
enum ReserveType {
  /// Weekly reservation (رزرو هفتگی - 0).
  weekly(0, 'رزرو هفتگی'),

  /// Day sale (روزفروش - 1).
  daily(1, 'روزفروش'),

  /// Food basket (سبد غذایی - 2).
  foodBasket(2, 'سبد غذایی');

  const ReserveType(this.value, this.label);
  final int value;
  final String label;
}

/// The outcome of requesting a temporary forgot-card receipt slip (فیش فراموشی).
sealed class ForgotReceiptOutcome {
  const ForgotReceiptOutcome();
}

/// The slip was successfully generated.
class ForgotReceiptSucceeded extends ForgotReceiptOutcome {
  const ForgotReceiptSucceeded({
    required this.date,
    required this.slot,
    required this.code,
    this.message,
    this.quotaRemaining,
  });

  final DateTime date;
  final MealSlot slot;

  /// The generated numeric slip token/code to show at the dining turnstile.
  final String code;

  /// Optional message from the portal.
  final String? message;

  /// Remaining monthly quota for this slot (if parsed).
  final int? quotaRemaining;
}

/// The slip was refused by the portal (e.g. limit exceeded, no meal found).
class ForgotReceiptRefused extends ForgotReceiptOutcome {
  const ForgotReceiptRefused(this.reason);

  final String reason;
}

/// Ambiguous outcome due to transport/network disruption.
class ForgotReceiptAmbiguous extends ForgotReceiptOutcome {
  const ForgotReceiptAmbiguous(this.diagnostic);

  final String diagnostic;
}

/// What went wrong during login, when it goes wrong.
class LoginFailure {
  const LoginFailure(this.reason, {this.retryable = false});

  final String reason;
  final bool retryable;
}

/// A transaction recorded in the account's ledger.
class Transaction {
  const Transaction({
    required this.accountId,
    required this.type,
    required this.foodName,
    required this.slot,
    required this.weekday,
    required this.date,
    required this.count,
    required this.amountRial,
  });

  /// Which account the transaction belongs to. The portal serves one account
  /// per session, so this is set by the adapter rather than parsed from the
  /// page.
  final AccountId accountId;

  /// The portal's transaction type, e.g. `رزرو غذا` (booking) or
  /// `انصراف از رزرو غذا` (withdrawal).
  final String type;

  /// The meal, e.g. `چلو اکبرجوجه,دوغ`.
  final String foodName;

  /// The meal slot, e.g. `ناهار`.
  final MealSlot? slot;

  /// The Persian weekday, e.g. `سه شنبه`.
  final String weekday;

  /// The Jalali date, e.g. `1405/07/28`.
  final String date;

  final int count;
  final int amountRial;

  /// True when this transaction is a meal being collected rather than given up.
  ///
  /// A withdrawal (`انصراف از رزرو غذا`) means the meal was released, so it must
  /// never be reported as something the student is collecting.
  bool get isAcquisition => type.contains('رزرو') && !type.contains('انصراف');

  /// True when this transaction is a release of a meal.
  bool get isWithdrawal => type.contains('انصراف');

  @override
  String toString() =>
      '$type | $foodName | ${slot?.name ?? weekday} | $date '
      '| $count | $amountRial';
}

/// The menus for the days that can still be booked.
///
/// The days and the menus come back together, because they are worked out
/// together: the days are counted from the portal's today, and the portal's
/// today is only known once the read that fetched the menu has been made. A
/// caller that worked the days out for itself would have to repeat that
/// reasoning — and would get it wrong whenever the two answers disagreed.
class BookableMenus {
  const BookableMenus({required this.dates, required this.menus});

  /// The days that can still be booked, in order.
  final List<DateTime> dates;

  /// One entry per meal slot served on one of [dates].
  final List<MealMenu> menus;
}
