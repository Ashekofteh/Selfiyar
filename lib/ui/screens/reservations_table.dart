/// The reservations table.
///
/// ## What it shows
///
/// One grid, one row per (date, meal) across the days the student can still
/// act on. A row states one thing plainly — **what is the state of this
/// meal** — and offers exactly one action, so the student never has to read a
/// form to know what tapping will do.
///
/// The rows come from [buildMealRows], which merges the portal's menu, the
/// local mirror and the server's clock. The table itself draws them.
///
/// ## Why a table and not a list of cards
///
/// The portal's own page is a table: three grids of seven rows. The student
/// is used to reading it that way, and a table makes the **shape** of the
/// week legible — which days are full, which are open, which are gone.
library;

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/persian.dart';
import '../../core/portal.dart';
import '../theme.dart';
import '../widgets.dart';
import '../reservation_table_model.dart';

/// The reservations table.
class ReservationsTable extends StatelessWidget {
  const ReservationsTable({
    super.key,
    required this.rows,
    required this.onBook,
    required this.onCancel,
    this.onSell,
    this.onRemoveFromSell,
    this.onForgotReceipt,
    this.selectionMode = false,
    this.selectedKeys = const {},
    this.onToggleSelect,
    this.busy = false,
    this.busyKey,
    this.emptyTitle = 'هنوز وعده‌ای برای نمایش نیست',
    this.emptyMessage = 'پس از رزرو یا خرید، وعده‌های شما اینجا فهرست می‌شوند.',
    this.emptyAction,
  });

  /// The rows, in date order then meal order.
  final List<MealRow> rows;

  /// Books a meal. Called with the (date, slot) the student tapped.
  final void Function(DateTime date, MealSlot slot) onBook;

  /// Cancels a held meal.
  final void Function(DateTime date, MealSlot slot) onCancel;

  /// Lists a held meal for sale in the secondary Food Basket.
  final void Function(DateTime date, MealSlot slot)? onSell;

  /// Removes a listed meal from the secondary Food Basket sale.
  final void Function(DateTime date, MealSlot slot)? onRemoveFromSell;

  /// Requests a forgot receipt for a held meal.
  final void Function(DateTime date, MealSlot slot, String? dishName, ReserveType reserveType)? onForgotReceipt;

  /// Whether multi-selection mode is active.
  final bool selectionMode;

  /// The keys of the selected rows in multi-selection mode.
  final Set<String> selectedKeys;

  /// Toggles selection of a row in multi-selection mode.
  final void Function(MealRow row)? onToggleSelect;

  /// Whether an action is in flight.
  final bool busy;

  /// The (date, slot) the in-flight action belongs to, if any.
  final String? busyKey;

  /// Custom empty state title when this week has no rows.
  final String emptyTitle;

  /// Custom empty state message when this week has no rows.
  final String emptyMessage;

  /// Optional action button to show in the empty state.
  final Widget? emptyAction;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return EmptyState(
        icon: Icons.event_busy_outlined,
        title: emptyTitle,
        message: emptyMessage,
        action: emptyAction,
      );
    }

    // Group the rows by day, so the table reads as a week.
    final days = <DateTime, List<MealRow>>{};
    for (final row in rows) {
      days.putIfAbsent(row.date, () => []).add(row);
    }
    final dates = days.keys.toList()..sort();

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        for (final date in dates) ...[
          _DayHeader(date: date, meals: days[date]!),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: Column(
                children: [
                  for (final row in days[date]!) ...[
                    _MealRowTile(
                      row: row,
                      busy: busy && busyKey == _keyOf(row),
                      onBook: () => onBook(row.date, row.slot),
                      onCancel: () => onCancel(row.date, row.slot),
                      onSell: onSell != null ? () => onSell!(row.date, row.slot) : null,
                      onRemoveFromSell: onRemoveFromSell != null ? () => onRemoveFromSell!(row.date, row.slot) : null,
                      onForgotReceipt: onForgotReceipt != null ? () => onForgotReceipt!(row.date, row.slot, row.dishName, row.status == MealRowStatus.bought ? ReserveType.foodBasket : ReserveType.weekly) : null,
                      selectionMode: selectionMode,
                      isSelected: selectedKeys.contains(_keyOf(row)),
                      onToggleSelect: onToggleSelect != null ? () => onToggleSelect!(row) : null,
                    ),
                    if (row != days[date]!.last) const Divider(height: 1),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  static String _keyOf(MealRow row) =>
      '${row.date.year}-${row.date.month}-${row.date.day}|${row.slot.name}';
}

/// The heading of one day.
class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.date, required this.meals});

  final DateTime date;
  final List<MealRow> meals;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final held = meals
        .where((m) => m.status == MealRowStatus.held ||
            m.status == MealRowStatus.heldLocked ||
            m.status == MealRowStatus.listedInBasket ||
            m.status == MealRowStatus.bought)
        .length;
    final open = meals
        .where((m) => m.status == MealRowStatus.bookable)
        .length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        children: [
          Text(
            formatPersianDateWithYear(date),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          _DayCount(
            label: '${toPersianDigits(held)} رزرو',
            colour: AppColors.heldOf(context),
          ),
          const SizedBox(width: 6),
          _DayCount(
            label: '${toPersianDigits(open)} باز',
            colour: theme.colorScheme.secondary,
          ),
        ],
      ),
    );
  }
}

