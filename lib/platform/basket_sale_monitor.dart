import 'dart:async';
import 'package:flutter/foundation.dart';
import '../core/models.dart';
import '../core/persian.dart';
import '../core/time.dart';
import '../ui/app_state.dart';
import 'platform_bridge.dart';
import 'portal_sync.dart';

/// Periodically monitors active Food Basket listings in the background.
///
/// Designed to consume ZERO battery when no meals are listed for sale:
/// the timer and platform alarm are only armed when [state.basketSales] is non-empty,
/// and are completely cancelled the moment all listed meals are sold or expired.
class BasketSaleMonitor {
  BasketSaleMonitor({
    required this.bridge,
    required this.state,
    required this.sync,
    this.clock,
    this.interval = const Duration(minutes: 15),
    this.onSold,
  });

  final PlatformBridge bridge;
  final AppState state;
  final PortalSync sync;
  final ServerClock? clock;
  final Duration interval;

  /// Optional callback invoked when a meal sale is detected, primarily for in-app UI updates.
  final void Function(String dishName, int priceRial)? onSold;

  Timer? _periodicTimer;
  bool _isChecking = false;

  static const int alarmRequestCode = 4250;
  static const int notificationId = 4150;
  static const String payload = 'basket_sale_check';
  static const String deepLink = 'transactions';

  bool get isActive => _periodicTimer != null;

  /// Starts or re-arms the periodic check if there are active basket sales.
  /// If [state.basketSales] is empty, stops monitoring completely.
  Future<void> startOrUpdate() async {
    _pruneExpiredSales();

    if (state.basketSales.isEmpty) {
      await stop();
      return;
    }

    if (_periodicTimer == null || !_periodicTimer!.isActive) {
      _periodicTimer = Timer.periodic(interval, (_) => checkNow());
    }

    final triggerAt =
        (clock?.isSynced == true ? clock!.portalNow : DateTime.now())
            .add(interval);
    try {
      await bridge.scheduleAlarm(
        requestCode: alarmRequestCode,
        triggerAt: triggerAt,
        payload: payload,
      );
    } catch (e) {
      debugPrint('BasketSaleMonitor: failed to schedule alarm: $e');
    }
  }

  /// Cancels both the in-process timer and the platform alarm.
  Future<void> stop() async {
    _periodicTimer?.cancel();
    _periodicTimer = null;
    try {
      await bridge.cancelAlarm(alarmRequestCode);
    } catch (e) {
      debugPrint('BasketSaleMonitor: failed to cancel alarm: $e');
    }
  }

  /// Removes sales whose distribution cutoff has passed, without making network calls.
  void _pruneExpiredSales() {
    final keys = List<String>.from(state.basketSales);
    for (final key in keys) {
      final parts = key.split('|');
      if (parts.length != 3) {
        state.unmarkListedInBasketByKey(key);
        continue;
      }
      final accId = parts[0];
      final dateParts = parts[1].split('-').map(int.parse).toList();
      final date = DateTime.utc(dateParts[0], dateParts[1], dateParts[2]);
      final slot = MealSlot.values.byName(parts[2]);

      if (isMealDistributionPassed(date, slot, clock: clock)) {
        state.unmarkListedInBasket(accId, date, slot);
      }
    }
  }

  /// Runs an active check against the university portal for all accounts with listed meals.
  Future<void> checkNow() async {
    if (_isChecking) return;
    _isChecking = true;

    try {
      _pruneExpiredSales();

      if (state.basketSales.isEmpty) {
        await stop();
        return;
      }

      // Collect accounts that have active basket sales.
      final accountIds = <AccountId>{};
      for (final key in state.basketSales) {
        final parts = key.split('|');
        if (parts.isNotEmpty) accountIds.add(parts[0]);
      }

      final activeAccounts = accountIds
          .where((accId) => state.accounts.any((a) => a.id == accId))
          .toList();

      await Future.wait(
        activeAccounts.map((accId) async {
          try {
            await sync.sync(accId);
          } catch (e) {
            debugPrint('BasketSaleMonitor: sync failed for $accId: $e');
          }
        }),
      );

      // After sync, state.mealsChanged() pruned sold meals and triggered onBasketMealSold.
      // Re-evaluate if any sales remain.
      if (state.basketSales.isEmpty) {
        await stop();
      } else {
        // Re-arm next alarm cycle
        final triggerAt =
            (clock?.isSynced == true ? clock!.portalNow : DateTime.now())
                .add(interval);
        await bridge.scheduleAlarm(
          requestCode: alarmRequestCode,
          triggerAt: triggerAt,
          payload: payload,
        );
      }
    } catch (e) {
      debugPrint('BasketSaleMonitor.checkNow failed: $e');
    } finally {
      _isChecking = false;
    }
  }

  /// Posts the notification when a meal is sold.
  Future<void> notifySold({
    required String dishName,
    required int priceRial,
  }) async {
    final priceText = formatTomanPersian(priceRial);
    final body =
        'غذای «$dishName» در سبد به فروش رسید و مبلغ $priceText به اعتبارتان بازگشت.';
    await bridge.postNotification(
      id: notificationId,
      title: 'فروش موفق در سبد غذا 🎉',
      body: body,
      deepLink: deepLink,
    );
    onSold?.call(dishName, priceRial);
  }
}
