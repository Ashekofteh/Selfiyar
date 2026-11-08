/// Turning a fired reminder alarm into a notification.
///
/// ## Why this exists
///
/// The alarm is scheduled by the platform and fires with the app in the
/// background — or with the app not running at all. Something has to be
/// listening for the fire and posting the digest, and that something has to
/// work without the user having opened the app.
///
/// Two paths, deliberately:
///
///   * **The process is alive** (the app is open, or was backgrounded): the
///     platform's method channel carries the fired payload, and this
///     coordinator delivers the digest and re-arms the slot for tomorrow.
///   * **The process is dead** (the app was killed): the alarm cannot reach
///     Dart at all, so the native side **records the delivery** and the Dart
///     side picks it up the next time it runs.
///
/// The second path is the one that matters most: a reminder whose whole job
/// is to protect a cutoff cannot depend on the student having opened the app.
///
/// ## Why the dead-process path is a record and not a delivery
///
/// The digest is composed in Dart, from the local meal mirror, so there is
/// nothing to deliver from the native side. But there is also nothing to
/// *lose* from the native side: the receiver writes the payload to a place
/// that survives the process, and the Dart side delivers it when it next
/// runs. A reminder that was owed is never forgotten.
///
/// The alternative — starting a Flutter engine inside the receiver — would
/// deliver the digest at the exact minute even with the app killed. It is
/// also a much larger machine: an engine, an isolate, the whole platform
/// bridge, in a broadcast receiver. The record is the smaller thing that
/// keeps the promise, and it is honest about what it is: the digest arrives
/// when the student next opens the app, rather than never.
library;

import '../core/account.dart';
import '../core/local_meal_store.dart';
import '../core/meal_invariant.dart';
import '../core/models.dart';
import '../core/next_week.dart';
import '../core/reminder.dart';
import '../core/time.dart';
import 'reminder_service.dart';

/// Delivers a fired reminder.
class ReminderDelivery {
  ReminderDelivery({
    required this.service,
    required this.accounts,
    this.config,
    this.clock,
    this.readReservations,
    this.persist,
    this.readTimeout = const Duration(seconds: 20),
  });

  /// Posts the digest.
  final ReminderService service;

  /// The accounts, for their display names.
  ///
  /// The digest names each account, so it needs to know what to call them.
  ///
  /// Settable rather than final, because the account list changes as the user
  /// adds and removes accounts, and a delivery that named a removed account
  /// by its old id would be wrong.
  List<SavedAccount> accounts;

  /// The configuration to deliver against.
  ///
  /// Supplied by the caller at delivery time rather than held, so the
  /// configuration the user sees is the configuration that is delivered: a
  /// reminder must not fire for a slot the user has since switched off.
  ReminderConfig? config;

  /// The account id the current delivery is for, when there is more than one.
  ///
  /// The platform serves one account per session, so a multi-account digest
  /// needs each account's own session. The delivery is therefore per account
  /// and the platform layer is told which one to read.
  AccountId? accountId;

  /// The clock, for the nudge's schedule and its cutoff arithmetic.
  ///
  /// The server clock is authoritative: the nudge's deadline is the portal's
  /// own 20:00 cutoff, and a device clock an hour off would fire the nudge
  /// at the wrong time or miss the window entirely.
  final ServerClock? clock;

  /// Reads the account's reservations from the portal, for the nudge.
  ///
  /// The nudge asks what an account does **not** hold, and only a live read
  /// can answer that: the mirror is a cache of what was last seen, and a
  /// week-old cache cannot tell "not booked" from "not read yet".
  final Future<List<Reservation>> Function(AccountId accountId)?
      readReservations;

  /// Persists the meal store after an online re-read.
  final Future<void> Function()? persist;

  /// How long the nudge's live read may take.
  ///
  /// The read is bounded because a network read in Doze does not fail — it
  /// hangs, waiting for the system to open a maintenance window. An
  /// unbounded read would hold the whole delivery hostage, and the student
  /// would see nothing when they opened the app.
  ///
  /// Twenty seconds is long enough for a real read on a slow connection and
  /// short enough that a blocked one is reported as a failure rather than
  /// waited on. The transport's own timeout is thirty, so this fires first
  /// and the read is abandoned rather than left dangling.
  final Duration readTimeout;