/// A small count in the day heading.
class _DayCount extends StatelessWidget {
  const _DayCount({required this.label, required this.colour});

  final String label;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: colour,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// One meal's row.
class _MealRowTile extends StatelessWidget {
  const _MealRowTile({
    required this.row,
    required this.busy,
    required this.onBook,
    required this.onCancel,
    this.onSell,
    this.onRemoveFromSell,
    this.onForgotReceipt,
    this.selectionMode = false,
    this.isSelected = false,
    this.onToggleSelect,
  });

  final MealRow row;
  final bool busy;
  final VoidCallback onBook;
  final VoidCallback onCancel;
  final VoidCallback? onSell;
  final VoidCallback? onRemoveFromSell;
  final VoidCallback? onForgotReceipt;
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback? onToggleSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () {
        if (selectionMode && onToggleSelect != null) {
          if (row.status == MealRowStatus.bookable) {
            onToggleSelect!();
          }
        } else if (row.status == MealRowStatus.bookable) {
          onBook();
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _SlotBadge(slot: row.slot, status: row.status),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.status == MealRowStatus.bookable
                        ? 'منو: ${row.dishName ?? _bookableLabel(row)}'
                        : (row.dishName ?? _bookableLabel(row)),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      _StatusChip(status: row.status),
                      if (row.status == MealRowStatus.bookable && row.optionCount > 1) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '${toPersianDigits(row.optionCount)} نوع غذا',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSecondaryContainer,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                      if (row.hallName != null) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            row.hallName!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (row.priceRial != null)
              MoneyText(row.priceRial!, style: theme.textTheme.titleSmall),
            const SizedBox(width: 4),
            _Action(
              row: row,
              busy: busy,
              onBook: onBook,
              onCancel: onCancel,
              onSell: onSell,
              onRemoveFromSell: onRemoveFromSell,
              onForgotReceipt: onForgotReceipt,
              selectionMode: selectionMode,
              isSelected: isSelected,
              onToggleSelect: onToggleSelect,
            ),
          ],
        ),
      ),
    );
  }

  /// What a bookable row says instead of a dish name.
  static String _bookableLabel(MealRow row) {
    if (row.availableDishes.isNotEmpty) {
      return row.availableDishes.join(' یا ');
    }
    return row.optionCount > 1
        ? '${toPersianDigits(row.optionCount)} غذای موجود'
        : 'یک غذای موجود';
  }
}

/// The leading badge: the meal's slot, coloured by its state.
class _SlotBadge extends StatelessWidget {
  const _SlotBadge({required this.slot, required this.status});

  final MealSlot slot;
  final MealRowStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = switch (status) {
      MealRowStatus.held || MealRowStatus.bought => AppColors.heldOf(context),
      MealRowStatus.bookable => theme.colorScheme.secondary,
      MealRowStatus.listedInBasket => Colors.orange.shade800,
      MealRowStatus.locked || MealRowStatus.heldLocked =>
        theme.colorScheme.outline,
    };

    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Icon(
        switch (slot) {
          MealSlot.breakfast => Icons.wb_twilight,
          MealSlot.lunch => Icons.lunch_dining_outlined,
          MealSlot.dinner => Icons.dark_mode_outlined,
        },
        size: 19,
        color: colour,
      ),
    );
  }
}

