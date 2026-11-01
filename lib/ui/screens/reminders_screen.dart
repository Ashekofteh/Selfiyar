import 'package:flutter/material.dart';

import '../../core/account.dart';
import '../../core/next_week.dart';
import '../../core/persian.dart';
import '../../core/reminder.dart';
import '../../core/time.dart';
import '../../platform/platform_bridge.dart';
import '../app_state.dart';
import '../widgets.dart';

/// The reminders screen: when the app should speak up, and about which accounts.
///
/// The design follows the product owner's model:
///
///   * A **master switch** that turns the whole feature off. Off means no
///     alarms are scheduled at all, and the screen says so plainly rather than
///     leaving the sub-settings looking live.
///   * **Two slots** with configurable times — lunch, and the evening slot that
///     covers dinner and tomorrow's breakfast together (they are collected
///     together, so one reminder covers both).
///   * **Per-account selection**: which of the saved accounts the reminders
///     speak about.
///   * A **live portal check** as an opt-in, off by default. Off means the
///     reminders read the local store and never need to log in.
///   * The **permission card**, which states what the system is actually
///     allowing. A reminder whose alarm was never granted is a reminder that
///     silently never fires, and a screen that shows a working switch while
///     the switch does nothing is a lie.
class RemindersScreen extends StatelessWidget {
  const RemindersScreen({
    super.key,
    required this.state,
    this.bridge,
    this.onOpenReminderSlot,
  });

  final AppState state;

  /// The platform bridge, for the permission checks.
  ///
  /// Null in a test that does not exercise them; the card then says nothing
  /// about the platform rather than claiming a state it cannot know.
  final PlatformBridge? bridge;

  /// Callback to open the dedicated meal reminder screen for a slot.
  final void Function(ReminderSlot slot)? onOpenReminderSlot;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final config = state.reminderConfig;
        final accounts = state.accounts;

