/// The hunt's platform service: runs the hunt, posts the outcome, and keeps
/// the foreground service alive for exactly as long as the hunt lasts.
///
/// ## Why the service is released promptly
///
/// A foreground service is a user-visible notification and a battery drain. The
/// spec is explicit that it is released the moment the window closes or a
/// purchase lands, so every exit path here calls [PlatformBridge
/// .stopHuntService] — including the failure paths, because a service that
/// lingers after a refused hunt is the worst of both.
///
/// ## The notification is not optimistic
///
/// The success notification is posted **after the outcome is known**, never
/// when the claim is sent. A basket purchase is irreversible, so an ambiguous
/// claim may not have been a purchase at all — and a notification that says
/// "bought" when nothing was bought sends the student looking for a meal they
/// do not have.
library;

import 'dart:async';

import '../core/hunt/hunt_config.dart';
import '../core/hunt/hunt_notify.dart';
import '../core/hunt/hunt_store.dart';
import '../core/meal/local_meal_store.dart';
import '../core/meal/meal_invariant.dart' show MealSource;
import '../core/meal/models.dart';
import '../core/hunt/snipe.dart';
import '../core/hunt/snipe_engine.dart';
import 'platform_bridge.dart';

/// Runs hunts and reports their outcome.
class HuntService {
  HuntService({
    required this.bridge,
    required this.engine,
    this.configStore,
    this.mealStore,
    this.successStore,
    this.onOutcome,
    this.onPersistMealStore,
  });

  final PlatformBridge bridge;
  final SnipeEngine engine;
  final HuntConfigStore? configStore;
  final LocalMealStore? mealStore;
  final HuntSuccessStore? successStore;
  final Future<void> Function(AccountId accountId, bool success)? onOutcome;
  final Future<void> Function()? onPersistMealStore;

  /// The active hunts tracked by account id for reliable multi-account cleanup.
  final Set<AccountId> _activeHunts = {};

  /// Whether a hunt is currently running for [accountId].
  bool isHunting(AccountId accountId) => _activeHunts.contains(accountId);

  /// The default notification id of the hunt outcome.
  static const int _outcomeNotificationId = 4150;

  /// Generates a distinct notification id per account so concurrent accounts
  /// do not overwrite each other's outcome notifications.
  static int outcomeNotificationId(AccountId accountId) =>
      _outcomeNotificationId + (accountId.hashCode.abs() % 1000);

  /// Starts a hunt for [accountId].
  ///
  /// The foreground service is started first, because the system kills an app
  /// that calls `startForegroundService` without posting its notification
  /// promptly.
  ///
  /// ## A switched-off hunt does not start
  ///
  /// The flag is checked **here**, not only in the screen, because the UI is
  /// not the only thing that can start a hunt: the platform can ask for one at
  /// a moment when the student is not looking at the screen. A hunt spends
  /// money, so "off" has to mean off on every path — not just the one the
  /// student touched.
  ///
  /// The check is before the service is started, so a refused hunt leaves no
  /// foreground notification behind claiming the basket is being watched.
  Future<void> start({
    required AccountId accountId,
    required HuntConfig config,
  }) async {
    if (!config.enabled) return;

    _activeHunts.add(accountId);
    await bridge.startHuntService(payload: accountId);

    final rule = config.toRule(id: _ruleId(accountId), account: accountId);
    await engine.start(rule, hunt: config);
  }

  /// Stops a running hunt and releases the foreground service.
  Future<void> stop(AccountId accountId) async {
    _activeHunts.remove(accountId);
    await engine.stop(_ruleId(accountId));
    await _releaseService(accountId);
    try {
      await bridge.cancelHuntAlarm(accountId);
    } catch (_) {}
    if (configStore != null) {
      try {
        final current = await configStore!.load(accountId);
        if (current != null && current.enabled) {
          await configStore!.save(accountId, current.copyWith(enabled: false));
        }
      } catch (_) {}
    }
  }

  /// The rule id a hunt runs under.
  static String _ruleId(AccountId accountId) => 'hunt-$accountId';

  /// Posts the outcome of a hunt and releases the service.
  ///
  /// Called by the engine's outcome listener. The service is released here
  /// rather than by the caller, so it happens on every path — a purchase, a
  /// refusal, a closed window — without the caller having to remember.
  Future<void> reportOutcome({
    required AccountId accountId,
    required HuntNotification notification,
    String? deepLink,
    bool isSuccess = false,
  }) async {
    _activeHunts.remove(accountId);
    await bridge.postNotification(
      id: outcomeNotificationId(accountId),
      title: notification.title,
      body: notification.body,
      deepLink: deepLink ?? 'reservations://$accountId',
    );
    await _releaseService(accountId);

    // The hunt MUST stop and be disabled after successful or unsuccessful hunt
    try {
      await bridge.cancelHuntAlarm(accountId);
    } catch (_) {}

    if (configStore != null) {
      try {
        final current = await configStore!.load(accountId);
        if (current != null && current.enabled) {
          await configStore!.save(accountId, current.copyWith(enabled: false));
        }
      } catch (_) {}
    }

    if (onOutcome != null) {
      try {
        await onOutcome!(accountId, isSuccess);
      } catch (_) {}
    }
  }

