/// The hunt screen: "تعیین بازه زمانی و وعده غذایی" — the portal's own phrase
/// for this feature, used here so the app speaks the same language as the
/// thing it automates.
///
/// ## Why a wizard
///
/// Each step depends on the one before it. The date and the meal decide which
/// dishes the portal is serving; the dishes and the halls decide what the
/// hunt buys; the rate decides what the hunt costs in requests. Showing them
/// as one flat form would mean the user picks a dish before knowing whether
/// the portal serves it that day.
///
/// ## The number that matters
///
/// The projected request count is the figure the user is actually trading
/// against, so it sits next to the slider and moves as the slider moves. A
/// label saying "fast" is not information; a count that changes is.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../core/account.dart';

import '../../core/hunt_config.dart';
import '../../core/hunt_notify.dart';
import '../../core/hunt_schedule.dart';
import '../../core/models.dart';
import '../../core/persian.dart';
import '../../core/service_calendar.dart';
import '../../core/time.dart';
import '../jalali_date_picker.dart';
import '../theme.dart';
import '../widgets.dart';

/// A dish the portal offers, as the hunt screen sees it.
///
/// Carries the hall it is offered in, because the buy page lists the dishes
/// on offer *and* the halls the row is served in, and the user picks both.
class HuntDishOption {
  const HuntDishOption({
    required this.optionId,
    required this.name,
    required this.priceRial,
    required this.halls,
  });

  final String optionId;
  final String name;
  final int priceRial;

  /// The halls the market offers this dish in.
  final List<Hall> halls;
}

/// The screen's view of the hunt, so the widget can be driven from a test.
class HuntScreen extends StatefulWidget {
  const HuntScreen({
    super.key,
    required this.dishes,
    required this.halls,
    required this.config,
    required this.onConfigChanged,
    this.accounts = const [],
    this.activeAccountId,
    this.onAccountChanged,
    this.balanceFor,
    this.preflightSummary,
    this.preflightRefusal,
    this.onStart,
    this.onStop,
    this.isRunning = false,
    this.marketError,
    this.targetDates = const [],
    this.schedule,
    this.enableRefusal,
    this.onTopUp,
  });

  /// The accounts available in the app.
  final List<SavedAccount> accounts;

  /// The account currently active for hunting.
  final AccountId? activeAccountId;

  /// Called when the user switches the active account.
  final void Function(AccountId)? onAccountChanged;

  /// Balance lookup for an account, in Rial.
  final int? Function(AccountId)? balanceFor;

  /// The dates the portal will serve that the hunt may target.
  ///
  /// Only the dates that are still open are offered, because a hunt for a
  /// locked date could never buy anything — the reservation cutoff has passed.
  final List<DateTime> targetDates;

  /// The dishes the portal offers for the chosen date and slot.
  final List<HuntDishOption> dishes;

  /// The halls the portal named for this account.
  final List<Hall> halls;

  /// Why the market could not be read, when it could not.
  ///
  /// Null means the read succeeded. An empty dish list is ambiguous on its
  /// own — it reads as "the market has nothing" — so the failure is stated.
  final String? marketError;

  /// The configuration being edited.
  final HuntConfig config;

  /// Called whenever the user changes the configuration.
  final void Function(HuntConfig) onConfigChanged;

  /// The pre-flight verdict, when the hunt is ready to start.
  final String? preflightSummary;

  /// Why the hunt was refused, when it was.
  final String? preflightRefusal;

  /// Starts the hunt. Null when the screen cannot start one.
  final VoidCallback? onStart;

  /// Stops a running hunt.
  final VoidCallback? onStop;

  /// Whether a hunt is currently running.
  final bool isRunning;

  /// When the hunt will start by itself, and whether it will.
  ///
  /// Null when the schedule has not been worked out — which is a state the
  /// card has to be honest about rather than paper over.
  final HuntScheduleResult? schedule;

  /// Why the hunt could not be switched **on**, when it could not.
  ///
  /// Null once it can. Distinct from [preflightRefusal], which is about
  /// starting the hunt now rather than about arming it to start later.
  final String? enableRefusal;

  /// Offers the top-up that would clear an insufficient-funds refusal.
  ///
  /// Null when a top-up is not the fix, so the button is not shown for a
  /// refusal money cannot solve (a closed window, an unserved meal).
  final VoidCallback? onTopUp;

  @override
  State<HuntScreen> createState() => _HuntScreenState();
}

class _HuntScreenState extends State<HuntScreen> {
  @override
  Widget build(BuildContext context) {
    final config = widget.config;

    final showAccountPicker = widget.accounts.length > 1 &&
        widget.activeAccountId != null &&
        widget.onAccountChanged != null;

    return Scaffold(
      appBar: AppBar(title: const Text('شکار')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          if (showAccountPicker) ...[
            _HuntAccountPicker(
              accounts: widget.accounts,
              activeId: widget.activeAccountId!,
              balanceFor: widget.balanceFor,
              onChanged: widget.onAccountChanged!,
            ),
            const SizedBox(height: 12),
          ],
          _EnabledCard(
            config: config,
            isRunning: widget.isRunning,
            schedule: widget.schedule,
            enableRefusal: widget.enableRefusal,
            onTopUp: widget.onTopUp,
            today: widget.targetDates.isNotEmpty ? widget.targetDates.first : null,
            onChanged: widget.onConfigChanged,
          ),
          const SizedBox(height: 12),
          _TargetCard(
            config: config,
            dates: widget.targetDates,
            schedule: widget.schedule,
            onChanged: widget.onConfigChanged,
          ),
          const SizedBox(height: 12),
          _DishesCard(
            config: config,
            dishes: widget.dishes,
            error: widget.marketError,
            onChanged: widget.onConfigChanged,
          ),
          const SizedBox(height: 12),
          _HallsCard(
            config: config,
            halls: widget.halls,
            error: widget.marketError,
            onChanged: widget.onConfigChanged,
          ),
          const SizedBox(height: 12),
          _RateCard(config: config, onChanged: widget.onConfigChanged),
          const SizedBox(height: 12),
          _PreflightCard(
            config: config,
            summary: widget.preflightSummary,
            refusal: widget.preflightRefusal,
            isRunning: widget.isRunning,
            schedule: widget.schedule,
            onStart: widget.onStart,
            onStop: widget.onStop,
            onChanged: widget.onConfigChanged,
          ),
        ],
      ),
    );
  }
}