        return Scaffold(
          appBar: AppBar(title: const Text('یادآورها')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            children: [
              _MasterSwitchCard(state: state, config: config),
              const SizedBox(height: 12),
              if (bridge != null) ...[
                _PermissionCard(bridge: bridge!),
                const SizedBox(height: 12),
              ],
              _SlotCard(
                state: state,
                config: config,
                slot: ReminderSlot.lunch,
                title: 'یادآور ناهار',
                covers: 'وعده ناهار',
                onOpenSlot: onOpenReminderSlot == null
                    ? null
                    : () => onOpenReminderSlot!(ReminderSlot.lunch),
              ),
              const SizedBox(height: 12),
              _SlotCard(
                state: state,
                config: config,
                slot: ReminderSlot.evening,
                title: 'یادآور شام و صبحانه فردا',
                covers: 'وعده شام و صبحانه فردا (با هم تحویل می‌گیرند)',
                onOpenSlot: onOpenReminderSlot == null
                    ? null
                    : () => onOpenReminderSlot!(ReminderSlot.evening),
              ),
              const SizedBox(height: 12),
              _AccountsCard(state: state, config: config, accounts: accounts),
              const SizedBox(height: 12),
              _NudgeCard(state: state, config: config, accounts: accounts),
              const SizedBox(height: 12),
              _LiveSyncCard(
                enabled: config.liveCheckEnabled,
                onChanged: (value) => state.saveReminderConfig(
                  config.copyWith(liveCheckEnabled: value),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// What the system is currently allowing the reminders to do.
///
/// ## Why this card exists
///
/// A reminder needs two grants from the system, and both are refusals the
/// user can make without noticing:
///
///   * **The notification permission** (Android 13+). Without it the
///     reminders post nothing — silently, because `NotificationManager.notify`
///     does not throw.
///   * **The exact-alarm grant** (Android 12+). Without it the alarm still
///     fires, but inexact: a 10:30 reminder can arrive at 11:20, which is
///     after the cutoff it exists to protect.
///
/// Both are refusals the user has to make on purpose, and both happen on
/// screens the app does not own. So the app asks — here, where the switch
/// that depends on them is.
///
/// ## The Doze exemption
///
/// The third card is the battery-optimisation exemption, which is a **named
/// mitigation in the spec** ("Requested explicitly with rationale shown to
/// the user"). It is on this screen rather than asked for on launch, because
/// a permission the student has not earned is a prompt they dismiss, and a
/// dismissed prompt is indistinguishable from a silent refusal.
class _PermissionCard extends StatefulWidget {
  const _PermissionCard({required this.bridge});

  final PlatformBridge bridge;

  @override
  State<_PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<_PermissionCard> with WidgetsBindingObserver {
  bool? _notifications;
  bool? _exactAlarms;
  bool? _batteryExempt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // The platform announces the answer when the system dialog closes. The
    // request itself returns before the answer is known, so without this the
    // card would keep warning about a grant the student has already given.
    widget.bridge.onPermissionChanged(_read);

    _read();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Two of the three grants are given in the **system settings**, not in a
    // dialog: the exact-alarm grant and the battery exemption. The student
    // leaves the app to grant them and comes back, so the card re-reads on
    // the way back in.
    if (state == AppLifecycleState.resumed) _read();
  }

  /// Reads the three states from the platform.
  ///
  /// A read that fails leaves the state unknown, and the card then says
  /// nothing about it — an unknown is not a refusal, and telling the user
  /// their notifications are blocked when the app simply could not ask is
  /// worse than saying nothing.
  Future<void> _read() async {
    final bridge = widget.bridge;

    bool? notifications;
    bool? exactAlarms;
    bool? battery;

    try {
      notifications = await bridge.hasNotificationPermission();
    } catch (_) {
      notifications = null;
    }
    try {
      exactAlarms = await bridge.canScheduleExactAlarms();
    } catch (_) {
      exactAlarms = null;
    }
    try {
      battery = await bridge.isIgnoringBatteryOptimizations();
    } catch (_) {
      battery = null;
    }

    if (!mounted) return;
    setState(() {
      _notifications = notifications;
      _exactAlarms = exactAlarms;
      _batteryExempt = battery;
    });
  }

  @override
  Widget build(BuildContext context) {
    final notifications = _notifications;
    final exactAlarms = _exactAlarms;
    final battery = _batteryExempt;

    // Nothing is known yet, or everything is granted: no card.
    //
    // A card that lists three satisfied permissions is noise, and noise is how
    // a real warning stops being read.
    final allGranted = notifications != false &&
        exactAlarms != false &&
        battery != false;
    if (allGranted) return const SizedBox.shrink();

    return SectionCard(
      title: 'اجازه‌های لازم',
      subtitle: 'بدون این اجازه‌ها یادآورها به‌درستی کار نمی‌کنند.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (notifications == false)
            _PermissionRow(
              icon: Icons.notifications_off_outlined,
              title: 'ارسال اعلان‌ها',
              detail: 'بدون این اجازه، هیچ یادآوری نمایش داده نمی‌شود.',
              actionLabel: 'اجازه می‌دهم',
              onPressed: () => _requestNotifications(),
            ),
          if (exactAlarms == false)
            _PermissionRow(
              icon: Icons.alarm_off_outlined,
              title: 'زنگ دقیق',
              detail: 'بدون این اجازه، یادآور با تأخیر می‌رسد و ممکن است '
                  'از مهلت رزرو بگذرد.',
              actionLabel: 'اجازه می‌دهم',
              onPressed: () => _requestExactAlarms(),
            ),
          if (battery == false)
            _PermissionRow(
              icon: Icons.battery_saver_outlined,
              title: 'مستثنا شدن از بهینه‌سازی باتری',
              detail: 'در حالت خواب، دسترسی برنامه به اینترنت قطع می‌شود و '
                  'یادآورها با تأخیر زیاد می‌رسند.',
              actionLabel: 'اجازه می‌دهم',
              onPressed: () => _requestBattery(),
            ),
        ],
      ),
    );
  }

  Future<void> _requestNotifications() async {
    try {
      await widget.bridge.requestNotificationPermission();
    } catch (_) {
      // The system dialog owns the outcome; the re-read below finds it.
    }
    await _read();
  }

  Future<void> _requestExactAlarms() async {
    try {
      await widget.bridge.requestExactAlarmPermission();
    } catch (_) {
      // The settings screen owns the outcome.
    }
    await _read();
  }

  Future<void> _requestBattery() async {
    try {
      await widget.bridge.requestIgnoreBatteryOptimizations();
    } catch (_) {
      // The settings screen owns the outcome.
    }
    await _read();
  }
}

/// One missing permission, with the reason and the button that asks for it.
class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.actionLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String actionLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            detail,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: onPressed,
              icon: Icon(Icons.open_in_new, size: 18),
              label: Text(actionLabel),
            ),
          ),
        ],
      ),
    );
  }
}

