import 'package:flutter/material.dart';

import '../../core/account.dart';
import '../../core/models.dart';
import '../../core/persian.dart';
import '../../core/portal.dart';
import '../../core/time.dart';
import '../app_state.dart';
import '../reservation_table_model.dart';
import '../widgets.dart';
import 'batch_booking_sheet.dart';
import 'reservations_table.dart';

/// The reservations screen: the student's week, in one table.
///
/// ## What it shows
///
/// One grid, one row per (date, meal) across the days that can still be
/// acted on. Every row states one thing plainly — what is the state of this
/// meal — and offers exactly one action:
///
///   * **held** — a weekly reservation, with a cancel button;
///   * **bought** — a Food Basket purchase, which is irreversible (F16), so
///     the row says so and offers nothing;
///   * **bookable** — served, still open, with a book button;
///   * **locked** — served, but the cutoff has passed, so nothing is offered.
///
/// ## The account picker
///
/// The student may hold several accounts, and the table is about **one**
/// account's meals. So the screen names the account it is showing, and the
/// student can switch. The picker is a row of chips, because the choice is
/// between a handful of names and it must be visible at a glance.
class ReservationsScreen extends StatefulWidget {
  const ReservationsScreen({
    super.key,
    required this.state,
    this.onBook,
    this.onCancel,
    this.onSell,
    this.onRemoveFromSell,
    this.onForgotReceipt,
    this.onMealDetails,
    this.onBatchBook,
    this.onBatchBookOfferings,
    this.onTopUp,
    this.onTopUpOfferings,
    this.onRefresh,
    this.onAccountChanged,
    this.menus = const [],
    this.clock,
    this.busy = false,
    this.busyKey,
  });

  final AppState state;

  /// Opens the booking sheet for a (date, slot).
  final void Function(DateTime date, MealSlot slot)? onBook;

  /// Cancels a held meal.
  final void Function(DateTime date, MealSlot slot)? onCancel;

  /// Lists a held meal for sale in the Food Basket.
  final void Function(DateTime date, MealSlot slot)? onSell;

  /// Removes a listed meal from the Food Basket sale.
  final void Function(DateTime date, MealSlot slot)? onRemoveFromSell;

  /// Requests a forgot receipt for a held meal.
  final void Function(DateTime date, MealSlot slot, String? dishName, ReserveType reserveType)? onForgotReceipt;

  /// Opens the details sheet for an existing or past meal.
  final void Function(MealRow row)? onMealDetails;

  /// Books multiple offerings in sequence.
  final Future<dynamic> Function(List<MealRow> rows)? onBatchBook;

  /// Books multiple offerings with student-chosen dishes and halls.
  final Future<dynamic> Function(List<MealOffering> offerings)? onBatchBookOfferings;

  /// Directs student to increase balance when deficit is detected.
  final void Function(int deficitRial, {List<MealRow>? pendingRows})? onTopUp;

  /// Directs student to increase balance with specific meal offerings pending.
  final void Function(int deficitRial, List<MealOffering> pendingOfferings)? onTopUpOfferings;

  /// Re-reads the portal.
  final VoidCallback? onRefresh;

  /// Called when the selected account for reservations changes.
  final void Function(AccountId accountId)? onAccountChanged;

  /// The portal's menu for the days that can still be booked.
  final List<MealMenu> menus;

  /// The server's clock, for the cutoff.
  final ServerClock? clock;

  /// Whether an action is in flight.
  final bool busy;

  /// The (date, slot) the in-flight action belongs to.
  final String? busyKey;

  @override
  State<ReservationsScreen> createState() => _ReservationsScreenState();
}

class _ReservationsScreenState extends State<ReservationsScreen> {
  /// Offset in weeks from the current week (0 = current week, 1 = next week, -1 = last week).
  /// Navigation is unconstrained: tapping next week or previous week advances or rewinds freely.
  int _weekOffset = 0;

  @override
  void initState() {
    super.initState();
    _checkInitialState();
  }