  /// Delivers the reminder for [slot], and re-arms it for tomorrow.
  ///
  /// Returns the text that was posted, or null when there was nothing to say.
  ///
  /// The re-arm is not optional. An exact alarm is a one-shot: without a new
  /// one, tomorrow's reminder never comes, and the user has no idea why the
  /// reminders simply stopped.
  Future<ReminderSlot?> handleFire(String? payload) async {
    // The nudge is a different kind of fire: it asks about the coming week,
    // not about today's meals.
    if (payload == ReminderService.nudgePayload) {
      await _handleNudge();
      return null;
    }

    final slot = ReminderService.slotFor(payload);
    if (slot == null) return null;

    final config = this.config;
    if (config == null) return null;

    // A slot that is no longer active must not fire. The user may have
    // switched it off after the alarm was armed, and a reminder the user
    // turned off is noise — and the spec says a fire already in flight
    // completes, so the check is on the *configuration*, not on the alarm.
    if (!config.isSlotActive(slot)) return null;

    final accountNames = <AccountId, String>{
      for (final account in accounts) account.id: account.resolvedName,
    };

    // When live portal check is enabled, reconcile the mirror against the portal
    // before delivering the digest.
    if (config.liveCheckEnabled && readReservations != null) {
      final now = clock != null && clock!.isSynced
          ? clock!.portalTodayUtc
          : DateTime.now().toUtc();
      var anyUpdated = false;
      await Future.wait(
        config.accountsFor(slot).map((accountId) async {
          try {
            final reservations =
                await readReservations!(accountId).timeout(readTimeout);
            final existingBasketMeals = service.mealStore
                .forAccount(accountId)
                .where((m) => m.source == MealSource.basketPurchase);
            final refreshed = <StoredMeal>[
              for (final r in reservations)
                StoredMeal(
                  accountId: accountId,
                  date: r.date,
                  slot: r.slot,
                  source: MealSource.weeklyReservation,
                  capturedAt: now,
                  optionId: r.option.id,
                  dishName: r.option.name,
                  hallName: r.hall.name,
                  priceRial: r.option.priceRial,
                  isConsumed: r.state == ReservationState.consumed,
                ),
              ...existingBasketMeals,
            ];
            service.mealStore.replaceForAccount(accountId, refreshed);
            anyUpdated = true;
          } catch (_) {
            // Bounded timeout or offline: fall back gracefully to the local mirror.
          }
        }),
      );
      if (anyUpdated) {
        try {
          await persist?.call();
        } catch (_) {}
      }
    }

    await service.deliver(
      slot,
      config: config,
      accountNames: accountNames,
    );

    // Re-arm for tomorrow. A one-shot alarm with no successor is a reminder
    // that works exactly once.
    await service.armSlot(slot, config);

    return slot;
  }

  /// Delivers the reminders that were owed while the app was not running.
  ///
  /// The native side records a delivery when the alarm fires and the Dart
  /// side cannot be reached. This delivers them, and clears the record — but
  /// only after each one has actually been delivered, so a failure leaves
  /// the delivery owed rather than losing it.
  ///
  /// ## The digests go first
  ///
  /// The digests are composed from the **local mirror**, so they need no
  /// network and can be delivered instantly. The nudge is different: it asks
  /// what the account does *not* hold, and only a live read can answer that.
  ///
  /// So the nudge goes last, and it goes last on purpose. A network read in
  /// Doze is **blocked**, and it does not fail — it hangs until the system
  /// opens a maintenance window, which can be minutes away. Measured on the
  /// emulator: the catch-up read the owed nudge, waited ten seconds for a
  /// read that could not go out, and only then delivered — and the digest
  /// that was owed alongside it was stuck behind it the whole time.
  ///
  /// Delivering the digests first means the student hears about their meals
  /// immediately, and the nudge — which is the one that can wait — is the
  /// one that waits.
  ///
  /// Returns the payloads that were delivered.
  Future<List<String>> deliverPending(List<String> payloads) async {
    final delivered = <String>[];

    // The digests first, the nudge last.
    final ordered = [
      ...payloads.where((p) => p != ReminderService.nudgePayload),
      ...payloads.where((p) => p == ReminderService.nudgePayload),
    ];

    for (final payload in ordered) {
      try {
        if (await _deliverOne(payload)) {
          delivered.add(payload);
        }
      } catch (_) {
        // One failed delivery must not cost the others. The failed one stays
        // owed: the record is cleared by the caller only for what was
        // delivered.
      }
    }

    return delivered;
  }