/// The master switch.
class _MasterSwitchCard extends StatelessWidget {
  const _MasterSwitchCard({required this.state, required this.config});

  final AppState state;
  final ReminderConfig config;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'فعال‌سازی یادآورها',
      subtitle: config.masterEnabled
          ? 'یادآورها فعال‌اند و طبق برنامه زمانی زیر ارسال می‌شوند.'
          : 'همه یادآورها خاموش‌اند و هیچ اعلانی برنامه‌ریزی نشده است.',
      trailing: Switch(
        value: config.masterEnabled,
        onChanged: (value) =>
            state.saveReminderConfig(config.copyWith(masterEnabled: value)),
      ),
      child: const SizedBox.shrink(),
    );
  }
}

/// One reminder slot: on/off, its time, and what it covers.
class _SlotCard extends StatelessWidget {
  const _SlotCard({
    required this.state,
    required this.config,
    required this.slot,
    required this.title,
    required this.covers,
    this.onOpenSlot,
  });

  final AppState state;
  final ReminderConfig config;
  final ReminderSlot slot;
  final String title;
  final String covers;
  final VoidCallback? onOpenSlot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final slotConfig =
        slot == ReminderSlot.lunch ? config.lunch : config.evening;
    final enabled = config.masterEnabled && slotConfig.enabled;

    return SectionCard(
      title: title,
      subtitle: covers,
      trailing: Switch(
        value: slotConfig.enabled,
        onChanged: config.masterEnabled
            ? (value) => _saveSlot(slot, slotConfig.copyWith(enabled: value))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: config.masterEnabled
                ? () => _pickTime(context, slot, slotConfig.time)
                : null,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: enabled
                      ? theme.colorScheme.primary.withValues(alpha: 0.4)
                      : theme.colorScheme.outlineVariant,
                ),
                color: enabled
                    ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                    : null,
              ),
              child: Row(
                children: [
                  Icon(Icons.schedule,
                      size: 20,
                      color: enabled
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Text(
                    formatClockTimePersian(
                      slotConfig.time.hour,
                      slotConfig.time.minute,
                    ),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: enabled
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  if (enabled)
                    Text(
                      'برای تغییر ضربه بزنید',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _saveSlot(ReminderSlot slot, ReminderSlotConfig updated) {
    state.saveReminderConfig(config.copyWith(
      lunch: slot == ReminderSlot.lunch ? updated : config.lunch,
      evening: slot == ReminderSlot.evening ? updated : config.evening,
    ));
  }

  Future<void> _pickTime(
    BuildContext context,
    ReminderSlot slot,
    ClockTime current,
  ) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current.hour, minute: current.minute),
      helpText: 'زمان یادآور',
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        ),
      ),
    );
    if (picked == null) return;

    final updated = ClockTime(picked.hour, picked.minute);
    _saveSlot(
      slot,
      slot == ReminderSlot.lunch
          ? config.lunch.copyWith(time: updated)
          : config.evening.copyWith(time: updated),
    );
  }
}

/// Which accounts the reminders speak about.
class _AccountsCard extends StatelessWidget {
  const _AccountsCard({
    required this.state,
    required this.config,
    required this.accounts,
  });

