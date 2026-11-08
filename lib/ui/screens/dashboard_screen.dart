import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/persian.dart';
import '../../core/spend_summary.dart';
import '../../core/time.dart';
import '../app_state.dart';
import '../widgets.dart';

/// The finance dashboard: what the meals cost, broken down.
///
/// Features:
///   * **Period filters**: All time, by Week (with week switching), or by Month.
///   * **Multi-select dimensions**: Accounts and meal slots can be combined freely.
///   * **Reserved vs spent**: The figure is meals reserved, not bank money spent.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({
    super.key,
    required this.state,
    this.clock,
    this.onRefresh,
  });

  final AppState state;
  final ServerClock? clock;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final summary = state.spendSummary;

        final listView = ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            _TotalsCard(summary: summary),
            const SizedBox(height: 12),
            _FilterCard(state: state, clock: clock),
            const SizedBox(height: 12),
            _BreakdownCard(summary: summary),
            if (summary.entries.isNotEmpty) ...[
              const SizedBox(height: 12),
              _EntriesCard(summary: summary),
            ],
          ],
        );

        return Scaffold(
          appBar: AppBar(
            title: const Text('مالی'),
            actions: [
              if (!state.spendFilter.isUnfiltered)
                TextButton(
                  onPressed: state.clearSpendFilter,
                  child: const Text('پاک کردن فیلتر'),
                ),
            ],
          ),
          body: Column(
            children: [
              OfflineBanner(isOffline: state.isOffline),
              Expanded(
                child: state.transactions.isEmpty
                    ? const EmptyState(
                        icon: Icons.pie_chart_outline,
                        title: 'هنوز تراکنشی ثبت نشده',
                        message: 'پس از اولین رزرو یا خرید، هزینه‌ها اینجا نمایش داده می‌شوند.',
                      )
                    : (onRefresh != null
                        ? RefreshIndicator(
                            onRefresh: onRefresh!,
                            child: listView,
                          )
                        : listView),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The headline figures.
class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.summary});

  final SpendSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'مجموع',
      subtitle: 'هزینه وعده‌های رزروشده (تومان) • ${summary.filter.periodLabel}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              MoneyText(
                summary.totalRial,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.secondary,
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'برای ${toPersianDigits(summary.totalMeals)} وعده',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              _MiniStat(
                label: 'میانگین هر وعده',
                child: MoneyText(summary.averageMealRial,
                    style: theme.textTheme.titleSmall),
              ),
              if (summary.excludedWithdrawn > 0)
                _MiniStat(
                  label: 'وعده آزادشده (کسر شده)',
                  child: Text(
                    toPersianDigits(summary.excludedWithdrawn),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        child,
      ],
    );
  }
}

/// The filters card: Accounts, Slots, and Period (all, week, month).
class _FilterCard extends StatelessWidget {
  const _FilterCard({required this.state, this.clock});

  final AppState state;
  final ServerClock? clock;

  DateTime? get _referenceDate =>
      clock?.isSynced == true ? clock!.portalTodayUtc : null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accounts = state.accounts;
    final filter = state.spendFilter;

    return SectionCard(
      title: 'فیلتر',
      subtitle: 'بازه زمانی، چند حساب و چند وعده را هم‌زمان انتخاب کنید',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'حساب‌ها',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          if (accounts.isEmpty)
            Text(
              'حسابی ذخیره نشده است.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final account in accounts)
                  FilterChip(
                    label: Text(account.resolvedName),
                    selected: filter.accountIds.contains(account.id),
                    onSelected: (_) =>
                        state.toggleSpendAccount(account.id),
                  ),
              ],
            ),
          const SizedBox(height: 16),
          Text(
            'وعده‌ها',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final slot in MealSlot.values)
                FilterChip(
                  label: Text(mealSlotName(slot)),
                  selected: filter.slots.contains(slot),
                  onSelected: (_) => state.toggleSpendSlot(slot),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'بازه زمانی',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('همه'),
                selected: filter.periodType == SpendPeriodType.all,
                onSelected: (_) => state.setSpendPeriod(
                  SpendPeriodType.all,
                  referenceDate: _referenceDate,
                ),
              ),
              ChoiceChip(
                label: const Text('هفته'),
                selected: filter.periodType == SpendPeriodType.week,
                onSelected: (_) => state.setSpendPeriod(
                  SpendPeriodType.week,
                  referenceDate: _referenceDate,
                ),
              ),
              ChoiceChip(
                label: const Text('ماه'),
                selected: filter.periodType == SpendPeriodType.month,
                onSelected: (_) => state.setSpendPeriod(
                  SpendPeriodType.month,
                  referenceDate: _referenceDate,
                ),
              ),
            ],
          ),
          if (filter.periodType == SpendPeriodType.week) ...[
            const SizedBox(height: 12),
            _WeekSwitcher(state: state, filter: filter),
          ] else if (filter.periodType == SpendPeriodType.month) ...[
            const SizedBox(height: 12),
            _MonthSwitcher(state: state, filter: filter),
          ],
          if (filter.isUnfiltered) ...[
            const SizedBox(height: 12),
            Text(
              'بدون فیلتر — همه حساب‌ها و همه وعده‌ها نمایش داده می‌شوند.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Switcher for browsing between weeks.
class _WeekSwitcher extends StatelessWidget {
  const _WeekSwitcher({required this.state, required this.filter});

  final AppState state;
  final SpendFilter filter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final weekTitle = formatWeekTitle(filter.weekOffset);
    final weekRange = formatWeekRange(filter.targetSaturday);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: 'هفته قبل',
            onPressed: () => state.setSpendWeekOffset(filter.weekOffset - 1),
          ),
          Expanded(
            child: InkWell(
              onTap: filter.weekOffset != 0
                  ? () => state.setSpendWeekOffset(0)
                  : null,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          weekTitle,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: filter.weekOffset == 0
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                        if (filter.weekOffset != 0) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'هفته جاری',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      weekRange,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'هفته بعد',
            onPressed: () => state.setSpendWeekOffset(filter.weekOffset + 1),
          ),
        ],
      ),
    );
  }
}

