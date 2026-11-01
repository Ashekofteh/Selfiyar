/// Reserving and cancelling a weekly meal.
///
/// ## Why this is a service and not a screen
///
/// A reservation is a **write** to the portal, and it is not undoable by
/// simply forgetting it: once the cutoff passes, the meal is committed and
/// cannot be given back. So the decision to book lives in the platform layer,
/// where it can be checked against the one-meal rule and the account's
/// balance **before** the request goes out, and where the outcome is
/// established by reading the portal back rather than by trusting the
/// response.
///
/// The write path itself is proven — a live book-and-cancel cycle (F14) and a
/// live basket purchase (F16) — so what was missing was not the ability to
/// reserve but any way for the user to ask for it.
library;

import '../core/local_meal_store.dart';
import '../core/meal_invariant.dart';
import '../core/models.dart';
import '../core/portal.dart';
import '../core/session_manager.dart';

/// Why a reservation could not be made.
enum ReservationFailure {
  /// The account already holds a meal for that date and slot.
  ///
  /// The one-meal rule. The portal does **not** enforce it (F22), so the app
  /// must — and a second meal for a slot the student already has is money
  /// spent on food that cannot be collected.
  slotAlreadyHeld,

  /// The date's cutoff has passed, so the portal will refuse the booking.
  locked,

  /// The balance cannot cover the meal's price.
  insufficientFunds,

  /// The account has no usable session.
  noSession,
}

/// The outcome of a reservation attempt.
class ReservationOutcome {
  const ReservationOutcome.reserved(this.reservation)
      : failure = null,
        message = null,
        deficitRial = null;

  const ReservationOutcome.failed(
    this.failure,
    this.message, {
    this.deficitRial,
  }) : reservation = null;

  /// The reservation the account now holds, when it succeeded.
  final Reservation? reservation;

  /// Why it failed, when it did.
  final ReservationFailure? failure;

  /// The message to show the user.
  final String? message;

  /// When [failure] is [ReservationFailure.insufficientFunds], the missing
  /// amount in Rial.
  final int? deficitRial;

  bool get succeeded => reservation != null;

  @override
  String toString() => succeeded
      ? 'ReservationOutcome.reserved(${reservation!.id})'
      : 'ReservationOutcome.failed(${failure?.name})';
}

/// Books and cancels weekly meals.
class ReservationService {
  ReservationService({
    required this.client,
    required this.sessions,
    required this.mealStore,
    this.persist,
  });

  final PortalClient client;
  final SessionManager sessions;

  /// The mirror of held meals, which the one-meal rule is checked against.
  final LocalMealStore mealStore;

  /// Persists the mirror after a change.
  final Future<void> Function()? persist;