/// The row of chips that picks the account the hunt targets.
class _HuntAccountPicker extends StatelessWidget {
  const _HuntAccountPicker({
    required this.accounts,
    required this.activeId,
    required this.onChanged,
    this.balanceFor,
  });

  final List<SavedAccount> accounts;
  final AccountId activeId;
  final void Function(AccountId) onChanged;
  final int? Function(AccountId)? balanceFor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.switch_account_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'شکار برای حساب:',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final account in accounts) ...[
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: ChoiceChip(
                        avatar: CircleAvatar(
                          radius: 12,
                          backgroundColor: account.id == activeId
                              ? theme.colorScheme.primary
                              : theme.colorScheme.surfaceContainerHighest,
                          child: Text(
                            account.resolvedName.isNotEmpty
                                ? account.resolvedName.characters.first
                                : '؟',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: account.id == activeId
                                  ? theme.colorScheme.onPrimary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        label: Text(
                          balanceFor?.call(account.id) != null
                              ? '${account.resolvedName} • ${formatTomanPersian(balanceFor!(account.id)!)}'
                              : account.resolvedName,
                        ),
                        selected: account.id == activeId,
                        onSelected: (selected) {
                          if (selected) onChanged(account.id);
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The switch that turns the hunt on.
///
/// ## Why it is at the top
///
/// A hunt spends money and makes requests, so it is **opt-in**: the flag
/// defaults to off, and the pre-flight refuses a rule that is off. This card
/// is the only place the student can change that, so it is the first thing on
/// the screen — the state of the hunt, before its details.
///
/// ## Why it is more than a switch
///
/// The cost of a hunt is not the same everywhere. A hunt at ten seconds makes
/// about 1,400 requests over a four-hour window; at two seconds it makes
/// 7,200. So the card says what the hunt will cost while it is off, and the
/// student can see the number before turning it on rather than after.
class _EnabledCard extends StatelessWidget {
  const _EnabledCard({
    required this.config,
    required this.isRunning,
    required this.schedule,
    required this.onChanged,
    this.enableRefusal,
    this.onTopUp,
    this.today,
  });

  final HuntConfig config;
  final bool isRunning;
  final HuntScheduleResult? schedule;
  final void Function(HuntConfig) onChanged;

  /// Why the hunt could not be switched on, when it could not.
  final String? enableRefusal;

  /// Offers a top-up, when a top-up is what would clear the refusal.
  final VoidCallback? onTopUp;

  /// The portal's today, used for relative day tags.
  final DateTime? today;

  /// Whether the hunt's window is open right now.
  ///
  /// The window being open is not a failure and not a schedule: the hunt starts
  /// immediately, so the card says *that* rather than a start time already
  /// passed. See [HuntScheduleStatus.windowOpen].
  bool get isOpenNow => schedule?.isOpenNow ?? false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final projected = config.projectedRequests();
    final start = _startText();

    final subtitle = config.enabled
        ? (start == null
            ? 'این شکار روشن است.'
            : 'این شکار روشن است و $start به‌طور خودکار شروع می‌شود.')
        : 'شکار خاموش است. تا آن را روشن نکنید، شکاری اجرا نمی‌شود.';

    final String activeSubtitle;
    if (isOpenNow) {
      activeSubtitle = config.enabled
          ? 'این شکار روشن است و بازه زمانی آن همین حالا باز است، '
              'پس بیدرنگ شروع می‌شود.'
          : 'بازه زمانی این شکار هم‌اکنون باز است؛ '
              'با روشن کردن، شکار بیدرنگ شروع می‌شود.';
    } else {
      activeSubtitle = subtitle;
    }

    return SectionCard(
      title: 'فعال‌سازی شکار',
      subtitle: activeSubtitle,
      trailing: Switch(
        value: config.enabled,
        onChanged: (value) => onChanged(config.copyWith(enabled: value)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                config.enabled
                    ? Icons.play_circle_outline
                    : Icons.pause_circle_outline,
                size: 20,
                color: config.enabled
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  config.enabled
                      ? 'با روشن بودن، برنامه در بازه زمانی مشخص‌شده به‌طور خودکار '
                          'جست‌وجو می‌کند و در صورت یافتن، غذا را می‌خرد.'
                      : 'روشن کردن این گزینه به معنی اجازه خرید خودکار است.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          // The red "it will not start" line is suppressed when the window is
          // open: there it is not a refusal, it is an immediate start, and the
          // subtitle already says so. Printing both would contradict itself.
          if (config.enabled && start == null && !isOpenNow && _noScheduleReason().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              _noScheduleReason(),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (enableRefusal != null) ...[
            const SizedBox(height: 10),
            _Banner(
              icon: Icons.error_outline,
              text: enableRefusal!,
              background: theme.colorScheme.errorContainer,
              foreground: theme.colorScheme.onErrorContainer,
            ),
            if (onTopUp != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.tonalIcon(
                  onPressed: onTopUp,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('افزایش اعتبار'),
                ),
              ),
            ],
          ],
          const SizedBox(height: 10),
          Text(
            'هزینه تقریبی این شکار در بازه فعلی: '
            '${toPersianDigits(projected)} درخواست',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: config.rate.needsRiskAcknowledgement
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurface,
            ),
          ),
          if (isRunning) ...[
            const SizedBox(height: 6),
            Text(
              'یک شکار هم‌اکنون در حال اجراست.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// When the hunt will start, in Persian, or null when it will not.
  ///
  /// ## Why the time is spelled out
  ///
  /// The card says the hunt «شروع می‌شود» — "starts". A student who reads
  /// that has no way to tell a hunt that starts at 16:30 tonight from one
  /// that starts tomorrow morning, or one that will not start at all because
  /// its window has passed. So the time is here, in the same card, and a hunt
  /// that cannot start says so instead of saying nothing.
  String? _startText() {
    final result = schedule;
    if (result == null) return null;
    if (!result.isScheduled) return null;

    final wakeAt = result.schedule!.wakeAtUtc;
    // The instant is a UTC moment, but the student thinks in the portal's
    // wall clock — the same clock the window is set in.
    final local = wakeAt.add(ServerClock.portalUtcOffset);
    final formatted = formatPersianDate(local);
    final rel = _relativeDayTag(local, today);
    final dateStr = rel != null ? '$formatted ($rel)' : formatted;

    return 'در ساعت ${formatClockTimePersian(local.hour, local.minute)} '
        'در $dateStr';
  }

  /// Why the hunt will not start, in Persian.
  ///
  /// The reasons are different and they call for different things from the
  /// student, so they are told apart rather than pooled into one message.
  String _noScheduleReason() {
    final result = schedule;
    if (result == null) {
      return 'زمان شروع خودکار هنوز مشخص نشده است.';
    }

    switch (result.status) {
      case HuntScheduleStatus.disabled:
        return '';
      case HuntScheduleStatus.noTargetDate:
        return 'برای شروع خودکار، ابتدا تاریخ این وعده را انتخاب کنید.';
      case HuntScheduleStatus.mealNotServed:
        return 'این وعده در این تاریخ ارائه نمی‌شود، پس شکاری برای آن معنا '
            'ندارد.';
      case HuntScheduleStatus.windowPassed:
        return 'بازه زمانی این شکار گذشته است. برای شروع خودکار، تاریخ یا '
            'بازه را تغییر دهید.';
      case HuntScheduleStatus.windowOpen:
        return 'بازه زمانی این شکار هم‌اکنون باز است. برای شروع خودکار، '
            'تاریخ این وعده را تغییر دهید.';
      case HuntScheduleStatus.windowInvalid:
        return 'بازه زمانی معتبر نیست: ساعت پایان باید پس از ساعت شروع '
            'باشد.';
      case HuntScheduleStatus.clockUnsynced:
        return 'ساعت سرور همگام نشده است، پس زمان شروع خودکار مشخص نیست.';
      case HuntScheduleStatus.scheduled:
        return '';
    }
  }
}

/// The peak window the chosen meal implies.
///
/// Shown inline with the slot picker so the connection between "which meal"
/// and "when the hunt is hot" is visible rather than implied.
class _PeakNote extends StatelessWidget {
  const _PeakNote({required this.slot});

  final MealSlot slot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final peak = distributionWindows[slot]!;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
      ),
      child: Row(
        children: [
          Icon(Icons.bolt, size: 20, color: theme.colorScheme.secondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'بازه اوج ${mealSlotPersian(slot)}: '
              '${formatClockTimePersian(peak.start.hour, peak.start.minute)}'
              ' تا '
              '${formatClockTimePersian(peak.end.hour, peak.end.minute)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.secondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Returns a human-friendly relative label for [target] relative to [today],
/// such as "امروز", "فردا", or "پس‌فردا".
String? _relativeDayTag(DateTime target, DateTime? today) {
  if (today == null) return null;
  final targetDay = DateTime.utc(target.year, target.month, target.day);
  final currentDay = DateTime.utc(today.year, today.month, today.day);
  final diff = targetDay.difference(currentDay).inDays;
  if (diff == 0) return 'امروز';
  if (diff == 1) return 'فردا';
  if (diff == 2) return 'پس‌فردا';
  return null;
}

/// The target date, with a picker over the dates the portal will still serve.
class _DateRow extends StatelessWidget {
  const _DateRow({
    required this.date,
    required this.dates,
    required this.slot,
    required this.onChanged,
    this.today,
  });

  final DateTime? date;
  final List<DateTime> dates;
  final MealSlot slot;
  final DateTime? today;
  final void Function(DateTime?) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final String dateDisplay;
    if (date == null) {
      dateDisplay = 'انتخاب کنید';
    } else {
      final formatted = formatPersianDate(date!);
      final tag = _relativeDayTag(date!, today);
      dateDisplay = tag != null ? '$formatted ($tag)' : formatted;
    }

    return InkWell(
      onTap: () async {
        // The calendar is the app's own Jalali one: Flutter's picker renders
        // a Gregorian calendar even under the Persian locale, which is a
        // hybrid the portal and the rest of the app never use.
        //
        // The range comes from [dates] — the dates the portal will still
        // serve — and never from the device clock. The device clock is not
        // trusted for anything the portal decides, and a date picked off it
        // can be a day the halls are shut, which is a hunt for a meal that
        // will never be served.
        final calendar = const ServiceCalendar();

        if (dates.isEmpty) {
          // Nothing is reservable, so there is nothing to pick. The reason is
          // on the screen already — the portal could not be read, or the
          // cutoff has passed for every date in range.
          return;
        }

        final first = dates.first;
        final last = dates.last;
        final nonClosed = dates.where((d) => !calendar.isClosedOn(d)).toList();

        final initialDate = (date != null &&
                !date!.isBefore(first) &&
                !date!.isAfter(last) &&
                !calendar.isClosedOn(date!))
            ? date!
            : (nonClosed.isNotEmpty ? nonClosed.first : (date ?? first));

        final picked = await showJalaliDatePicker(
          context: context,
          initial: initialDate,
          first: first,
          last: last,
          // All days when meals are served (including Thursday) are selectable.
          isSelectable: (d) => !calendar.isClosedOn(d),
          helpText: 'تاریخ غذا',
        );
        if (picked == null) return;

        if (calendar.isClosedOn(picked)) return;

        onChanged(DateTime.utc(picked.year, picked.month, picked.day));
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(Icons.event, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Text('تاریخ', style: theme.textTheme.bodyMedium),
            const Spacer(),
            Text(
              dateDisplay,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Displays unambiguous scheduling information showing when the hunt will run.
class _WindowExecutionSummary extends StatelessWidget {
  const _WindowExecutionSummary({
    required this.config,
    required this.collectionDate,
    required this.todayUtc,
    this.schedule,
  });

  final HuntConfig config;
  final DateTime? collectionDate;
  final DateTime? todayUtc;
  final HuntScheduleResult? schedule;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final target = config.targetDate;
    if (target == null) return const SizedBox.shrink();

    final startStr = formatClockTimePersian(config.windowStart.hour, config.windowStart.minute);
    final endStr = formatClockTimePersian(config.windowEnd.hour, config.windowEnd.minute);

    final String message;
    final bool isWarning;

    final status = schedule?.status;

    final startDay = schedule?.schedule?.startDate ??
        config.startDate ??
        config.effectiveStartDate ??
        collectionDate;

    final isCrossDay = startDay != null &&
        collectionDate != null &&
        (startDay.year != collectionDate!.year ||
            startDay.month != collectionDate!.month ||
            startDay.day != collectionDate!.day);

    final startRel = startDay != null ? _relativeDayTag(startDay, todayUtc) : null;
    final startWeekday = startDay != null ? persianWeekdays[startDay.weekday] : null;
    final startDayLabel = startRel != null ? '$startRel ($startWeekday)' : startWeekday;

    final endRel = collectionDate != null ? _relativeDayTag(collectionDate!, todayUtc) : null;
    final endWeekday = collectionDate != null ? persianWeekdays[collectionDate!.weekday] : null;
    final endDayLabel = endRel != null ? '$endRel ($endWeekday)' : endWeekday;

    final timeSpanLabel = isCrossDay
        ? 'از $startDayLabel ساعت $startStr تا $endDayLabel ساعت $endStr'
        : '$endDayLabel از ساعت $startStr تا $endStr';

    if (collectionDate == null || status == HuntScheduleStatus.mealNotServed) {
      isWarning = true;
      message = 'این وعده (${mealSlotPersian(config.targetSlot)}) در تاریخ انتخاب‌شده ارائه نمی‌شود، بنابراین شکاری اجرا نخواهد شد.';
    } else if (status == HuntScheduleStatus.windowInvalid) {
      isWarning = true;
      message = 'بازه زمانی معتبر نیست: ساعت پایان باید پس از ساعت شروع باشد.';
    } else if (status == HuntScheduleStatus.windowPassed) {
      isWarning = true;
      message = 'بازه زمانی این شکار ($timeSpanLabel) گذشته است. لطفاً تاریخ یا بازه را تغییر دهید.';
    } else if (status == HuntScheduleStatus.windowOpen) {
      isWarning = false;
      message = 'بازه زمانی شکار برای ${mealSlotPersian(config.targetSlot)} ($timeSpanLabel) هم‌اکنون باز است!';
    } else {
      isWarning = false;
      if (config.targetSlot == MealSlot.breakfast) {
        message = 'زمان اجرای شکار: $timeSpanLabel (با توجه به توزیع صبحانه همزمان با شام روز قبل).';
      } else {
        message = 'زمان اجرای شکار برای ${mealSlotPersian(config.targetSlot)}: $timeSpanLabel.';
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: isWarning
            ? theme.colorScheme.errorContainer.withValues(alpha: 0.5)
            : theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isWarning ? Icons.warning_amber_rounded : Icons.info_outline,
            size: 20,
            color: isWarning ? theme.colorScheme.error : theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: isWarning
                    ? theme.colorScheme.onErrorContainer
                    : theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Quick date selection chips for today, tomorrow, and the day after tomorrow.
class _QuickDateChips extends StatelessWidget {
  const _QuickDateChips({
    required this.currentDate,
    required this.dates,
    required this.slot,
    required this.today,
    required this.onSelected,
  });

  final DateTime? currentDate;
  final List<DateTime> dates;
  final MealSlot slot;
  final DateTime today;
  final void Function(DateTime) onSelected;

  @override
  Widget build(BuildContext context) {
    final calendar = const ServiceCalendar();
    final items = <_QuickDateOption>[];

    final labels = ['امروز', 'فردا', 'پس‌فردا'];
    for (var i = 0; i < 3; i++) {
      final target = DateTime.utc(today.year, today.month, today.day + i);
      final match = dates.where((d) =>
          d.year == target.year &&
          d.month == target.month &&
          d.day == target.day).firstOrNull;
      if (match != null) {
        final isServed = !calendar.isClosedOn(match);
        items.add(_QuickDateOption(
          date: match,
          label: labels[i],
          isServed: isServed,
        ));
      }
    }

    if (items.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in items)
          ChoiceChip(
            label: Text(
              item.isServed ? item.label : '${item.label} (تعطیل)',
            ),
            selected: currentDate != null &&
                currentDate!.year == item.date.year &&
                currentDate!.month == item.date.month &&
                currentDate!.day == item.date.day,
            onSelected: item.isServed
                ? (selected) {
                    if (selected) onSelected(item.date);
                  }
                : null,
          ),
      ],
    );
  }
}

class _QuickDateOption {
  const _QuickDateOption({
    required this.date,
    required this.label,
    required this.isServed,
  });

  final DateTime date;
  final String label;
  final bool isServed;
}

/// Start date options when the target meal's collection date is in the future.
class _StartDateChips extends StatelessWidget {
  const _StartDateChips({
    required this.currentStartDate,
    required this.todayUtc,
    required this.collectionDate,
    required this.windowStart,
    required this.windowEnd,
    required this.onSelected,
  });

  final DateTime? currentStartDate;
  final DateTime todayUtc;
  final DateTime collectionDate;
  final ClockTime windowStart;
  final ClockTime windowEnd;
  final void Function(DateTime) onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOvernight = windowEnd <= windowStart;

    final effectiveSelected = currentStartDate ??
        (isOvernight ? todayUtc : collectionDate);

    final days = <DateTime>[];
    var cur = todayUtc;
    while (!cur.isAfter(collectionDate)) {
      days.add(cur);
      cur = cur.add(const Duration(days: 1));
    }

    if (days.length <= 1) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.play_circle_outline,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              'تاریخ شروع عملیات:',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final day in days)
              _buildChip(theme, day, effectiveSelected),
          ],
        ),
      ],
    );
  }

  Widget _buildChip(ThemeData theme, DateTime day, DateTime effectiveSelected) {
    final isSelected = day.year == effectiveSelected.year &&
        day.month == effectiveSelected.month &&
        day.day == effectiveSelected.day;

    final isToday = day.year == todayUtc.year &&
        day.month == todayUtc.month &&
        day.day == todayUtc.day;

    final isCollection = day.year == collectionDate.year &&
        day.month == collectionDate.month &&
        day.day == collectionDate.day;

    final rel = _relativeDayTag(day, todayUtc);
    final weekday = persianWeekdays[day.weekday];

    final String label;
    if (isToday) {
      label = 'امروز ($weekday - از الان)';
    } else if (isCollection) {
      label = rel != null ? '$rel ($weekday - روز وعده)' : '$weekday (روز وعده)';
    } else {
      label = rel != null ? '$rel ($weekday)' : weekday;
    }

    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) {
        onSelected(day);
      },
    );
  }
}

/// The target: date, meal, time window, and execution schedule.
class _TargetCard extends StatelessWidget {
  const _TargetCard({
    required this.config,
    required this.onChanged,
    this.dates = const [],
    this.schedule,
  });

  final HuntConfig config;
  final List<DateTime> dates;
  final HuntScheduleResult? schedule;
  final void Function(HuntConfig) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final collection = HuntSchedules.collectionDate(
      targetDate: config.targetDate,
      slot: config.targetSlot,
    );

    final today = dates.isNotEmpty ? dates.first : null;
    final todayUtc = today != null
        ? DateTime.utc(today.year, today.month, today.day)
        : () {
            final now = DateTime.now().toUtc().add(ServerClock.portalUtcOffset);
            return DateTime.utc(now.year, now.month, now.day);
          }();

    return SectionCard(
      title: 'تاریخ، وعده و بازه زمانی',
      subtitle: 'تعیین تاریخ غذا، وعده و بازه زمانی جست‌وجو؛ شکار فقط در این تاریخ و '
          'بازه زمانی اجرا می‌شود.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DateRow(
            date: config.targetDate,
            dates: dates,
            slot: config.targetSlot,
            today: todayUtc,
            onChanged: (d) {
              if (d == null) return;
              final calendar = const ServiceCalendar();
              var slot = config.targetSlot;
              if (!calendar.isServedOn(d, slot)) {
                final served = calendar.servedSlots(Weekday.fromDateTime(d));
                if (served.isNotEmpty) {
                  slot = served.contains(MealSlot.lunch) ? MealSlot.lunch : served.first;
                }
              }
              onChanged(config.retargeted(targetDate: d, targetSlot: slot));
            },
          ),
          if (dates.isNotEmpty) ...[
            const SizedBox(height: 8),
            _QuickDateChips(
              currentDate: config.targetDate,
              dates: dates,
              slot: config.targetSlot,
              today: todayUtc,
              onSelected: (d) {
                final calendar = const ServiceCalendar();
                var slot = config.targetSlot;
                if (!calendar.isServedOn(d, slot)) {
                  final served = calendar.servedSlots(Weekday.fromDateTime(d));
                  if (served.isNotEmpty) {
                    slot = served.contains(MealSlot.lunch) ? MealSlot.lunch : served.first;
                  }
                }
                onChanged(config.retargeted(targetDate: d, targetSlot: slot));
              },
            ),
          ],
          if (dates.isEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'هنوز هیچ تاریخی برای شکار در دسترس نیست. این معمولاً یعنی '
              'ساعت سرور همگام نشده است یا مهلت رزرو همه تاریخ‌ها گذشته است.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final slot in MealSlot.values)
                ChoiceChip(
                  label: Text(mealSlotPersian(slot)),
                  selected: config.targetSlot == slot,
                  onSelected: (_) => onChanged(config.retargeted(targetSlot: slot)),
                ),
            ],
          ),
          if (collection != null && collection.isAfter(todayUtc)) ...[
            const SizedBox(height: 10),
            _StartDateChips(
              currentStartDate: config.startDate,
              todayUtc: todayUtc,
              collectionDate: collection,
              windowStart: config.windowStart,
              windowEnd: config.windowEnd,
              onSelected: (d) => onChanged(config.copyWith(startDate: d)),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _TimeRow(
                  label: 'شروع',
                  value: config.windowStart,
                  onChanged: (t) {
                    final newConfig = config.copyWith(windowStart: t);
                    if (newConfig.windowEnd <= t &&
                        newConfig.startDate == null &&
                        collection != null &&
                        collection.isAfter(todayUtc)) {
                      onChanged(newConfig.copyWith(startDate: todayUtc));
                    } else {
                      onChanged(newConfig);
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _TimeRow(
                  label: 'پایان',
                  value: config.windowEnd,
                  onChanged: (t) {
                    final newConfig = config.copyWith(windowEnd: t);
                    if (t <= newConfig.windowStart &&
                        newConfig.startDate == null &&
                        collection != null &&
                        collection.isAfter(todayUtc)) {
                      onChanged(newConfig.copyWith(startDate: todayUtc));
                    } else {
                      onChanged(newConfig);
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _PeakNote(slot: config.targetSlot),
          if (config.targetDate != null) ...[
            const SizedBox(height: 10),
            _WindowExecutionSummary(
              config: config,
              collectionDate: collection,
              todayUtc: todayUtc,
              schedule: schedule,
            ),
          ],
          if (config.peakOverlapSeconds == 0) ...[
            const SizedBox(height: 10),
            Text(
              'این بازه با بازه اوج هم‌پوشانی ندارد، پس شکار همیشه با نرخ '
              'بیرون از اوج بررسی می‌کند.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One editable time.
class _TimeRow extends StatelessWidget {
  const _TimeRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final ClockTime value;
  final void Function(ClockTime) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: TimeOfDay(hour: value.hour, minute: value.minute),
          helpText: label,
          builder: (context, child) => Directionality(
            textDirection: TextDirection.rtl,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
              child: child!,
            ),
          ),
        );
        if (picked == null) return;
        onChanged(ClockTime(picked.hour, picked.minute));
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(Icons.schedule,
                size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(label, style: theme.textTheme.bodyMedium),
            const Spacer(),
            Text(
              formatClockTimePersian(value.hour, value.minute),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The dishes, in priority order.
class _DishesCard extends StatelessWidget {
  const _DishesCard({
    required this.config,
    required this.dishes,
    required this.onChanged,
    this.error,
  });

  final HuntConfig config;
  final List<HuntDishOption> dishes;
  final void Function(HuntConfig) onChanged;

  /// Why the market could not be read, when it could not.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'غذاها',
      subtitle: 'اولویت اول خریداری می‌شود؛ اگر موجود نبود، دومی خریداری '
          'می‌شود. انتخاب دومی اختیاری است.',
      child: dishes.isEmpty
          ? Text(
              error ?? 'برای این تاریخ و وعده غذایی در سامانه موجود نیست.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: error == null
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.error,
              ),
            )
          : Column(
              children: [
                for (final dish in dishes)
                  _DishTile(
                    dish: dish,
                    position: _positionOf(dish),
                    onToggle: () => _toggle(dish),
                  ),
              ],
            ),
    );
  }

  /// The 1-based priority position of a dish, or null when it is not chosen.
  int? _positionOf(HuntDishOption dish) {
    final key = normalizeDishName(dish.name);
    for (var i = 0; i < config.dishPriority.length; i++) {
      if (config.dishPriority[i].dishKey == key) return i + 1;
    }
    return null;
  }

  /// Adds a dish to the end of the list, or removes it.
  void _toggle(HuntDishOption dish) {
    final key = normalizeDishName(dish.name);
    final existing = config.dishPriority.indexWhere(
      (d) => d.dishKey == key,
    );

    if (existing >= 0) {
      final next = List<HuntDish>.from(config.dishPriority)..removeAt(existing);
      onChanged(config.copyWith(dishPriority: next));
      return;
    }

    // The list is capped at two: "the first choice, then the second". A third
    // would be a rule the user cannot hold in their head, and the pre-flight
    // credit check would then demand the sum of three meals.
    if (config.dishPriority.length >= 2) return;

    onChanged(config.copyWith(
      dishPriority: [
        ...config.dishPriority,
        HuntDish(
          optionId: dish.optionId,
          name: dish.name,
          priceRial: dish.priceRial,
        ),
      ],
    ));
  }
}

/// One dish, with its priority mark and its price.
class _DishTile extends StatelessWidget {
  const _DishTile({
    required this.dish,
    required this.position,
    required this.onToggle,
  });

  final HuntDishOption dish;
  final int? position;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = position != null;

    return CheckboxListTile(
      value: selected,
      onChanged: (_) => onToggle(),
      title: Text(dish.name),
      subtitle: MoneyText(
        dish.priceRial,
        style: theme.textTheme.bodySmall,
        colour: theme.colorScheme.onSurfaceVariant,
      ),
      secondary: selected
          ? CircleAvatar(
              radius: 14,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                toPersianDigits(position!),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          : null,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
    );
  }
}

/// The halls, in priority order.
class _HallsCard extends StatelessWidget {
  const _HallsCard({
    required this.config,
    required this.halls,
    required this.onChanged,
    this.error,
  });

  final HuntConfig config;
  final List<Hall> halls;
  final void Function(HuntConfig) onChanged;

  /// Why the list is empty, when it is empty because the read failed.
  ///
  /// Without it the card would claim the halls were "not read yet" on a
  /// screen where they *were* read and the meal simply has no serving hall.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'سلف‌ها',
      subtitle: 'خالی گذاشتن یعنی «هر سلفی که سامانه پیشنهاد دهد».',
      child: halls.isEmpty
          ? Text(
              error ?? 'برای این تاریخ و وعده غذایی سلفی اعلام نشده است.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: error == null
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.error,
              ),
            )
          : Column(
              children: [
                for (final hall in halls)
                  _HallTile(
                    hall: hall,
                    position: _positionOf(hall),
                    onToggle: () => _toggle(hall),
                  ),
              ],
            ),
    );
  }

  int? _positionOf(Hall hall) {
    for (var i = 0; i < config.hallPriority.length; i++) {
      if (config.hallPriority[i].id == hall.id) return i + 1;
    }
    return null;
  }

  void _toggle(Hall hall) {
    final existing =
        config.hallPriority.indexWhere((h) => h.id == hall.id);

    if (existing >= 0) {
      final next = List<HuntHall>.from(config.hallPriority)..removeAt(existing);
      onChanged(config.copyWith(hallPriority: next));
      return;
    }

    if (config.hallPriority.length >= 2) return;

    onChanged(config.copyWith(
      hallPriority: [...config.hallPriority, HuntHall(id: hall.id, name: hall.name)],
    ));
  }
}

/// One hall, with its priority mark.
class _HallTile extends StatelessWidget {
  const _HallTile({
    required this.hall,
    required this.position,
    required this.onToggle,
  });

  final Hall hall;
  final int? position;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = position != null;

    return CheckboxListTile(
      value: selected,
      onChanged: (_) => onToggle(),
      title: Text(hall.name),
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      secondary: selected
          ? CircleAvatar(
              radius: 14,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                toPersianDigits(position!),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          : null,
    );
  }
}

/// The rate: a slider per interval, and the cost of the rate.
class _RateCard extends StatelessWidget {
  const _RateCard({required this.config, required this.onChanged});

  final HuntConfig config;
  final void Function(HuntConfig) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rate = config.rate;
    final projected = config.projectedRequests();

    return SectionCard(
      title: 'سرعت بررسی',
      subtitle: 'هرچه فاصله کمتر باشد، شکار سریع‌تر است و درخواست بیشتری '
          'فرستاده می‌شود.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IntervalSlider(
            label: 'در بازه اوج',
            value: rate.peakInterval,
            min: HuntBounds.minPeakInterval,
            max: HuntBounds.maxPeakInterval,
            accent: _accentFor(rate.peakInterval, context),
            onChanged: (d) => onChanged(
              config.copyWith(rate: rate.copyWith(peakInterval: d)),
            ),
          ),
          const SizedBox(height: 16),
          _IntervalSlider(
            label: 'بیرون از بازه اوج',
            value: rate.offPeakInterval,
            min: HuntBounds.minOffPeakInterval,
            max: HuntBounds.maxOffPeakInterval,
            accent: _accentFor(rate.offPeakInterval, context),
            onChanged: (d) => onChanged(
              config.copyWith(rate: rate.copyWith(offPeakInterval: d)),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: theme.colorScheme.surfaceContainerHighest,
            ),
            child: Row(
              children: [
                Icon(Icons.cloud_upload_outlined,
                    size: 20, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'حدود ${toPersianDigits(projected)} درخواست در این بازه',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The band colour for an interval: green when safe, amber near the risk
  /// threshold, red at the aggressive extreme.
  static Color _accentFor(Duration interval, [BuildContext? context]) {
    final isDark = context != null && Theme.of(context).brightness == Brightness.dark;
    if (interval < HuntBounds.riskAcknowledgementThreshold) {
      return isDark ? AppColors.releasedDark : AppColors.released;
    }
    if (interval < const Duration(seconds: 20)) {
      return isDark ? AppColors.closingDark : AppColors.closing;
    }
    return isDark ? AppColors.heldDark : AppColors.held;
  }
}

/// A logarithmic slider over an interval range.
///
/// Logarithmic because the useful range spans 2 to 60 seconds, and a linear
/// slider spends most of its travel on the slow end, where nothing interesting
/// happens.
class _IntervalSlider extends StatelessWidget {
  const _IntervalSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.accent,
    required this.onChanged,
  });

  final String label;
  final Duration value;
  final Duration min;
  final Duration max;
  final Color accent;
  final void Function(Duration) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clamped = value < min ? min : (value > max ? max : value);
    final position = _positionOf(clamped);
    final steps = _steps();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: theme.textTheme.bodyMedium),
            const Spacer(),
            Text(
              _formatInterval(clamped),
              style: theme.textTheme.titleMedium?.copyWith(
                color: accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        Slider(
          value: position,
          min: 0,
          max: 1,
          divisions: steps,
          activeColor: accent,
          label: _formatInterval(clamped),
          onChanged: (p) => onChanged(_durationAt(p)),
        ),
      ],
    );
  }

  /// The number of discrete stops.
  ///
  /// One per second in the fast range, one per five seconds in the slow one —
  /// the slider is logarithmic, so the stops are too.
  int _steps() {
    final span = max.inSeconds - min.inSeconds;
    if (span <= 60) return span;
    return (span / 5).ceil();
  }

  /// The slider position for a duration, on a log scale.
  double _positionOf(Duration d) {
    final lo = _log(min.inSeconds.toDouble());
    final hi = _log(max.inSeconds.toDouble());
    final v = _log(d.inSeconds.toDouble());
    if (hi <= lo) return 0;
    return ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
  }

  /// The duration at a slider position.
  Duration _durationAt(double position) {
    final lo = _log(min.inSeconds.toDouble());
    final hi = _log(max.inSeconds.toDouble());
    final seconds = math.pow(10, lo + (hi - lo) * position).toDouble();
    return Duration(milliseconds: (seconds * 1000).round());
  }

  /// The base-10 logarithm, so the slider's travel matches its scale.
  static double _log(double x) => math.log(x) / math.ln10;

  /// An interval in Persian, e.g. «۱۰ ثانیه».
  static String _formatInterval(Duration d) {
    if (d.inSeconds < 60) {
      return '${toPersianDigits(d.inSeconds)} ثانیه';
    }
    if (d.inSeconds < 3600) {
      final minutes = d.inSeconds ~/ 60;
      final seconds = d.inSeconds % 60;
      if (seconds == 0) return '${toPersianDigits(minutes)} دقیقه';
      return '${toPersianDigits(minutes)} دقیقه و ${toPersianDigits(seconds)} ثانیه';
    }
    return '${toPersianDigits(d.inMinutes)} دقیقه';
  }
}

/// The pre-flight result, and the button that starts the hunt.
class _PreflightCard extends StatefulWidget {
  const _PreflightCard({
    required this.config,
    required this.summary,
    required this.refusal,
    required this.isRunning,
    required this.onStart,
    required this.onStop,
    this.schedule,
    this.onChanged,
  });

  final HuntConfig config;
  final String? summary;
  final String? refusal;
  final bool isRunning;
  final FutureOr<void> Function()? onStart;
  final FutureOr<void> Function()? onStop;
  final HuntScheduleResult? schedule;
  final FutureOr<void> Function(HuntConfig)? onChanged;

  @override
  State<_PreflightCard> createState() => _PreflightCardState();
}

class _PreflightCardState extends State<_PreflightCard> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOpenNow = widget.schedule?.isOpenNow ?? false;
    final isPassed = widget.schedule?.status == HuntScheduleStatus.windowPassed;

    final String buttonLabel;
    final Widget buttonIcon;
    final VoidCallback? buttonAction;

    if (_isLoading) {
      buttonLabel = 'در حال بررسی و آماده‌سازی...';
      buttonIcon = SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: theme.colorScheme.onPrimary,
        ),
      );
      buttonAction = null;
    } else if (widget.isRunning) {
      buttonLabel = 'توقف شکار';
      buttonIcon = const Icon(Icons.stop);
      buttonAction = widget.onStop == null
          ? null
          : () async {
              setState(() => _isLoading = true);
              try {
                await widget.onStop!();
              } finally {
                if (mounted) setState(() => _isLoading = false);
              }
            };
    } else if (isPassed) {
      buttonLabel = 'مهلت زمانی شکار گذشته است';
      buttonIcon = const Icon(Icons.timer_off_outlined);
      buttonAction = null;
    } else if (isOpenNow) {
      buttonLabel = 'شروع شکار';
      buttonIcon = const Icon(Icons.play_arrow);
      buttonAction = (widget.onStart == null || widget.refusal != null)
          ? null
          : () async {
              setState(() => _isLoading = true);
              try {
                if (!widget.config.enabled && widget.onChanged != null) {
                  await widget.onChanged!(widget.config.copyWith(enabled: true));
                }
                await widget.onStart!();
              } finally {
                if (mounted) setState(() => _isLoading = false);
              }
            };
    } else {
      // Window is in the future
      if (widget.config.enabled) {
        buttonLabel = 'لغو زمان‌بندی شکار';
        buttonIcon = const Icon(Icons.alarm_off);
        buttonAction = widget.onChanged == null
            ? null
            : () async {
                setState(() => _isLoading = true);
                try {
                  await widget.onChanged!(widget.config.copyWith(enabled: false));
                } finally {
                  if (mounted) setState(() => _isLoading = false);
                }
              };
      } else {
        buttonLabel = 'فعال‌سازی و زمان‌بندی خودکار';
        buttonIcon = const Icon(Icons.alarm_on);
        buttonAction = (widget.refusal != null || widget.onChanged == null)
            ? null
            : () async {
                setState(() => _isLoading = true);
                try {
                  await widget.onChanged!(widget.config.copyWith(enabled: true));
                } finally {
                  if (mounted) setState(() => _isLoading = false);
                }
              };
      }
    }

    final String cardSubtitle = _isLoading
        ? 'در حال بررسی پیش‌نیازها و اتصال به سامانه...'
        : widget.isRunning
            ? 'شکار در حال اجراست.'
            : isPassed
                ? 'بازه زمانی این شکار به پایان رسیده است.'
                : isOpenNow
                    ? 'بازه زمانی شکار باز است و می‌توانید همین حالا شکار را شروع کنید.'
                    : widget.config.enabled
                        ? 'شکار فعال و زمان‌بندی شده است.'
                        : 'پیش از شروع، بررسی می‌شود که این وعده را ندارید و موجودی کافی است.';

    return SectionCard(
      title: 'آمادگی شکار',
      subtitle: cardSubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.refusal != null)
            _Banner(
              icon: Icons.block,
              text: widget.refusal!,
              background: theme.colorScheme.errorContainer,
              foreground: theme.colorScheme.onErrorContainer,
            )
          else if (widget.summary != null)
            _Banner(
              icon: Icons.check_circle_outline,
              text: widget.summary!,
              background: theme.colorScheme.secondaryContainer,
              foreground: theme.colorScheme.onSecondaryContainer,
            ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: widget.isRunning
                  ? FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.error,
                      foregroundColor: theme.colorScheme.onError,
                    )
                  : null,
              onPressed: buttonAction,
              icon: buttonIcon,
              label: Text(buttonLabel),
            ),
          ),
        ],
      ),
    );
  }
}

/// A coloured message block.
class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.text,
    required this.background,
    required this.foreground,
  });

  final IconData icon;
  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: background,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: foreground),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks the user to accept the ban risk of a fast rate.
///
/// A **modal**, not a snackbar, because it must be acknowledged rather than
/// merely seen. The default focus is on cancel, so a stray Enter does not
/// accept a risk the user did not mean to take.
///
/// Returns true when the user accepted.
Future<bool> confirmRiskAcknowledgement(
  BuildContext context, {
  required Duration interval,
  required int projectedRequests,
}) async {
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => _RiskDialog(
      interval: interval,
      projectedRequests: projectedRequests,
    ),
  );
  return accepted ?? false;
}

/// The risk dialog.
class _RiskDialog extends StatelessWidget {
  const _RiskDialog({
    required this.interval,
    required this.projectedRequests,
  });

  final Duration interval;
  final int projectedRequests;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('هشدار ریسک مسدود شدن حساب'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'بررسی با فاصله کمتر از ۱۰ ثانیه، احتمال مسدود شدن یا محدود شدن '
            'حساب را به‌طور قابل توجهی بالا می‌برد.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 10),
          Text(
            'این ریسک روی خودِ حساب است: در صورت مسدود شدن، همه بخش‌های دیگر '
            'برنامه هم از کار می‌افتند، نه فقط شکار.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 10),
          Text(
            'در این بازه حدود ${toPersianDigits(projectedRequests)} درخواست '
            'فرستاده می‌شود.',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('انصراف'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('می‌پذیرم'),
        ),
      ],
    );
  }
}
