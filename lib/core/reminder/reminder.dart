/// Reminder configuration and the digest that a reminder reports.
///
/// Pure Dart: no clock, no I/O, no Flutter, so the whole digest pipeline is
/// testable on the VM.
library;

import '../meal/models.dart';
import '../shared/time.dart';

/// The two daily reminder slots.
///
/// [evening] covers dinner *and* tomorrow's breakfast because they are collected
/// together — losing one means losing both.
enum ReminderSlot { lunch, evening }

/// One configurable reminder slot.
class ReminderSlotConfig {
  const ReminderSlotConfig({
    required this.slot,
    required this.time,
    this.enabled = true,
    required this.covers,
  });

  final ReminderSlot slot;

  /// Fire time, in **portal-local** time (UTC+3:30), not device-local.
  ///
  /// A user travelling abroad would otherwise set 10:30, get device-local
  /// behaviour, and silently miss every reminder.
  final ClockTime time;

  final bool enabled;

  /// Which meals this slot reports on.
  final Set<MealSlot> covers;

  static const lunchDefault = ReminderSlotConfig(
    slot: ReminderSlot.lunch,
    time: ClockTime(10, 30),
    covers: {MealSlot.lunch},
  );

  static const eveningDefault = ReminderSlotConfig(
    slot: ReminderSlot.evening,
    time: ClockTime(16, 30),
    covers: {MealSlot.dinner, MealSlot.breakfast},
  );

  ReminderSlotConfig copyWith({ClockTime? time, bool? enabled}) =>
      ReminderSlotConfig(
        slot: slot,
        time: time ?? this.time,
        enabled: enabled ?? this.enabled,
        covers: covers,
      );
}

/// All reminder configuration.
class ReminderConfig {
  const ReminderConfig({
    this.masterEnabled = true,
    this.accountIds = const {},
    this.lunch = ReminderSlotConfig.lunchDefault,
    this.evening = ReminderSlotConfig.eveningDefault,
    this.nextWeekNudgeEnabled = true,
    this.liveCheckEnabled = false,
    this.excludedFromSlot = const {},
    this.nudgeAccountIds,
    this.dismissedNudgeWeekSaturday,
  });

  /// Global switch. Off means no alarms at all are scheduled.
  final bool masterEnabled;

  /// Accounts included in reminders.
  final Set<AccountId> accountIds;

  final ReminderSlotConfig lunch;
  final ReminderSlotConfig evening;

  /// Independently toggled: a user may want daily reminders but not the nudge.
  final bool nextWeekNudgeEnabled;

  /// Independently toggled: re-check the portal online before delivering a digest.
  final bool liveCheckEnabled;

  /// Accounts excluded from one specific slot, so a user can receive the evening
  /// digest for an account without also receiving the morning one.
  final Map<ReminderSlot, Set<AccountId>> excludedFromSlot;

  /// Accounts included in the weekend reservation reminder (nudge).
  /// If null, defaults to [accountIds].
  final Set<AccountId>? nudgeAccountIds;

  /// The Saturday start date of the week for which the next-week reservation reminder
  /// was manually dismissed by the student for this week only.
  final DateTime? dismissedNudgeWeekSaturday;

  /// The active accounts for the next-week nudge.
  Set<AccountId> get activeNudgeAccounts => nudgeAccountIds ?? accountIds;

  /// True when the nudge for [targetSaturday] was dismissed for that specific week.
  bool isNudgeDismissedForWeek(DateTime targetSaturday) {
    final d = dismissedNudgeWeekSaturday;
    if (d == null) return false;
    return d.year == targetSaturday.year &&
        d.month == targetSaturday.month &&
        d.day == targetSaturday.day;
  }

  /// Accounts that should receive [slot], after exclusions.
  Set<AccountId> accountsFor(ReminderSlot slot) =>
      accountIds.difference(excludedFromSlot[slot] ?? const {});

  /// True when [slot] should fire at all.
  bool isSlotActive(ReminderSlot slot) {
    if (!masterEnabled) return false;
    final config = slot == ReminderSlot.lunch ? lunch : evening;
    return config.enabled && accountsFor(slot).isNotEmpty;
  }