  /// Books [offering] for [accountId].
  ///
  /// ## The order of the checks
  ///
  /// The one-meal rule is checked **first**, against the local mirror,
  /// because it is free and it is the rule the portal does not enforce. A
  /// booking that would give the student two lunches for one day is refused
  /// before a single request is made.
  ///
  /// The balance is checked next, for the same reason: a booking the account
  /// cannot pay for is refused before the request, not after the money has
  /// moved.
  ///
  /// The cutoff is the portal's own: a locked row is refused **silently** by
  /// the server (F: session 12), so the client checks it first rather than
  /// discovering it from an absent reservation.
  Future<ReservationOutcome> reserve({
    required AccountId accountId,
    required MealOffering offering,
  }) async {
    // The one-meal rule, checked against the mirror.
    final ledger = mealStore.toLedger();
    final admission = ledger.check(
      accountId: accountId,
      date: offering.date,
      slot: offering.slot,
      source: MealSource.weeklyReservation,
    );
    if (!admission.isAllowed) {
      return const ReservationOutcome.failed(
        ReservationFailure.slotAlreadyHeld,
        'برای این تاریخ و وعده، غذای دیگری در حساب شما ثبت شده است.',
      );
    }

    // The cutoff. The portal renders a locked row `disabled` and ignores the
    // post entirely, so this is checked before the request rather than
    // discovered from its absence afterwards.
    if (!offering.reservable) {
      return const ReservationOutcome.failed(
        ReservationFailure.locked,
        'مهلت رزرو این تاریخ به پایان رسیده است.',
      );
    }

    // The balance. A booking the account cannot pay for must not be sent.
    Balance? balance;
    try {
      balance = await _readBalance(accountId);
    } catch (_) {
      balance = null;
    }
    if (balance == null) {
      return const ReservationOutcome.failed(
        ReservationFailure.noSession,
        'ورود به سامانه ممکن نشد، پس رزرو انجام نشد.',
      );
    }
    if (balance.amountRial < offering.option.priceRial) {
      final deficit = offering.option.priceRial - balance.amountRial;
      return ReservationOutcome.failed(
        ReservationFailure.insufficientFunds,
        'موجودی حساب برای این وعده کافی نیست.',
        deficitRial: deficit,
      );
    }

    // The write.
    try {
      final reservation = await sessions.withSession(
        accountId,
        (session) => client.reserve(session, offering),
      );

      // The mirror follows the portal, not the other way round: the portal is
      // the authority for what is held.
      mealStore.put(StoredMeal(
        accountId: accountId,
        date: reservation.date,
        slot: reservation.slot,
        source: MealSource.weeklyReservation,
        capturedAt: DateTime.now().toUtc(),
        optionId: reservation.option.id,
        dishName: reservation.option.name,
        hallName: reservation.hall.name,
        priceRial: reservation.option.priceRial,
      ));
      await persist?.call();

      return ReservationOutcome.reserved(reservation);
    } on ReservationLockedException {
      return const ReservationOutcome.failed(
        ReservationFailure.locked,
        'مهلت رزرو این تاریخ به پایان رسیده است.',
      );
    } on LoginRejectedException {
      return const ReservationOutcome.failed(
        ReservationFailure.noSession,
        'نشست منقضی شده است. دوباره تلاش کنید.',
      );
    } catch (error) {
      return ReservationOutcome.failed(
        ReservationFailure.noSession,
        'رزرو انجام نشد: $error',
      );
    }
  }

  /// Modifies an existing weekly reservation (e.g. changing the dish option or dining hall).
  ///
  /// Unlike [reserve], this does not refuse with [ReservationFailure.slotAlreadyHeld]
  /// because the student is replacing their existing choice for this slot.
  Future<ReservationOutcome> modifyReservation({
    required AccountId accountId,
    required MealOffering offering,
  }) async {
    // The cutoff.
    if (!offering.reservable) {
      return const ReservationOutcome.failed(
        ReservationFailure.locked,
        'مهلت رزرو این تاریخ به پایان رسیده است.',
      );
    }

    // The balance check for price difference.
    final existing = mealStore.find(accountId, offering.date, offering.slot);
    final existingPrice = existing?.priceRial ?? 0;
    final priceDiff = offering.option.priceRial - existingPrice;

    if (priceDiff > 0) {
      Balance? balance;
      try {
        balance = await _readBalance(accountId);
      } catch (_) {
        balance = null;
      }
      if (balance == null) {
        return const ReservationOutcome.failed(
          ReservationFailure.noSession,
          'ورود به سامانه ممکن نشد، پس تغییر رزرو انجام نشد.',
        );
      }
      if (balance.amountRial < priceDiff) {
        final deficit = priceDiff - balance.amountRial;
        return ReservationOutcome.failed(
          ReservationFailure.insufficientFunds,
          'موجودی حساب برای پرداخت مابه‌التفاوت این غذا کافی نیست.',
          deficitRial: deficit,
        );
      }
    }

    // The write.
    try {
      final reservation = await sessions.withSession(
        accountId,
        (session) => client.reserve(session, offering),
      );

      mealStore.put(StoredMeal(
        accountId: accountId,
        date: reservation.date,
        slot: reservation.slot,
        source: MealSource.weeklyReservation,
        capturedAt: DateTime.now().toUtc(),
        optionId: reservation.option.id,
        dishName: reservation.option.name,
        hallName: reservation.hall.name,
        priceRial: reservation.option.priceRial,
      ));
      await persist?.call();

      return ReservationOutcome.reserved(reservation);
    } on ReservationLockedException {
      return const ReservationOutcome.failed(
        ReservationFailure.locked,
        'مهلت رزرو این تاریخ به پایان رسیده است.',
      );
    } on LoginRejectedException {
      return const ReservationOutcome.failed(
        ReservationFailure.noSession,
        'نشست منقضی شده است. دوباره تلاش کنید.',
      );
    } catch (error) {
      return ReservationOutcome.failed(
        ReservationFailure.noSession,
        'تغییر رزرو انجام نشد: $error',
      );
    }
  }