  /// Releases the foreground service, swallowing a platform failure.
  ///
  /// If [accountId] is provided, releases only that account's claim on the
  /// service so other running accounts keep running undisturbed.
  Future<void> _releaseService([AccountId? accountId]) async {
    try {
      await bridge.stopHuntService(accountId: accountId);
    } catch (_) {
      // The service releases itself when the process ends anyway.
    }
  }
}

/// The engine's outcome listener for a hunt.
///
/// Posts the success notification when a meal was bought, and the "ended
/// without a purchase" notification when the hunt stopped for any other
/// reason.
class HuntNotifier implements HuntOutcomeListener {
  HuntNotifier({
    required this.service,
    required this.accountId,
    this.configStore,
    this.mealStore,
    this.successStore,
    this.onPersistMealStore,
    this.onClaimedCallback,
    this.onEndedCallback,
  });

  final HuntService service;
  final AccountId accountId;
  final HuntConfigStore? configStore;
  final LocalMealStore? mealStore;
  final HuntSuccessStore? successStore;
  final Future<void> Function()? onPersistMealStore;
  final Future<void> Function(Listing listing, Reservation reservation)?
  onClaimedCallback;
  final Future<void> Function(SnipeState state, String reason)? onEndedCallback;

  @override
  Future<void> onClaimed({
    required String ruleId,
    required Listing listing,
    required Reservation reservation,
  }) async {
    final meals = mealStore ?? service.mealStore;
    if (meals != null) {
      try {
        meals.put(
          StoredMeal(
            accountId: accountId,
            date: listing.date,
            slot: listing.slot,
            source: MealSource.basketPurchase,
            capturedAt: DateTime.now().toUtc(),
            optionId: listing.option.id,
            dishName: listing.option.name,
            hallName: listing.hall.name,
            priceRial: listing.option.priceRial,
          ),
        );
      } catch (_) {}
      try {
        final persist = onPersistMealStore ?? service.onPersistMealStore;
        if (persist != null) {
          await persist();
        }
      } catch (_) {}
    }

    final successes = successStore ?? service.successStore;
    if (successes != null) {
      try {
        await successes.save(
          HuntSuccess(
            accountId: accountId,
            dishName: listing.option.name,
            hallName: listing.hall.name,
            priceRial: listing.option.priceRial,
            date: listing.date,
            slot: listing.slot,
            claimedAt: DateTime.now().toUtc(),
          ),
        );
      } catch (_) {}
    }

    final notification = composeHuntSuccess(
      slot: listing.slot,
      date: listing.date,
      dishName: listing.option.name,
      hallName: listing.hall.name,
      priceRial: listing.option.priceRial,
    );

    final deepLink = Uri(
      scheme: 'nut',
      host: 'hunt-success',
      queryParameters: {
        'account': accountId,
        'dish': listing.option.name,
        'hall': listing.hall.name,
        'price': listing.option.priceRial.toString(),
        'date': listing.date.toIso8601String(),
        'slot': listing.slot.name,
      },
    ).toString();

    final store = configStore ?? service.configStore;
    if (store != null) {
      try {
        final current = await store.load(accountId);
        if (current != null && current.enabled) {
          await store.save(accountId, current.copyWith(enabled: false));
        }
      } catch (_) {}
    }

    if (onClaimedCallback != null) {
      try {
        await onClaimedCallback!(listing, reservation);
      } catch (_) {}
    }

    await service.reportOutcome(
      accountId: accountId,
      notification: notification,
      deepLink: deepLink,
      isSuccess: true,
    );
  }

  @override
  Future<void> onEnded({
    required String ruleId,
    required SnipeState state,
    required String reason,
  }) async {
    // A dry run that matched is a *success* of the simulation, not a purchase,
    // so it says so rather than claiming a meal was bought.
    final notification = composeHuntEnded(
      reason: state == SnipeState.claimed
          ? 'این یک اجرای آزمایشی بود؛ چیزی خریداری نشد.'
          : reason,
    );

    final store = configStore ?? service.configStore;
    if (store != null) {
      try {
        final current = await store.load(accountId);
        if (current != null && current.enabled) {
          await store.save(accountId, current.copyWith(enabled: false));
        }
      } catch (_) {}
    }

    if (onEndedCallback != null) {
      try {
        await onEndedCallback!(state, reason);
      } catch (_) {}
    }

    await service.reportOutcome(
      accountId: accountId,
      notification: notification,
      isSuccess: false,
    );
  }
}
