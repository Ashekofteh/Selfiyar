/// Reading the portal and refreshing the local mirror.
///
/// The local store is what the reminders read, so keeping it fresh is the
/// bridge between "the portal knows something" and "the app knows something".
///
/// ## Why the sync is explicit rather than automatic
///
/// Every portal read costs a request, and a request pattern is the thing most
/// likely to get an account flagged. So the sync happens:
///   * when the user asks for it (pull to refresh), and
///   * when the app does something itself (a booking, a purchase, a cancel).
///
/// It is never a background poll. The sniping engine polls the **basket**, not
/// the account, and only inside a hunting window.
library;

import '../core/local_meal_store.dart';
import '../core/meal_invariant.dart';
import '../core/models.dart';
import '../core/portal.dart';
import '../core/persian.dart';
import '../core/session.dart' show SessionNeedsCaptcha;
import '../core/session_manager.dart';
import '../core/time.dart';

/// The outcome of a sync for one account.
class AccountSyncResult {
  const AccountSyncResult({
    required this.accountId,
    required this.ok,
    this.balanceRial,
    this.reservations = const [],
    this.transactions = const [],
    this.profileName,
    this.error,
    this.needsCaptcha,
  });

  final AccountId accountId;
  final bool ok;
  final int? balanceRial;
  final List<Reservation> reservations;

  /// The account's transaction history, as read for this sync.
  ///
  /// The dashboard's spend metric is computed from it, and the newest event
  /// per (date, slot) also tells the mirror which meals came from the basket.
  final List<Transaction> transactions;

  /// The student's real name, as the portal knows it. Null when the account
  /// could not be read.
  final String? profileName;

  final String? error;

  /// The CAPTCHA the student must answer, when the solver declined.
  ///
  /// The sync could not read the account, but the failure has a way forward:
  /// the student can read the code. The image travels with the result so the
  /// UI can show it — and it is the image that is *live*, bound to the
  /// session at fetch time, so the answer is judged against it.
  final SessionNeedsCaptcha? needsCaptcha;

  @override
  String toString() => 'AccountSyncResult($accountId, ok=$ok'
      '${error == null ? "" : ", error=$error"})';
}

/// Reads the portal for a set of accounts and refreshes the local mirror.
class PortalSync {
  PortalSync({
    required this.client,
    required this.sessions,
    required this.mealStore,
    this.onMealsChanged,
    this.persist,
  });

  final PortalClient client;
  final SessionManager sessions;
  final LocalMealStore mealStore;

  /// Called after the mirror changes, so the platform can write it to disk.
  ///
  /// The store cannot persist itself — it is a plain value type with no I/O —
  /// so the platform layer owns that and is told when there is something to
  /// save.
  final void Function()? onMealsChanged;

  /// Persists the mirror. Supplied by the platform layer; null in tests.
  final Future<void> Function()? persist;

  /// Reads one account.
  ///
  /// A failure is reported, not thrown: the user may have several accounts and
  /// one of them may be misconfigured, and the others should still work.
  Future<AccountSyncResult> sync(AccountId accountId) async {
    try {
      return await sessions.withSession(accountId, (session) async {
        final balance = await client.fetchBalance(session);
        final reservations = await client.fetchReservations(session);

        // The ledger is read as well, because a **Food Basket purchase never
        // appears in the weekly reservation grid**. Verified by a live purchase
        // (2026-10-19): the grids were byte-for-byte identical before and
        // after, and the meal existed only as a ledger row. A mirror built from
        // the grids alone would tell the student they have no lunch on a day
        // they in fact bought one.
        final rawTransactions = await _readTransactions(session);
        final transactions = [
          for (final t in rawTransactions)
            Transaction(
              accountId: accountId,
              type: t.type,
              foodName: t.foodName,
              slot: t.slot,
              weekday: t.weekday,
              date: t.date,
              count: t.count,
              amountRial: t.amountRial,
            ),
        ];

        // "Today" is the **portal's** day, not the device's.
        //
        // The portal's clock is the authority for everything it decides, and
        // the device's can be hours off. A mirror built on the device's date
        // would drop today's meals on a device running in another timezone —
        // and the drop is silent, so the reminder would simply have nothing
        // to say.
        final clock = sessions.clock;
        final now = clock.isSynced
            ? clock.portalTodayUtc
            : DateTime.now().toUtc();

        // Replace this account's meals in the local mirror, so a meal the
        // portal no longer lists does not linger in the reminders.
        final refreshed = <StoredMeal>[
          for (final reservation in reservations)
            StoredMeal(
              accountId: accountId,
              date: reservation.date,
              slot: reservation.slot,
              source: MealSource.weeklyReservation,
              capturedAt: DateTime.now().toUtc(),
              optionId: reservation.option.id,
              dishName: reservation.option.name,
              hallName: reservation.hall.name,
              priceRial: reservation.option.priceRial,
              isConsumed: reservation.state == ReservationState.consumed,
            ),
          ..._basketMeals(accountId, transactions, reservations, now),
        ];
        mealStore.replaceForAccount(accountId, refreshed);
        mealStore.prune(now);
        await persist?.call();
        onMealsChanged?.call();

        return AccountSyncResult(
          accountId: accountId,
          ok: true,
          balanceRial: balance.amountRial,
          profileName: balance.profileName,
          reservations: reservations,
          transactions: transactions,
        );
      });
    } on SessionUnavailableException catch (e) {
      return AccountSyncResult(
        accountId: accountId,
        ok: false,
        error: e.reason,
        needsCaptcha: e.needsCaptcha,
      );
    } catch (e) {
      return AccountSyncResult(
        accountId: accountId,
        ok: false,
        error: '$e',
      );
    }
  }