  final AppState state;
  final ReminderConfig config;
  final List<dynamic> accounts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'حساب‌ها',
      subtitle: config.accountIds.isEmpty
          ? 'هیچ حسابی انتخاب نشده — تا وقتی حسابی انتخاب نکنید، یادآوری ارسال نمی‌شود.'
          : '${toPersianDigits(config.accountIds.length)} حساب انتخاب شده',
      child: accounts.isEmpty
          ? Text(
              'ابتدا یک حساب اضافه کنید.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : Column(
              children: [
                for (final account in accounts)
                  CheckboxListTile(
                    value: config.accountIds.contains(account.id),
                    onChanged: (_) => state.toggleReminderAccount(account.id),
                    title: Text(account.resolvedName),
                    subtitle: Text(account.studentId),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
              ],
            ),
    );
  }
}

/// The next-week nudge with per-account selection and single-week dismissal.
class _NudgeCard extends StatelessWidget {
  const _NudgeCard({
    required this.state,
    required this.config,
    required this.accounts,
  });

  final AppState state;
  final ReminderConfig config;
  final List<SavedAccount> accounts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nextSat = nextWeekStart(DateTime.now().toUtc());
    final isDismissed = config.isNudgeDismissedForWeek(nextSat);

    return SectionCard(
      title: 'یادآور رزرو هفته آینده',
      subtitle:
          'از چهارشنبه ظهر تا پنجشنبه عصر بررسی می‌شود که وعده‌های هفته آینده رزرو شده‌اند یا نه.',
      trailing: Switch(
        value: config.nextWeekNudgeEnabled,
        onChanged: (value) => state
            .saveReminderConfig(config.copyWith(nextWeekNudgeEnabled: value)),
      ),
      child: config.nextWeekNudgeEnabled
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (accounts.isNotEmpty) ...[
                  const Divider(height: 16),
                  Text(
                    'حساب‌های مشمول یادآور رزرو آخر هفته:',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final account in accounts)
                        FilterChip(
                          label: Text(account.resolvedName),
                          selected: config.activeNudgeAccounts.contains(account.id),
                          onSelected: (_) => state.toggleNudgeAccount(account.id),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 14),
                if (isDismissed) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.notifications_off_outlined,
                          size: 18,
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'یادآور رزرو برای این هفته لغو شده است (برای هفته‌های بعد فعال خواهد بود).',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSecondaryContainer,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => state.setNudgeWeekDismissal(null),
                          child: const Text('فعال‌سازی مجدد'),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  OutlinedButton.icon(
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('لغو یادآور رزرو این هفته'),
                          content: const Text(
                            'آیا می‌خواهید یادآور رزرو غذای هفته آینده فقط برای این هفته غیرفعال شود؟\n\n'
                            'این لغو موقت است و یادآور در هفته‌های بعد به صورت خودکار فعال خواهد بود.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              child: const Text('انصراف'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.of(context).pop(true),
                              child: const Text('لغو برای این هفته'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true) {
                        await state.setNudgeWeekDismissal(nextSat);
                      }
                    },
                    icon: const Icon(Icons.snooze_outlined, size: 18),
                    label: const Text('لغو یادآور رزرو برای این هفته'),
                  ),
                ],
              ],
            )
          : const SizedBox.shrink(),
    );
  }
}

/// The opt-in live portal check.
class _LiveSyncCard extends StatelessWidget {
  const _LiveSyncCard({
    required this.enabled,
    required this.onChanged,
  });

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'بررسی آنلاین سامانه',
      subtitle:
          'پیش‌فرض خاموش است. یادآورها از اطلاعات ذخیره‌شده روی گوشی استفاده می‌کنند '
          'و برای هر اعلان وارد سامانه نمی‌شوند.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                enabled ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                size: 20,
                color: enabled
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  enabled ? 'روشن (بررسی قبل از ارسال)' : 'خاموش (پیش‌فرض)',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: enabled ? FontWeight.w600 : FontWeight.normal,
                    color: enabled ? theme.colorScheme.primary : null,
                  ),
                ),
              ),
              Switch(
                value: enabled,
                onChanged: onChanged,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'با روشن کردن این گزینه، پیش از هر اعلان وضعیت از سامانه خوانده می‌شود. '
            'این کار هر بار یک ورود به سامانه لازم دارد.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
