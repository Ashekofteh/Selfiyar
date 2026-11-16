/// The reminder part of the app's state: the notification configuration and
/// the account toggles derived from it.
///
/// The configuration is owned here; the platform owns the alarms. A change
/// notifies both the screens and [onReminderConfigChanged], so the two can
/// never drift apart.
library;

import 'package:flutter/foundation.dart';

import '../../core/auth/account_store.dart';
import '../../core/meal/models.dart';
import '../../core/reminder/reminder.dart';

/// Reminder configuration and account selection.
class RemindersState extends ChangeNotifier {
  RemindersState({required this.configStore});

  /// Where the reminder configuration is persisted.
  final ReminderConfigStore configStore;

  ReminderConfig _reminderConfig = const ReminderConfig();

  /// The current reminder configuration.
  ReminderConfig get config => _reminderConfig;

  /// Loads the persisted configuration. Does not notify: the caller is
  /// typically the composition root's `load()`, which notifies once at the
  /// end.
  Future<void> load() async {
    _reminderConfig = await configStore.load();
  }

  /// Called after the reminder configuration changes, so the alarms can be
  /// re-armed.
  ///
  /// The state owns the configuration; the platform owns the alarms. The
  /// platform layer sets this.
  void Function(ReminderConfig config)? onReminderConfigChanged;

  /// Saves the reminder configuration.
  Future<void> save(ReminderConfig config) async {
    _reminderConfig = config;
    await configStore.save(config);
    // The alarms are derived from the configuration, so a change has to
    // re-arm them. A slot the user switched off must stop firing, and a slot
    // they switched on must start: the alarm and the setting the user sees
    // are the same thing, and they must not drift apart.
    onReminderConfigChanged?.call(config);
    notifyListeners();
  }

  /// Toggles an account's participation in the reminders.
  Future<void> toggleAccount(AccountId accountId) async {
    final next = Set<AccountId>.from(_reminderConfig.accountIds);
    if (!next.remove(accountId)) next.add(accountId);
    await save(_reminderConfig.copyWith(accountIds: next));
  }

  /// Toggles an account's participation in the weekend reservation nudge.
  Future<void> toggleNudgeAccount(AccountId accountId) async {
    final current =
        _reminderConfig.nudgeAccountIds ?? _reminderConfig.accountIds;
    final next = Set<AccountId>.from(current);
    if (!next.remove(accountId)) next.add(accountId);
    await save(_reminderConfig.copyWith(nudgeAccountIds: next));
  }

  /// Sets or clears dismissal of the next-week reservation reminder for a
  /// specific week.
  Future<void> setNudgeWeekDismissal(DateTime? weekSaturday) async {
    await save(
      _reminderConfig.copyWith(
        dismissedNudgeWeekSaturday: weekSaturday,
        clearDismissedNudge: weekSaturday == null,
      ),
    );
  }
}