  /// Cancels the meal held for (date, slot).
  ///
  /// The weekly cancel is "uncheck the row and save again" (F14) — there is
  /// no cancel button on the portal. The adapter's [PortalClient.cancel]
  /// posts the row's own state, so the account's other meals are untouched:
  /// an ASP.NET checkbox absent from a post reads as *unchecked*, and posting
  /// only one row would cancel everything.
  ///
  /// ## The mirror follows the portal, not the request
  ///
  /// A locked date is refused **silently** (F14): the server discards the
  /// post and answers `200`, so the request cannot tell success from refusal.
  /// Removing the meal on the strength of the response would hide a meal the
  /// student still holds — and the reminders would stop mentioning it too
  /// (F63). So the adapter reads the portal back, and the mirror is only
  /// touched once the portal says the meal is gone.
  Future<CancelOutcome> cancel({
    required AccountId accountId,
    required DateTime date,
    required MealSlot slot,
  }) async {
    final CancelOutcome outcome;
    try {
      outcome = await sessions.withSession(
        accountId,
        (session) => client.cancel(
          session,
          MealRef(date: date, slot: slot),
        ),
      );
    } catch (_) {
      // The portal could not be reached. The meal may or may not have been
      // released, so nothing is removed and the student is told the cancel
      // could not be confirmed.
      return const CancelAmbiguous('لغو قابل تایید نبود.');
    }

    if (outcome is CancelSucceeded) {
      mealStore.remove(accountId, date, slot);
      await persist?.call();
    }

    return outcome;
  }

  /// Lists the meal held for (date, slot) for sale on the secondary Food Basket
  /// (`FoodBasketSale.aspx`).
  Future<SaleListingResult> listForSale({
    required AccountId accountId,
    required DateTime date,
    required MealSlot slot,
  }) async {
    final SaleListingResult outcome;
    try {
      outcome = await sessions.withSession(
        accountId,
        (session) => client.listMealForSale(
          session,
          date: date,
          slot: slot,
        ),
      );
    } catch (e) {
      return SaleListingAmbiguous('ارتباط با سامانه برقرار نشد: $e');
    }

    return outcome;
  }

  /// Removes a meal listed for sale in the secondary Food Basket
  /// (`FoodBasketSale.aspx`).
  Future<SaleListingResult> removeFromSale({
    required AccountId accountId,
    required DateTime date,
    required MealSlot slot,
  }) async {
    final SaleListingResult outcome;
    try {
      outcome = await sessions.withSession(
        accountId,
        (session) => client.removeFromSale(
          session,
          date: date,
          slot: slot,
        ),
      );
    } catch (e) {
      return SaleListingAmbiguous('ارتباط با سامانه برقرار نشد: $e');
    }

    return outcome;
  }

  Future<Balance?> _readBalance(AccountId accountId) async {
    try {
      return await sessions.withSession(
        accountId,
        (session) => client.fetchBalance(session),
      );
    } catch (_) {
      return null;
    }
  }
}