/// Switcher for browsing between months.
class _MonthSwitcher extends StatelessWidget {
  const _MonthSwitcher({required this.state, required this.filter});

  final AppState state;
  final SpendFilter filter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final monthTitle = formatMonthTitle(filter.monthOffset);
    final target = filter.targetJalaliMonth;
    final monthName = formatJalaliMonthName(target.year, target.month);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: 'ماه قبل',
            onPressed: () => state.setSpendMonthOffset(filter.monthOffset - 1),
          ),
          Expanded(
            child: InkWell(
              onTap: filter.monthOffset != 0
                  ? () => state.setSpendMonthOffset(0)
                  : null,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          monthTitle,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: filter.monthOffset == 0
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                        if (filter.monthOffset != 0) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'ماه جاری',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      monthName,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'ماه بعد',
            onPressed: () => state.setSpendMonthOffset(filter.monthOffset + 1),
          ),
        ],
      ),
    );
  }
}

/// The per-slot breakdown with a bar chart.
class _BreakdownCard extends StatelessWidget {
  const _BreakdownCard({required this.summary});

  final SpendSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final slots = MealSlot.values
        .where((s) => (summary.bySlot.totals[s] ?? 0) > 0)
        .toList();

    if (slots.isEmpty) {
      return SectionCard(
        title: 'تفکیک بر اساس وعده',
        child: Text(
          'داده‌ای برای نمایش نیست.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final maxTotal = slots
        .map((s) => summary.bySlot.totals[s] ?? 0)
        .reduce((a, b) => a > b ? a : b);

    return SectionCard(
      title: 'تفکیک بر اساس وعده',
      subtitle: 'سهم هر وعده از مجموع',
      child: Column(
        children: [
          for (final slot in slots) ...[
            _BarRow(
              label: mealSlotName(slot),
              amountRial: summary.bySlot.totals[slot] ?? 0,
              fraction: maxTotal == 0
                  ? 0
                  : (summary.bySlot.totals[slot] ?? 0) / maxTotal,
              count: summary.bySlot.counts[slot] ?? 0,
            ),
            if (slot != slots.last) const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

/// One bar of the breakdown.
class _BarRow extends StatelessWidget {
  const _BarRow({
    required this.label,
    required this.amountRial,
    required this.fraction,
    required this.count,
  });

  final String label;
  final int amountRial;
  final double fraction;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: theme.textTheme.bodyMedium),
            ),
            Text(
              '${toPersianDigits(count)} وعده',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 10),
            MoneyText(amountRial, style: theme.textTheme.titleSmall),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 8,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation(theme.colorScheme.secondary),
          ),
        ),
      ],
    );
  }
}

/// The per-meal list.
class _EntriesCard extends StatelessWidget {
  const _EntriesCard({required this.summary});

  final SpendSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'وعده‌ها',
      subtitle: '${toPersianDigits(summary.entries.length)} مورد',
      child: Column(
        children: [
          for (final entry in summary.entries) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.foodName,
                        style: theme.textTheme.bodyMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${formatPersianDate(entry.date)} • ${mealSlotName(entry.slot)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                MoneyText(entry.amountRial, style: theme.textTheme.titleSmall),
              ],
            ),
            if (entry != summary.entries.last) const Divider(height: 20),
          ],
        ],
      ),
    );
  }
}

/// The Persian name of a meal slot.
String mealSlotName(MealSlot slot) => switch (slot) {
      MealSlot.breakfast => 'صبحانه',
      MealSlot.lunch => 'ناهار',
      MealSlot.dinner => 'شام',
    };