/// The state of a meal, as a small chip.
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final MealRowStatus status;

  /// The state, in words.
  static String _statusLabel(MealRowStatus status) => switch (status) {
        MealRowStatus.held => 'رزرو شده',
        MealRowStatus.heldLocked => 'رزرو شده - مهلت گذشته',
        MealRowStatus.listedInBasket => 'در سبد فروش',
        MealRowStatus.bought => 'خریداری شده',
        MealRowStatus.bookable => 'قابل رزرو',
        MealRowStatus.locked => 'مهلت گذشته',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = switch (status) {
      MealRowStatus.held || MealRowStatus.bought => AppColors.heldOf(context),
      MealRowStatus.bookable => theme.colorScheme.secondary,
      MealRowStatus.listedInBasket => Colors.orange.shade800,
      MealRowStatus.locked || MealRowStatus.heldLocked =>
        theme.colorScheme.outline,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        _statusLabel(status),
        style: theme.textTheme.labelSmall?.copyWith(
          color: colour,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// The row's action: one button, one meaning.
class _Action extends StatelessWidget {
  const _Action({
    required this.row,
    required this.busy,
    required this.onBook,
    required this.onCancel,
    this.onSell,
    this.onRemoveFromSell,
    this.onForgotReceipt,
    this.selectionMode = false,
    this.isSelected = false,
    this.onToggleSelect,
  });

  final MealRow row;
  final bool busy;
  final VoidCallback onBook;
  final VoidCallback onCancel;
  final VoidCallback? onSell;
  final VoidCallback? onRemoveFromSell;
  final VoidCallback? onForgotReceipt;
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback? onToggleSelect;

  Widget _buildReceiptButton(ThemeData theme) {
    if (onForgotReceipt == null) return const SizedBox.shrink();
    if (row.hasReceipt) {
      return IconButton(
        onPressed: busy ? null : onForgotReceipt,
        icon: const Icon(Icons.receipt, size: 20),
        tooltip: 'مشاهده فیش صادر شده (کد: ${row.receiptCode})',
        visualDensity: VisualDensity.compact,
        style: IconButton.styleFrom(
          foregroundColor: theme.colorScheme.primary,
          backgroundColor: theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
        ),
      );
    }
    return IconButton(
      onPressed: busy ? null : onForgotReceipt,
      icon: const Icon(Icons.receipt_long, size: 20),
      tooltip: 'دریافت فیش فراموشی',
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        foregroundColor: theme.colorScheme.secondary,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    switch (row.status) {
      case MealRowStatus.held:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildReceiptButton(theme),
            IconButton(
              onPressed: busy ? null : onCancel,
              icon: const Icon(Icons.close),
              tooltip: 'لغو رزرو',
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                disabledForegroundColor: theme.colorScheme.outline,
              ),
            ),
          ],
        );

      case MealRowStatus.bought:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildReceiptButton(theme),
            Icon(
              Icons.lock_outline,
              size: 18,
              color: theme.colorScheme.outline,
            ),
          ],
        );

      case MealRowStatus.heldLocked:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildReceiptButton(theme),
            if (onSell != null)
              IconButton(
                onPressed: busy ? null : onSell,
                icon: const Icon(Icons.shopping_basket_outlined),
                tooltip: 'فروش در سبد غذایی',
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  foregroundColor: theme.colorScheme.primary,
                  disabledForegroundColor: theme.colorScheme.outline,
                ),
              )
            else
              Icon(
                Icons.lock_clock_outlined,
                size: 18,
                color: theme.colorScheme.outline,
              ),
          ],
        );

      case MealRowStatus.listedInBasket:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildReceiptButton(theme),
            if (onRemoveFromSell != null)
              IconButton(
                onPressed: busy ? null : onRemoveFromSell,
                icon: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(Icons.shopping_basket, size: 22),
                    Positioned(
                      right: -3,
                      bottom: -2,
                      child: Container(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.cancel,
                          size: 12,
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
                tooltip: 'در سبد فروش (حذف از سبد)',
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  foregroundColor: Colors.orange.shade800,
                  disabledForegroundColor: theme.colorScheme.outline,
                ),
              )
            else
              Icon(
                Icons.shopping_basket,
                size: 20,
                color: Colors.orange.shade800,
              ),
          ],
        );

      case MealRowStatus.bookable:
        if (selectionMode && onToggleSelect != null) {
          return Checkbox(
            value: isSelected,
            onChanged: busy ? null : (_) => onToggleSelect!(),
          );
        }
        return IconButton.filledTonal(
          onPressed: busy ? null : onBook,
          icon: busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add),
          tooltip: 'رزرو این وعده',
          visualDensity: VisualDensity.compact,
        );

      case MealRowStatus.locked:
        return Icon(
          Icons.lock_clock_outlined,
          size: 18,
          color: theme.colorScheme.outline,
        );
    }
  }
}
