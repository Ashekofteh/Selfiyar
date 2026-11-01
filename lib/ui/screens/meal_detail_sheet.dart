/// The meal detail and edit bottom sheet.
///
/// ## What it shows
///
/// When the student taps any meal in the reservations table, this sheet opens
/// from the bottom and displays:
///   * The full, untruncated dish name (including side items and accompaniments).
///   * The dining hall (سلف) where the meal was reserved.
///   * The date, meal slot, and current status (held, heldLocked, bought, etc.).
///   * If a receipt code was already issued, displays the code prominently with
///     a one-tap copy button.
///
/// ## In-place modification
///
/// If the date's reservation cutoff has NOT passed (`row.cancellable` and
/// `menu.reservable`):
///   * The student can switch between alternative dishes served for that slot.
///   * The student can switch between dining halls serving that slot.
///   * The price difference is computed and displayed dynamically.
///   * A "ذخیره تغییرات" button submits the update to the portal.
///
/// ## Quick actions
///
/// Direct access to receipt issuance, cancellation, or Food Basket sale/removal
/// without leaving the detail sheet.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/hunt_notify.dart' show mealSlotPersian;
import '../../core/models.dart';
import '../../core/persian.dart';
import '../reservation_table_model.dart';
import '../theme.dart';
import '../widgets.dart';

/// The bottom sheet displaying meal details and offering in-place modification.
class MealDetailSheet extends StatefulWidget {
  const MealDetailSheet({
    super.key,
    required this.row,
    this.menu,
    this.accountName,
    this.currentBalanceRial,
    this.onModify,
    this.onTopUp,
    this.onCancel,
    this.onSell,
    this.onRemoveFromSell,
    this.onForgotReceipt,
    this.busy = false,
  });

  /// The meal row being inspected.
  final MealRow row;

  /// The portal's menu for this (date, slot), when available.
  final MealMenu? menu;

  /// The account name holding this meal, if multi-account is present.
  final String? accountName;

  /// The student's current balance in Rial, for calculating price difference deficits.
  final int? currentBalanceRial;

  /// Submits the modified offering (dish and/or hall). Returns null on success or an error message.
  final Future<String?> Function(MealOffering offering)? onModify;

  /// Directs the student to top-up when a balance deficit is detected.
  final void Function(int deficitRial)? onTopUp;

  /// Quick action: cancels this weekly reservation.
  final VoidCallback? onCancel;

  /// Quick action: lists this meal for sale in the secondary Food Basket.
  final VoidCallback? onSell;

  /// Quick action: removes this meal from the secondary Food Basket sale.
  final VoidCallback? onRemoveFromSell;

  /// Quick action: requests or views the forgot-card receipt slip.
  final VoidCallback? onForgotReceipt;

  /// Whether an external action is in flight.
  final bool busy;

  /// Shows the sheet.
  static Future<void> show(
    BuildContext context, {
    required MealRow row,
    MealMenu? menu,
    String? accountName,
    int? currentBalanceRial,
    Future<String?> Function(MealOffering offering)? onModify,
    void Function(int deficitRial)? onTopUp,
    VoidCallback? onCancel,
    VoidCallback? onSell,
    VoidCallback? onRemoveFromSell,
    VoidCallback? onForgotReceipt,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => MealDetailSheet(
        row: row,
        menu: menu,
        accountName: accountName,
        currentBalanceRial: currentBalanceRial,
        onModify: onModify,
        onTopUp: onTopUp,
        onCancel: onCancel,
        onSell: onSell,
        onRemoveFromSell: onRemoveFromSell,
        onForgotReceipt: onForgotReceipt,
      ),
    );
  }

  @override
  State<MealDetailSheet> createState() => _MealDetailSheetState();
}