  /// Reads the ledger, tolerating a failure.
  ///
  /// The ledger is a bonus source, not the primary one: a portal that serves
  /// the transaction page but not the grid is still worth mirroring, and a
  /// ledger that cannot be read must not cost the whole sync.
  Future<List<Transaction>> _readTransactions(Session session) async {
    try {
      return await client.fetchTransactions(session);
    } catch (_) {
      return const [];
    }
  }

  /// The meals this account holds that came from the basket.
  ///
  /// The ledger is an **event log**, not a set of possessions: the same
  /// (date, slot) can appear several times — booked, released, booked again.
  /// Only the most recent event counts, and document order is recency order
  /// (verified live: the newest transaction appears second, not last), so the
  /// first event seen for a key is the most recent one.
  ///
  /// A weekly reservation is already in the mirror from the grid, so a
  /// reservation that appears in *both* sources is the same meal and must not
  /// be counted twice. The grid wins for those: it carries the hall, which the
  /// ledger does not.
  ///
  /// ## Only the meals that are still ahead
  ///
  /// The ledger is the account's **whole history** — every meal it ever had,
  /// including the ones it ate last month. A mirror of all of them would
  /// report, in one digest, every lunch the student has had since the
  /// semester began.
  ///
  /// So only the meals that are still ahead (today or later) are mirrored. The
  /// past is the portal's business, and the mirror exists to answer "what am
  /// I collecting", which is a question about the future.
  List<StoredMeal> _basketMeals(
    AccountId accountId,
    List<Transaction> transactions,
    List<Reservation> reservations,
    DateTime now,
  ) {
    final newest = <String, Transaction>{};
    for (final transaction in transactions) {
      final slot = transaction.slot;
      if (slot == null) continue;
      final key = '${transaction.date}|${slot.name}';
      newest.putIfAbsent(key, () => transaction);
    }

    // The meals the grid already accounts for. A reservation that appears in
    // both sources is the same meal, and the grid's version is the better one
    // — it carries the hall and the option id.
    //
    // The check is against the reservations just read, not against the store:
    // the store still holds the *previous* mirror at this point, and a meal
    // the portal has since dropped would wrongly suppress a real basket
    // purchase.
    //
    // The key is the **civil** date, because the two sources spell the date
    // differently: the grid carries a `DateTime` and the ledger carries the
    // portal's Jalali string.
    final fromGrid = <String>{};
    for (final reservation in reservations) {
      fromGrid.add('${HeldMeal.dateKey(reservation.date)}|'
          '${reservation.slot.name}');
    }

    final today = DateTime.utc(now.year, now.month, now.day);

    final out = <StoredMeal>[];
    for (final transaction in newest.values) {
      // A release means the meal was given up, so it is not held.
      if (!transaction.isAcquisition) continue;

      final date = parseJalaliDate(transaction.date);
      if (date == null) continue;

      // A meal that is already behind was eaten, missed or expired. It is not
      // something the student is collecting.
      if (date.isBefore(today)) continue;

      if (fromGrid.contains('${HeldMeal.dateKey(date)}|'
          '${transaction.slot!.name}')) {
        continue;
      }

      out.add(StoredMeal(
        accountId: accountId,
        date: date,
        slot: transaction.slot!,
        source: MealSource.basketPurchase,
        capturedAt: DateTime.now().toUtc(),
        dishName: transaction.foodName,
        priceRial: transaction.amountRial,
      ));
    }
    return out;
  }

  /// Reads every account, one after another.
  ///
  /// Sequential, not parallel: the portal is a shared resource and a burst of
  /// logins from one device looks like an attack. The requests are seconds
  /// apart and few.
  Future<List<AccountSyncResult>> syncAll(
    Iterable<AccountId> accountIds,
  ) async {
    final out = <AccountSyncResult>[];
    for (final accountId in accountIds) {
      out.add(await sync(accountId));
    }
    return out;
  }
}