  @override
  void didUpdateWidget(ReservationsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _checkInitialState();
  }

  void _checkInitialState() {
    if (_weekOffset == 0 && widget.menus.isNotEmpty) {
      final currentSat = _currentSaturday();
      final accountId = widget.state.selectedReservationsAccountId ??
          (widget.state.accounts.isNotEmpty ? widget.state.accounts.first.id : null);
      if (accountId != null) {
        final allRows = buildMealRows(
          menus: widget.menus,
          held: widget.state.mealsFor(accountId),
          clock: widget.clock,
          isListedInBasket: (date, slot) => widget.state.isListedInBasket(accountId, date, slot),
          receiptCodeFor: (date, slot) => widget.state.receiptCodeFor(accountId, date, slot),
        );
        final currentWeekRows = filterRowsForWeek(allRows, currentSat);
        final nextSat = currentSat.add(const Duration(days: 7));
        final nextWeekRows = filterRowsForWeek(allRows, nextSat);

        final currentBookableCount = currentWeekRows.where((r) => r.status == MealRowStatus.bookable).length;
        final nextBookableCount = nextWeekRows.where((r) => r.status == MealRowStatus.bookable).length;

        if (currentBookableCount == 0 && nextBookableCount > 0) {
          _weekOffset = 1;
        }
      }
    }
  }


  final Map<AccountId, bool> _selectionModes = {};
  final Map<AccountId, Map<String, MealRow>> _selectedRowsPerAccount = {};

  bool _isSelectionModeFor(AccountId accountId) =>
      _selectionModes[accountId] ?? false;

  Map<String, MealRow> _selectedRowsFor(AccountId accountId) =>
      _selectedRowsPerAccount.putIfAbsent(
          accountId, () => <String, MealRow>{});

  void _toggleSelect(AccountId accountId, MealRow row) {
    final key =
        '${row.date.year}-${row.date.month}-${row.date.day}|${row.slot.name}';
    final rows = _selectedRowsFor(accountId);
    setState(() {
      if (rows.containsKey(key)) {
        rows.remove(key);
      } else {
        rows[key] = row;
      }
    });
  }

  void _clearSelectionFor(AccountId accountId) {
    _selectionModes[accountId] = false;
    _selectedRowsPerAccount[accountId]?.clear();
  }

  DateTime _currentSaturday() {
    final now = widget.clock != null && widget.clock!.isSynced
        ? widget.clock!.portalTodayUtc
        : DateTime.now().toUtc();
    return weekStartSaturday(now);
  }

  DateTime _selectedSaturday() {
    final currentSat = _currentSaturday();
    return currentSat.add(Duration(days: _weekOffset * 7));
  }

  void _previousWeek() {
    setState(() {
      _weekOffset--;
    });
  }

  void _nextWeek() {
    setState(() {
      _weekOffset++;
    });
  }