class _MealDetailSheetState extends State<MealDetailSheet> {
  OptionId? _selectedDishId;
  HallId? _selectedHallId;
  OptionId? _initialDishId;
  HallId? _initialHallId;

  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _resolveInitialSelection();
  }

  void _resolveInitialSelection() {
    final menu = widget.menu;
    if (menu == null) return;

    // Match initial dish
    if (widget.row.dishName != null && menu.dishes.isNotEmpty) {
      final normalizedRowDish = _normalize(widget.row.dishName!);
      final match = menu.dishes.cast<MenuOption?>().firstWhere(
            (d) =>
                d != null &&
                (_normalize(d.name) == normalizedRowDish ||
                    normalizedRowDish.contains(_normalize(d.name)) ||
                    _normalize(d.name).contains(normalizedRowDish)),
            orElse: () => null,
          );
      _initialDishId = match?.id ?? menu.dishes.first.id;
    } else if (menu.dishes.isNotEmpty) {
      _initialDishId = menu.dishes.first.id;
    }
    _selectedDishId = _initialDishId;

    // Match initial hall
    if (widget.row.hallName != null && menu.halls.isNotEmpty) {
      final normalizedRowHall = _normalize(widget.row.hallName!);
      final match = menu.halls.cast<Hall?>().firstWhere(
            (h) =>
                h != null &&
                (_normalize(h.name) == normalizedRowHall ||
                    normalizedRowHall.contains(_normalize(h.name)) ||
                    _normalize(h.name).contains(normalizedRowHall)),
            orElse: () => null,
          );
      _initialHallId = match?.id ?? menu.halls.first.id;
    } else if (menu.halls.isNotEmpty) {
      _initialHallId = menu.halls.first.id;
    }
    _selectedHallId = _initialHallId;
  }

  static String _normalize(String input) => input
      .replaceAll('ي', 'ی')
      .replaceAll('ك', 'ک')
      .replaceAll(' ', '')
      .trim();

  bool get _canEdit =>
      widget.row.cancellable &&
      widget.menu != null &&
      widget.menu!.reservable &&
      widget.onModify != null &&
      !widget.row.isConsumed &&
      !widget.row.isDistributionPassed;

  bool get _isModified =>
      (_selectedDishId != null && _selectedDishId != _initialDishId) ||
      (_selectedHallId != null && _selectedHallId != _initialHallId);

  MenuOption? get _currentDish {
    if (widget.menu == null) return null;
    return widget.menu!.dishes.cast<MenuOption?>().firstWhere(
          (d) => d?.id == _selectedDishId,
          orElse: () => null,
        );
  }

  Hall? get _currentHall {
    if (widget.menu == null) return null;
    return widget.menu!.halls.cast<Hall?>().firstWhere(
          (h) => h?.id == _selectedHallId,
          orElse: () => null,
        );
  }

  int get _initialPrice =>
      widget.row.priceRial ??
      (widget.menu?.dishes
              .cast<MenuOption?>()
              .firstWhere((d) => d?.id == _initialDishId, orElse: () => null)
              ?.priceRial ??
          0);

  int get _priceDiff {
    final newPrice = _currentDish?.priceRial ?? _initialPrice;
    return newPrice - _initialPrice;
  }

  int? get _deficitRial {
    if (_priceDiff <= 0 || widget.currentBalanceRial == null) return null;
    final deficit = _priceDiff - widget.currentBalanceRial!;
    return deficit > 0 ? deficit : null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = widget.row;
    final menu = widget.menu;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildHeader(theme),
                const SizedBox(height: 16),
                if (_error != null) ...[
                  _buildErrorBox(theme, _error!),
                  const SizedBox(height: 14),
                ],
                _buildCurrentMealCard(theme),
                if (row.hasReceipt) ...[
                  const SizedBox(height: 12),
                  _buildReceiptCard(theme),
                ],
                const SizedBox(height: 14),
                if (!_canEdit) ...[
                  _buildLockExplanationCard(theme),
                ] else if (menu != null) ...[
                  _buildEditSection(theme, menu),
                ],
                const SizedBox(height: 16),
                _buildQuickActions(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Row(
            children: [
              _SlotBadge(slot: widget.row.slot, status: widget.row.status),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${mealSlotPersian(widget.row.slot)} — ${formatPersianDateWithYear(widget.row.date)}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        _StatusBadge(status: widget.row.status),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (widget.accountName != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.person, size: 14, color: theme.colorScheme.primary),
                const SizedBox(width: 4),
                Text(
                  widget.accountName!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCurrentMealCard(ThemeData theme) {
    final dishTitle = widget.row.dishName ?? 'غذای رزرو شده';
    final hallName = widget.row.hallName ?? 'سلف مشخص نشده';
    final price = widget.row.priceRial;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.restaurant_menu,
                  size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  dishTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
              ),
              if (price != null) ...[
                const SizedBox(width: 8),
                MoneyText(
                  price,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.storefront_outlined,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'سلف توزیع: $hallName',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildReceiptCard(ThemeData theme) {
    final code = widget.row.receiptCode!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.receipt_long, color: theme.colorScheme.primary, size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'کد فیش فراموشی صادر شده',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                Text(
                  toPersianDigits(code),
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
              ],
            ),
          ),
          IconButton.filledTonal(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('کد فیش در حافظه کپی شد.'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            icon: const Icon(Icons.copy, size: 18),
            tooltip: 'کپی کد فیش',
          ),
        ],
      ),
    );
  }

  Widget _buildLockExplanationCard(ThemeData theme) {
    final row = widget.row;
    final (icon, message, color) = switch (row.status) {
      MealRowStatus.consumed => (
          Icons.check_circle_outline,
          'این وعده در سلف دانشگاه تحویل گرفته شده (صرف شده) و پرونده آن بسته شده است.',
          Colors.teal,
        ),
      MealRowStatus.bought => (
          Icons.shopping_bag_outlined,
          'این غذا از سبد غذایی خریداری شده است و قوانین سلف امکان لغو یا تغییر آن را نمی‌دهد.',
          theme.colorScheme.secondary,
        ),
      MealRowStatus.listedInBasket => (
          Icons.storefront_outlined,
          'این غذا در سبد غذایی برای فروش قرار داده شده است.',
          Colors.orange.shade800,
        ),
      _ => (
          Icons.lock_clock_outlined,
          'مهلت رزرو، ویرایش یا لغو این تاریخ به پایان رسیده است.',
          theme.colorScheme.outline,
        ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditSection(ThemeData theme, MealMenu menu) {
    final hasMultipleDishes = menu.dishes.length > 1;
    final hasMultipleHalls = menu.halls.length > 1;

    if (!hasMultipleDishes && !hasMultipleHalls) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          'برای این وعده تنها همین غذا و سلف در برنامه دانشگاه تعریف شده است.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 24),
        Row(
          children: [
            Icon(Icons.edit_note, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Text(
              'تغییر نوع غذا یا سلف توزیع',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (hasMultipleDishes) ...[
          Text(
            'انتخاب غذا:',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          RadioGroup<String>(
            groupValue: _selectedDishId,
            onChanged: (v) {
              if (v != null) setState(() => _selectedDishId = v);
            },
            child: Column(
              children: [
                for (final dish in menu.dishes)
                  RadioListTile<String>(
                    value: dish.id,
                    title: Text(
                      dish.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: _selectedDishId == dish.id
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    subtitle: Row(
                      children: [
                        MoneyText(
                          dish.priceRial,
                          style: theme.textTheme.bodySmall,
                          colour: theme.colorScheme.onSurfaceVariant,
                        ),
                        if (_initialDishId != null && dish.id != _initialDishId) ...[
                          const SizedBox(width: 8),
                          _buildPriceDiffBadge(theme, dish.priceRial - _initialPrice),
                        ],
                      ],
                    ),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
              ],
            ),
          ),
        ],
        if (hasMultipleHalls) ...[
          const SizedBox(height: 10),
          Text(
            'انتخاب سلف توزیع:',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          RadioGroup<String>(
            groupValue: _selectedHallId,
            onChanged: (v) {
              if (v != null) setState(() => _selectedHallId = v);
            },
            child: Column(
              children: [
                for (final hall in menu.halls)
                  RadioListTile<String>(
                    value: hall.id,
                    title: Text(
                      hall.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: _selectedHallId == hall.id
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
              ],
            ),
          ),
        ],
        if (_isModified) ...[
          const SizedBox(height: 12),
          _buildModificationSummary(theme),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_saving || widget.busy) ? null : _submitModification,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
              label: Text(_saving ? 'در حال ذخیره...' : 'ذخیره تغییرات'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildPriceDiffBadge(ThemeData theme, int diffRial) {
    if (diffRial == 0) return const SizedBox.shrink();
    final isIncrease = diffRial > 0;
    final color = isIncrease ? theme.colorScheme.error : Colors.teal;
    final text = isIncrease
        ? '+${formatTomanPersian(diffRial)}'
        : '-${formatTomanPersian(-diffRial)}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 10,
        ),
      ),
    );
  }

  Widget _buildModificationSummary(ThemeData theme) {
    final deficit = _deficitRial;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: (deficit != null)
            ? theme.colorScheme.errorContainer.withValues(alpha: 0.5)
            : theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                deficit != null
                    ? Icons.warning_amber_rounded
                    : Icons.info_outline,
                size: 18,
                color: deficit != null
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _priceDiff > 0
                      ? 'مابه‌التفاوت این تغییر: +${formatTomanPersian(_priceDiff)} (کسر از اعتبار)'
                      : (_priceDiff < 0
                          ? 'مابه‌التفاوت این تغییر: ${formatTomanPersian(-_priceDiff)} به حسابتان بازگردانده می‌شود.'
                          : 'قیمت دو غذا برابر است و هزینه‌ای کسر یا اضافه نمی‌شود.'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (deficit != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'کسری موجودی: ${formatTomanPersian(deficit)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (widget.onTopUp != null)
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onTopUp!(deficit);
                    },
                    child: const Text('افزایش موجودی'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildQuickActions(ThemeData theme) {
    final row = widget.row;
    final actions = <Widget>[];

    // Receipt button
    if (widget.onForgotReceipt != null &&
        !row.isConsumed &&
        !row.isDistributionPassed &&
        row.status != MealRowStatus.listedInBasket) {
      actions.add(
        OutlinedButton.icon(
          onPressed: () {
            Navigator.of(context).pop();
            widget.onForgotReceipt!();
          },
          icon: Icon(row.hasReceipt ? Icons.receipt : Icons.receipt_long, size: 18),
          label: Text(row.hasReceipt ? 'نمایش فیش' : 'دریافت فیش فراموشی'),
        ),
      );
    }

    // Cancel weekly reservation
    if (row.cancellable && widget.onCancel != null) {
      actions.add(
        OutlinedButton.icon(
          onPressed: () {
            Navigator.of(context).pop();
            widget.onCancel!();
          },
          icon: const Icon(Icons.close, size: 18),
          label: const Text('لغو این رزرو'),
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.error,
            side: BorderSide(color: theme.colorScheme.error.withValues(alpha: 0.5)),
          ),
        ),
      );
    }

    // Sell to basket
    if (row.status == MealRowStatus.heldLocked &&
        widget.onSell != null &&
        !row.isConsumed &&
        !row.isDistributionPassed) {
      actions.add(
        OutlinedButton.icon(
          onPressed: () {
            Navigator.of(context).pop();
            widget.onSell!();
          },
          icon: const Icon(Icons.shopping_basket_outlined, size: 18),
          label: const Text('فروش در سبد غذایی'),
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.primary,
          ),
        ),
      );
    }

    // Remove from basket sale
    if (row.status == MealRowStatus.listedInBasket &&
        widget.onRemoveFromSell != null) {
      actions.add(
        OutlinedButton.icon(
          onPressed: () {
            Navigator.of(context).pop();
            widget.onRemoveFromSell!();
          },
          icon: const Icon(Icons.remove_shopping_cart_outlined, size: 18),
          label: const Text('انصراف از فروش در سبد'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.orange.shade800,
            side: BorderSide(color: Colors.orange.shade800.withValues(alpha: 0.5)),
          ),
        ),
      );
    }

    if (actions.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 20),
        Text(
          'عملیات سریع:',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: actions,
        ),
      ],
    );
  }

  Widget _buildErrorBox(ThemeData theme, String error) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: theme.colorScheme.errorContainer,
      ),
      child: Text(
        error,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onErrorContainer,
        ),
      ),
    );
  }

  Future<void> _submitModification() async {
    final menu = widget.menu;
    final dish = _currentDish;
    final hall = _currentHall;
    if (menu == null || dish == null || hall == null) return;

    final deficit = _deficitRial;
    if (deficit != null && widget.onTopUp != null) {
      final goToTopUp = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('کمبود موجودی حساب'),
          content: Text(
            'موجودی حساب برای پرداخت مابه‌التفاوت این غذا کافی نیست.\n'
            'کسری موجودی: ${formatTomanPersian(deficit)}\n\n'
            'آیا مایلید برای افزایش اعتبار به صفحه پرداخت هدایت شوید؟',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('انصراف'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('افزایش موجودی'),
            ),
          ],
        ),
      );

      if (goToTopUp == true && mounted) {
        Navigator.of(context).pop();
        widget.onTopUp!(deficit);
        return;
      }
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final offering = MealOffering(
      date: menu.date,
      slot: menu.slot,
      hall: hall,
      option: dish,
      reservable: menu.reservable,
    );

    final error = await widget.onModify?.call(offering);

    if (!mounted) return;

    if (error == null) {
      Navigator.of(context).pop();
      return;
    }

    setState(() {
      _saving = false;
      _error = error;
    });
  }
}

/// The slot badge matching the main table.
class _SlotBadge extends StatelessWidget {
  const _SlotBadge({required this.slot, required this.status});

  final MealSlot slot;
  final MealRowStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = switch (status) {
      MealRowStatus.consumed => Colors.teal,
      MealRowStatus.held || MealRowStatus.bought => AppColors.heldOf(context),
      MealRowStatus.bookable => theme.colorScheme.secondary,
      MealRowStatus.listedInBasket => Colors.orange.shade800,
      MealRowStatus.locked || MealRowStatus.heldLocked =>
        theme.colorScheme.outline,
    };

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        status == MealRowStatus.consumed
            ? Icons.restaurant
            : switch (slot) {
                MealSlot.breakfast => Icons.wb_twilight,
                MealSlot.lunch => Icons.lunch_dining_outlined,
                MealSlot.dinner => Icons.dark_mode_outlined,
              },
        size: 20,
        color: colour,
      ),
    );
  }
}

/// The status chip badge.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final MealRowStatus status;

  static String _statusLabel(MealRowStatus status) => switch (status) {
        MealRowStatus.held => 'رزرو شده (قابل ویرایش)',
        MealRowStatus.heldLocked => 'رزرو شده (مهلت ویرایش گذشته)',
        MealRowStatus.listedInBasket => 'در سبد فروش',
        MealRowStatus.bought => 'خریداری شده از سبد',
        MealRowStatus.bookable => 'قابل رزرو',
        MealRowStatus.locked => 'مهلت گذشته',
        MealRowStatus.consumed => 'تحویل شده (خورده شده)',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = switch (status) {
      MealRowStatus.consumed => Colors.teal,
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