  /// A copy with the given fields changed.
  ///
  /// Every mutation goes through this rather than rebuilding the config by hand.
  /// Rebuilding it field-by-field is how a change silently drops a setting — and
  /// the dropped setting here was the **master switch**, which would silently
  /// turn every reminder back on. A copy method makes that class of mistake
  /// impossible.
  ReminderConfig copyWith({
    bool? masterEnabled,
    Set<AccountId>? accountIds,
    ReminderSlotConfig? lunch,
    ReminderSlotConfig? evening,
    bool? nextWeekNudgeEnabled,
    bool? liveCheckEnabled,
    Map<ReminderSlot, Set<AccountId>>? excludedFromSlot,
    Set<AccountId>? nudgeAccountIds,
    DateTime? dismissedNudgeWeekSaturday,
    bool clearDismissedNudge = false,
  }) => ReminderConfig(
    masterEnabled: masterEnabled ?? this.masterEnabled,
    accountIds: accountIds ?? this.accountIds,
    lunch: lunch ?? this.lunch,
    evening: evening ?? this.evening,
    nextWeekNudgeEnabled: nextWeekNudgeEnabled ?? this.nextWeekNudgeEnabled,
    liveCheckEnabled: liveCheckEnabled ?? this.liveCheckEnabled,
    excludedFromSlot: excludedFromSlot ?? this.excludedFromSlot,
    nudgeAccountIds: nudgeAccountIds ?? this.nudgeAccountIds,
    dismissedNudgeWeekSaturday: clearDismissedNudge
        ? null
        : (dismissedNudgeWeekSaturday ?? this.dismissedNudgeWeekSaturday),
  );
}

/// A reserved meal, as it will be reported.
class ReservedMealItem {
  const ReservedMealItem({
    required this.date,
    required this.slot,
    required this.hallName,
    required this.dishName,
    required this.priceRial,
  });

  final DateTime date;
  final MealSlot slot;
  final String hallName;
  final String dishName;
  final int priceRial;
}

/// One account's reserved meals.
class AccountDigest {
  const AccountDigest({
    required this.accountId,
    required this.displayName,
    this.items = const [],
  });

  final AccountId accountId;
  final String displayName;
  final List<ReservedMealItem> items;

  bool get hasItems => items.isNotEmpty;
}

/// An account that could not be checked.
///
/// Carried through the whole pipeline so it can be **named in the message**.
/// Silently omitting an account would produce a briefing that looks complete and
/// is not — the one outcome this subsystem must never ship.
class ReminderFailure {
  const ReminderFailure({
    required this.accountId,
    required this.displayName,
    required this.cause,
  });

  final AccountId accountId;
  final String displayName;
  final ReminderFailureCause cause;
}

enum ReminderFailureCause {
  /// Could not authenticate: bad credentials, or the CAPTCHA solve declined.
  authFailed,

  /// Authenticated, but the read failed (network, portal error).
  readFailed,

  /// Session was stale and could not be refreshed without user action.
  sessionExpired,
}

/// Everything one reminder needs to say.
class ReminderDigest {
  const ReminderDigest({
    required this.slot,
    required this.generatedAt,
    required this.accounts,
    this.failures = const [],
  });

  final ReminderSlot slot;
  final DateTime generatedAt;

  /// Accounts that were checked successfully. May hold zero reserved meals.
  final List<AccountDigest> accounts;

  /// Accounts that could **not** be checked.
  final List<ReminderFailure> failures;

  /// True when no account holds anything in any covered slot.
  bool get nothingReserved => accounts.every((a) => !a.hasItems);

  /// Reserved items for one meal slot, paired with the accounts holding them.
  ///
  /// Returns only accounts that hold the slot, in the order given.
  List<(AccountDigest, ReservedMealItem)> itemsForSlot(MealSlot slot) {
    final out = <(AccountDigest, ReservedMealItem)>[];
    for (final account in accounts) {
      for (final item in account.items) {
        if (item.slot == slot) out.add((account, item));
      }
    }
    return out;
  }
}

/// Rendered notification content.
class NotificationText {
  const NotificationText({
    required this.title,
    required this.body,
    this.summary,
    this.multiAccountText,
  });

  final String title;
  final String body;

  /// Collapsed one-liner shown in the notification shade.
  final String? summary;

  /// Specific multi-account phrasing: `با اکانت X غذای Y را رزرو داری`
  final String? multiAccountText;

  @override
  String toString() => 'NotificationText($title | $body)';
}