  /// Delivers one owed payload, and says whether it was delivered.
  ///
  /// The distinction matters because [handleFire] returns the **slot**, and
  /// a null slot means two different things: the nudge was handled (and the
  /// nudge does not have a slot), and the delivery was refused (there was no
  /// configuration, or the slot had been switched off). Only the first is a
  /// delivery.
  ///
  /// A refused delivery stays owed. That is the right answer: the student
  /// switched the slot off, so the digest is not wanted — but the *record*
  /// must not be cleared on a refusal, because the refusal may be a
  /// configuration that had not loaded yet, and a reminder that is silently
  /// dropped is the failure this whole path exists to prevent.
  Future<bool> _deliverOne(String payload) async {
    if (payload == ReminderService.nudgePayload) {
      await _handleNudge();
      return true;
    }

    final slot = ReminderService.slotFor(payload);
    if (slot == null) return false;

    // The configuration and the slot's activity decide whether the digest is
    // posted. Both are checked here rather than inside [handleFire], so the
    // refusal is visible.
    final config = this.config;
    if (config == null) return false;
    if (!config.isSlotActive(slot)) return false;

    await handleFire(payload);
    return true;
  }

  /// Handles a fired nudge: read the week, post if something is unbooked, and
  /// arm the next check.
  ///
  /// The check arming happens **after** the delivery, and it happens even
  /// when the delivery was silent — because a silent check means the week is
  /// booked, and the next check will be silent too, which is the point.
  Future<void> _handleNudge() async {
    final config = this.config;
    final clock = this.clock;
    if (config == null || clock == null) return;
    if (!config.nextWeekNudgeEnabled) return;

    final read = readReservations;
    if (read == null) return;

    final accountNames = <AccountId, String>{
      for (final account in accounts) account.id: account.resolvedName,
    };

    // Read every selected account. A failure is not fatal: the nudge names
    // the accounts it could not check, so a partial answer still tells the
    // user something true.
    //
    // The read is **bounded**. A network read in Doze is blocked, and it
    // does not fail — it hangs, because the socket waits for the system to
    // open a maintenance window. An unbounded read would therefore hold the
    // delivery hostage: the student would open the app and nothing would
    // happen until Android decided to let the request through, minutes or
    // hours later. So the read is given a deadline, and a read that misses
    // it is reported as a failure — which the digest names, so the student
    // is told the check could not be made rather than being told nothing.
    final nextSat = nextWeekStart(clock.portalTodayUtc);
    if (config.isNudgeDismissedForWeek(nextSat)) {
      // User dismissed reservation reminder for this week!
      await service.armNudge(config, clock);
      return;
    }

    final targetAccounts = config.activeNudgeAccounts;
    if (targetAccounts.isEmpty) {
      await service.armNudge(config, clock);
      return;
    }

    final reservations = <AccountId, List<Reservation>>{};
    final failuresByAccount = <AccountId, ReminderFailure>{};
    await Future.wait(
      targetAccounts.map((accountId) async {
        try {
          final res = await read(accountId).timeout(readTimeout);
          reservations[accountId] = res;
        } catch (_) {
          failuresByAccount[accountId] = ReminderFailure(
            accountId: accountId,
            displayName: accountNames[accountId] ?? accountId,
            cause: ReminderFailureCause.readFailed,
          );
        }
      }),
    );
    final failures = [
      for (final accountId in targetAccounts)
        if (failuresByAccount.containsKey(accountId))
          failuresByAccount[accountId]!,
    ];

    final status = detectNextWeekGaps(
      weekStart: nextWeekStart(clock.portalTodayUtc),
      reservationsByAccount: reservations,
      clock: clock,
      failures: failures,
    );

    await service.deliverNudge(
      config: config,
      accountNames: accountNames,
      reservationsByAccount: reservations,
      status: status,
    );

    // Arm the next check, whether or not this one had anything to say.
    await service.armNudge(config, clock);
  }
}
