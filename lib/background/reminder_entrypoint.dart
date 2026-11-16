/// The headless reminder sync: refreshing the offline store for a reminder
/// that fires while the app is closed.
///
/// ## Why this file exists
///
/// The reminder digest is built from `meals.held`, which is normally kept up
/// to date by the app's own sync. When the app has not been opened for a day,
/// that mirror can be stale. The live portal check is an opt-in setting, and
/// when it is on the reminder must refresh the mirror before it speaks.
///
/// With the app closed there is no Dart side to run that refresh, so the alarm
/// receiver starts a short-lived Flutter engine that runs this entrypoint. It
/// reads the same store the app writes, refreshes the selected accounts, and
/// reports back. The native side then composes the notification.
///
/// ## It never posts the reminder itself
///
/// The native delivery path owns the notification, the re-arm and the pending
/// delivery record. This entrypoint only refreshes the store. If the network
/// is unavailable, the login fails, or the whole refresh exceeds the budget,
/// it reports finished anyway — the native side then delivers from the
/// existing offline mirror. A reminder is never silently dropped.
///
/// ## Why it is its own entrypoint
///
/// The app's `main` builds a widget tree. A background refresh has no screen
/// and must finish in seconds, so it runs the smallest possible Dart program:
/// services, a handful of reads, a write, and done.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/meal/local_meal_store.dart';
import '../core/meal/meal_invariant.dart';
import '../core/meal/models.dart';
import '../platform/platform_services.dart';

/// How long the refresh may take before the native timeout takes over.
///
/// The native side allows fifteen seconds. Twelve leaves room to persist the
/// store and report back before the engine is destroyed.
const Duration reminderSyncBudget = Duration(seconds: 12);

/// The function the native engine calls. It takes no arguments.
@pragma('vm:entry-point')
void main(List<String> args) {
  // The bindings must exist before the method channel is usable. There is
  // deliberately no `runApp`: this entrypoint has no screen.
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(runHeadlessReminderSync());
}

/// Refreshes the offline meal store for the reminder configuration.
///
/// Always reports finished, even when every read failed. The caller falls
/// back to the store it already has.
Future<void> runHeadlessReminderSync({
  Duration budget = reminderSyncBudget,
}) async {
  final services = AppServices.forAndroid();
  try {
    await _refreshHeldMeals(services).timeout(budget);
  } catch (_) {
    // Offline, login failure, or the budget expired. The native side reads
    // the store as it is and delivers the reminder anyway.
  } finally {
    try {
      await services.bridge.notifyReminderSyncFinished();
    } catch (_) {
      // The native timeout is the backstop; an announcement failure is not
      // worth taking the process down for.
    }
    services.dispose();
  }
}

/// Reads the selected accounts' reservations into `meals.held`.
///
/// Only the live accounts are touched, and a failure for one account does not
/// cost the others. Basket purchases that are already in the mirror are
/// preserved: they do not appear in the weekly reservation grid, so replacing
/// an account wholesale with the grid would silently lose them.
Future<void> _refreshHeldMeals(AppServices services) async {
  final config = await services.reminderConfigStore.load();
  if (!config.liveCheckEnabled) return;

  // The engine starts with an empty in-memory store. Reading the disk copy
  // first is what makes this refresh a *reconciliation* rather than a
  // replacement: without it, persisting the refreshed accounts would wipe
  // every other account's mirror — and the basket purchases of the refreshed
  // accounts, which are not in the weekly reservation grid.
  await services.mealStore.restore();

  final selected = <AccountId>{
    ...config.accountIds,
    ...config.activeNudgeAccounts,
  };
  if (selected.isEmpty) return;

  var updated = false;
  for (final accountId in selected) {
    try {
      final reservations = await services.sessions.withSession(
        accountId,
        (session) => services.client.fetchReservations(session),
      );

      final capturedAt = DateTime.now().toUtc();
      final existingBasketMeals = services.mealStore.store
          .forAccount(accountId)
          .where((meal) => meal.source == MealSource.basketPurchase);

      final refreshed = <StoredMeal>[
        for (final reservation in reservations)
          StoredMeal(
            accountId: accountId,
            date: reservation.date,
            slot: reservation.slot,
            source: MealSource.weeklyReservation,
            capturedAt: capturedAt,
            optionId: reservation.option.id,
            dishName: reservation.option.name,
            hallName: reservation.hall.name,
            priceRial: reservation.option.priceRial,
            isConsumed: reservation.state == ReservationState.consumed,
          ),
        ...existingBasketMeals,
      ];

      services.mealStore.store.replaceForAccount(accountId, refreshed);
      updated = true;
    } catch (_) {
      // One account's stale mirror must not stop the others from refreshing.
    }
  }

  if (updated) {
    services.mealStore.store.prune(DateTime.now().toUtc());
    await services.mealStore.persist();
  }
}