  void _resetToCurrentWeek() {
    setState(() {
      _weekOffset = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final accounts = widget.state.accounts;

        if (accounts.isEmpty) {
          return Scaffold(
            appBar: AppBar(title: const Text('رزروها')),
            body: const EmptyState(
              icon: Icons.people_outline,
              title: 'هنوز حسابی اضافه نشده است',
              message: 'برای دیدن رزروها، ابتدا یک حساب اضافه کنید.',
            ),
          );
        }

        final accountId = widget.state.selectedReservationsAccountId ?? accounts.first.id;
        final allRows = buildMealRows(
          menus: widget.menus,
          held: widget.state.mealsFor(accountId),
          clock: widget.clock,
          isListedInBasket: (date, slot) => widget.state.isListedInBasket(accountId, date, slot),
          receiptCodeFor: (date, slot) => widget.state.receiptCodeFor(accountId, date, slot),
        );

        final currentSat = _currentSaturday();
        final currentWeekRows = filterRowsForWeek(allRows, currentSat);
        final nextSat = currentSat.add(const Duration(days: 7));
        final nextWeekRows = filterRowsForWeek(allRows, nextSat);

        final currentBookableCount = currentWeekRows.where((r) => r.status == MealRowStatus.bookable).length;
        final nextBookableCount = nextWeekRows.where((r) => r.status == MealRowStatus.bookable).length;



        final selectedSat = _selectedSaturday();
        final weekRows = filterRowsForWeek(allRows, selectedSat);

        return Scaffold(
          appBar: AppBar(
            title: const Text('رزروها'),
            actions: [
              if (weekRows.any((r) => r.status == MealRowStatus.bookable) ||
                  _isSelectionModeFor(accountId))
                IconButton(
                  icon: Icon(_isSelectionModeFor(accountId)
                      ? Icons.close
                      : Icons.checklist_rtl),
                  tooltip: _isSelectionModeFor(accountId)
                      ? 'انصراف از انتخاب چندگانه'
                      : 'انتخاب چند وعده',
                  onPressed: () {
                    setState(() {
                      final current = _selectionModes[accountId] ?? false;
                      _selectionModes[accountId] = !current;
                      if (current) {
                        _selectedRowsPerAccount[accountId]?.clear();
                      }
                    });
                  },
                ),
              if (widget.onRefresh != null)
                RotatingRefreshButton(
                  isSyncing: widget.state.isSyncing,
                  onPressed: widget.onRefresh,
                ),
            ],
          ),
          body: Column(
            children: [
              if (accounts.length > 1)
                _AccountPicker(
                  accounts: accounts,
                  activeId: accountId,
                  balanceFor: (id) => widget.state.balanceFor(id),
                  selectedCountFor: (id) =>
                      _selectedRowsPerAccount[id]?.length ?? 0,
                  onChanged: (id) {
                    widget.state.selectReservationsAccount(id);
                    if (widget.onAccountChanged != null) {
                      widget.onAccountChanged!(id);
                    } else {
                      widget.onRefresh?.call();
                    }
                  },
                )
              else if (accounts.length == 1 && widget.state.balanceFor(accountId) != null)
                _SingleAccountBalanceBar(
                  balanceRial: widget.state.balanceFor(accountId)!,
                  onTopUp: widget.onTopUp != null ? () => widget.onTopUp!(0) : null,
                ),
              _WeekNavigator(
                weekOffset: _weekOffset,
                saturday: selectedSat,
                onPrevious: _previousWeek,
                onNext: _nextWeek,
                onReset: _resetToCurrentWeek,
                onSelectOffset: (offset) => setState(() => _weekOffset = offset),
                nextBookableCount: nextBookableCount,
              ),
              if (_weekOffset == 0 && currentBookableCount == 0 && nextBookableCount > 0)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.event_available, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${toPersianDigits(nextBookableCount)} وعده غذایی در «هفته بعد» باز و قابل رزرو است.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.onPrimaryContainer,
                              ),
                        ),
                      ),
                      FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        onPressed: () => setState(() => _weekOffset = 1),
                        child: const Text('مشاهده و رزرو'),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: ReservationsTable(
                  rows: weekRows,
                  busy: widget.busy,
                  busyKey: widget.busyKey,
                  emptyTitle: _weekOffset < 0
                      ? 'هیچ رزروی در این هفته ثبت نشده است'
                      : (_weekOffset > 1
                          ? 'برنامه غذایی این هفته هنوز ارائه نشده است'
                          : 'هنوز وعده‌ای برای نمایش نیست'),
                  emptyMessage: _weekOffset < 0
                      ? 'در این هفته هیچ وعده رزروشده یا خریداری‌شده‌ای برای این حساب وجود ندارد.'
                      : (_weekOffset > 1
                          ? 'سامانه دانشگاه معمولاً برنامه غذایی را حداکثر تا یک هفته قبل ارائه می‌دهد.'
                          : 'پس از دریافت برنامه غذایی یا رزرو، وعده‌ها اینجا نمایش داده می‌شوند.'),
                  onBook: (date, slot) => widget.onBook?.call(date, slot),
                  onCancel: (date, slot) => widget.onCancel?.call(date, slot),
                  onSell: widget.onSell != null ? (date, slot) => widget.onSell!(date, slot) : null,
                  onRemoveFromSell: widget.onRemoveFromSell != null
                      ? (date, slot) => widget.onRemoveFromSell!(date, slot)
                      : null,
                  onForgotReceipt: widget.onForgotReceipt != null
                      ? (date, slot, dishName, reserveType) => widget.onForgotReceipt!(date, slot, dishName, reserveType)
                      : null,
                  onMealDetails: widget.onMealDetails,
                  selectionMode: _isSelectionModeFor(accountId),
                  selectedKeys: _selectedRowsFor(accountId).keys.toSet(),
                  onToggleSelect: (row) => _toggleSelect(accountId, row),
                  emptyAction: (widget.menus.isEmpty && widget.onRefresh != null)
                      ? Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: FilledButton.icon(
                            onPressed: widget.state.isSyncing ? null : widget.onRefresh,
                            icon: const Icon(Icons.refresh),
                            label: const Text('دریافت برنامه غذایی دانشگاه'),
                          ),
                        )
                      : null,
                ),
              ),
              if (_isSelectionModeFor(accountId) &&
                  _selectedRowsFor(accountId).isNotEmpty)
                _MultiSelectSummaryBar(
                  selectedCount: _selectedRowsFor(accountId).length,
                  totalPriceRial: _selectedRowsFor(accountId)
                      .values
                      .fold<int>(0, (sum, r) => sum + (r.priceRial ?? 0)),
                  balanceRial: widget.state.balanceFor(accountId) ?? 0,
                  onTopUp: (deficit) {
                    final rows = _selectedRowsFor(accountId).values.toList();
                    widget.onTopUp?.call(
                      deficit,
                      pendingRows: rows,
                    );
                    if (mounted) {
                      setState(() {
                        _clearSelectionFor(accountId);
                      });
                    }
                  },
                  onConfirmReserve: () {
                    final account = accounts.firstWhere((a) => a.id == accountId);
                    final rowsToBook =
                        _selectedRowsFor(accountId).values.toList();
                    BatchBookingSheet.show(
                      context,
                      menus: widget.menus,
                      selectedRows: rowsToBook,
                      accountName: account.resolvedName,
                      currentBalanceRial: widget.state.balanceFor(accountId),
                      onConfirm: (offerings) async {
                        dynamic result;
                        if (widget.onBatchBookOfferings != null) {
                          result = await widget.onBatchBookOfferings!(offerings);
                        } else if (widget.onBatchBook != null) {
                          result = await widget.onBatchBook!(rowsToBook);
                        } else {
                          for (final off in offerings) {
                            widget.onBook?.call(off.date, off.slot);
                          }
                          result = true;
                        }
                        final failed = result is bool && !result;
                        if (mounted && !failed) {
                          setState(() {
                            _clearSelectionFor(accountId);
                          });
                        }
                      },
                      onTopUp: (deficit, offerings) {
                        if (widget.onTopUpOfferings != null) {
                          widget.onTopUpOfferings!(deficit, offerings);
                        } else {
                          widget.onTopUp?.call(
                            deficit,
                            pendingRows: rowsToBook,
                          );
                        }
                        if (mounted) {
                          setState(() {
                            _clearSelectionFor(accountId);
                          });
                        }
                      },
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Navigation bar allowing unconstrained forward/backward week paging
/// while showing the Persian week label and Jalali date range.
class _WeekNavigator extends StatelessWidget {
  const _WeekNavigator({
    required this.weekOffset,
    required this.saturday,
    required this.onPrevious,
    required this.onNext,
    required this.onReset,
    this.onSelectOffset,
    this.nextBookableCount = 0,
  });

  final int weekOffset;
  final DateTime saturday;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onReset;
  final void Function(int offset)? onSelectOffset;
  final int nextBookableCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final weekTitle = formatWeekTitle(weekOffset);
    final weekRange = formatWeekRange(saturday);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          // In Persian RTL: Next Week (future) progresses towards start/left.
          // Arrow forward is Icons.arrow_back in RTL, or chevron.
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: 'هفته قبل',
            onPressed: onPrevious,
          ),
          Expanded(
            child: InkWell(
              onTap: weekOffset != 0 ? onReset : null,
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
                            color: weekOffset == 0
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                        if (weekOffset != 0) ...[
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
                              'بازگشت به امروز',
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
            onPressed: onNext,
          ),
        ],
      ),
    );
  }
}


/// The row of chips that picks the account the table shows.
class _AccountPicker extends StatelessWidget {
  const _AccountPicker({
    required this.accounts,
    required this.activeId,
    required this.onChanged,
    this.balanceFor,
    this.selectedCountFor,
  });

  final List<SavedAccount> accounts;
  final AccountId activeId;
  final void Function(AccountId) onChanged;
  final int? Function(AccountId)? balanceFor;
  final int Function(AccountId)? selectedCountFor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.switch_account_outlined,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                'رزرو برای حساب:',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final account in accounts) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Builder(
                      builder: (context) {
                        final count = selectedCountFor?.call(account.id) ?? 0;
                        final countBadge = count > 0 ? ' (${toPersianDigits(count)})' : '';
                        final balance = balanceFor?.call(account.id);
                        final labelText = balance != null
                            ? '${account.resolvedName}$countBadge • ${formatTomanPersian(balance)}'
                            : '${account.resolvedName}$countBadge';

                        return ChoiceChip(
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
                          label: Text(labelText),
                          selected: account.id == activeId,
                          onSelected: (selected) {
                            if (selected) onChanged(account.id);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}


/// Persistent bottom summary when multiple meals are selected for reservation.
class _MultiSelectSummaryBar extends StatelessWidget {
  const _MultiSelectSummaryBar({
    required this.selectedCount,
    required this.totalPriceRial,
    required this.balanceRial,
    this.onTopUp,
    required this.onConfirmReserve,
  });

  final int selectedCount;
  final int totalPriceRial;
  final int balanceRial;
  final void Function(int deficitRial)? onTopUp;
  final VoidCallback onConfirmReserve;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deficitRial = totalPriceRial - balanceRial;
    final hasDeficit = deficitRial > 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            offset: const Offset(0, -2),
            blurRadius: 8,
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${toPersianDigits(selectedCount)} وعده انتخاب شده',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                Text(
                  'مجموع: ${formatTomanPersian(totalPriceRial)}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'موجودی حساب:',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                Text(
                  formatTomanPersian(balanceRial),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
            if (hasDeficit) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, size: 18, color: theme.colorScheme.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'کسری موجودی: ${formatTomanPersian(deficitRial)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onConfirmReserve,
                      icon: const Icon(Icons.tune, size: 16),
                      label: const Text('انتخاب نوع غذا و سلف'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onTopUp != null ? () => onTopUp!(deficitRial) : null,
                      icon: const Icon(Icons.account_balance_wallet_outlined, size: 18),
                      label: Text('شارژ حساب (${formatTomanPersian(deficitRial)})'),
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: onConfirmReserve,
                icon: const Icon(Icons.tune),
                label: Text('انتخاب نوع غذا و سلف (${toPersianDigits(selectedCount)} وعده)'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A compact real-time balance indicator when exactly one account exists.
class _SingleAccountBalanceBar extends StatelessWidget {
  const _SingleAccountBalanceBar({
    required this.balanceRial,
    this.onTopUp,
  });

  final int balanceRial;
  final VoidCallback? onTopUp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(
                Icons.account_balance_wallet_outlined,
                size: 16,
                color: theme.colorScheme.secondary,
              ),
              const SizedBox(width: 6),
              Text(
                'اعتبار: ${formatTomanPersian(balanceRial)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.secondary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          if (onTopUp != null)
            TextButton.icon(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: onTopUp,
              icon: const Icon(Icons.add, size: 14),
              label: const Text('افزایش اعتبار', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
