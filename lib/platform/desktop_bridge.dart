/// Desktop platform bridge for Windows, macOS, and Linux.
///
/// Replaces Android-specific method channels (Keystore, SharedPreferences,
/// AlarmManager, ForegroundService) with pure Dart file-based storage and
/// in-process timers.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/models.dart';
import '../core/platform_stores.dart';
import 'desktop_stores.dart';
import 'platform_bridge.dart';

/// Desktop implementation of [PlatformBridge].
class DesktopPlatformBridge extends PlatformBridge {
  DesktopPlatformBridge({Directory? storageDirectory})
      : _plainStore = FilePlainStore(directory: storageDirectory),
        _secureStore = FileSecureStore(directory: storageDirectory);

  final PlainStore _plainStore;
  final SecureCredentialStore _secureStore;

  final Map<int, Timer> _scheduledAlarms = {};
  final Map<AccountId, Timer> _scheduledHuntAlarms = {};

  void Function(String? payload)? _desktopHuntHandler;

  @override
  SecureCredentialStore get credentialStore => _secureStore;

  @override
  PlainStore get plainStore => _plainStore;

  @override
  Future<bool> hasNotificationPermission() async => true;

  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<bool> canScheduleExactAlarms() async => true;

  @override
  Future<bool> requestExactAlarmPermission() async => true;

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => true;

  @override
  Future<bool> requestIgnoreBatteryOptimizations() async => true;

  @override
  Future<void> postNotification({
    required int id,
    required String title,
    required String body,
    String? deepLink,
  }) async {
    // On desktop, notifications can be logged to stdout or handled by the system.
    // In-app visual feedback (SnackBar/Toasts) handles user-facing alerts.
  }

  @override
  Future<void> cancelNotification(int id) async {}

  @override
  Future<void> shareText({required String text, String? title}) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  @override
  Future<void> sendSms({required String text}) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  @override
  Future<void> openUrl(String url) async {
    try {
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', url]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [url]);
      } else {
        await Clipboard.setData(ClipboardData(text: url));
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: url));
    }
  }

  @override
  Future<void> scheduleAlarm({
    required int requestCode,
    required DateTime triggerAt,
    String? payload,
  }) async {
    _scheduledAlarms[requestCode]?.cancel();
    final delay = triggerAt.difference(DateTime.now());
    final effectiveDelay = delay.isNegative ? Duration.zero : delay;

    _scheduledAlarms[requestCode] = Timer(effectiveDelay, () {
      _desktopHuntHandler?.call(payload);
      _scheduledAlarms.remove(requestCode);
    });
  }

  @override
  Future<void> cancelAlarm(int requestCode) async {
    _scheduledAlarms.remove(requestCode)?.cancel();
  }

  @override
  Future<void> scheduleHuntAlarm({
    required AccountId accountId,
    required DateTime triggerAt,
  }) async {
    _scheduledHuntAlarms[accountId]?.cancel();
    final delay = triggerAt.difference(DateTime.now());
    final effectiveDelay = delay.isNegative ? Duration.zero : delay;

    _scheduledHuntAlarms[accountId] = Timer(effectiveDelay, () {
      _desktopHuntHandler?.call(accountId);
      _scheduledHuntAlarms.remove(accountId);
    });
  }

  @override
  Future<void> cancelHuntAlarm(AccountId accountId) async {
    _scheduledHuntAlarms.remove(accountId)?.cancel();
  }

  @override
  Future<List<String>> pendingDeliveries() async => const [];

  @override
  Future<void> clearPendingDeliveries(List<String> payloads) async {}

  @override
  Future<List<String>> pendingRequests() async => const [];

  @override
  Future<void> clearPendingRequests(List<String> entries) async {}

  @override
  Future<void> startHuntService({String? payload}) async {}

  @override
  Future<void> stopHuntService() async {}

  @override
  Future<String?> getInitialDeepLink() async => null;

  @override
  void onHuntRequested(void Function(String? payload) handler) {
    _desktopHuntHandler = handler;
  }

  @override
  void onPermissionChanged(void Function() handler) {
  }

  /// Cancels all pending timers when the desktop bridge is disposed.
  void dispose() {
    for (final timer in _scheduledAlarms.values) {
      timer.cancel();
    }
    _scheduledAlarms.clear();

    for (final timer in _scheduledHuntAlarms.values) {
      timer.cancel();
    }
    _scheduledHuntAlarms.clear();
  }
}
