import 'package:flutter/material.dart';
import '../theme.dart';

import '../../core/hunt_notify.dart' show mealSlotPersian;
import '../../core/models.dart';
import '../../core/persian.dart';
import '../reservation_table_model.dart';
import '../widgets.dart';

/// Bottom sheet for configuring and confirming batch reservations.
///
/// Allows the student to:
/// 1. Choose the dining hall (سلف) globally or per meal.
/// 2. Choose the desired dish for each meal (when multiple options exist).
/// 3. View the live financial summary and proceed to reserve or top-up.
class BatchBookingSheet extends StatefulWidget {
  const BatchBookingSheet({
    super.key,
    required this.menus,
    required this.selectedRows,
    required this.onConfirm,
    this.accountName,
    this.currentBalanceRial,
    this.onTopUp,
  });

  final List<MealMenu> menus;
  final List<MealRow> selectedRows;
  final Future<void> Function(List<MealOffering> offerings) onConfirm;
  final String? accountName;
  final int? currentBalanceRial;
  final void Function(int deficitRial, List<MealOffering> offerings)? onTopUp;

  static Future<void> show(
    BuildContext context, {
    required List<MealMenu> menus,
    required List<MealRow> selectedRows,
    required Future<void> Function(List<MealOffering> offerings) onConfirm,
    String? accountName,
    int? currentBalanceRial,
    void Function(int deficitRial, List<MealOffering> offerings)? onTopUp,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => BatchBookingSheet(
        menus: menus,
        selectedRows: selectedRows,
        onConfirm: onConfirm,
        accountName: accountName,
        currentBalanceRial: currentBalanceRial,
        onTopUp: onTopUp,
      ),
    );
  }

  @override
  State<BatchBookingSheet> createState() => _BatchBookingSheetState();
}

class _BatchBookingSheetState extends State<BatchBookingSheet> {
  final Map<String, MenuOption> _selectedOptions = {};
  final Map<String, Hall> _selectedHalls = {};
  Hall? _globalHall;
  bool _busy = false;

  late final List<MealRow> _orderedRows = List<MealRow>.from(widget.selectedRows)
    ..sort((a, b) {
      final aDate = DateTime.utc(a.date.year, a.date.month, a.date.day);
      final bDate = DateTime.utc(b.date.year, b.date.month, b.date.day);
      final dateCmp = aDate.compareTo(bDate);
      if (dateCmp != 0) return dateCmp;
      return a.slot.index.compareTo(b.slot.index);
    });

  String _key(DateTime date, MealSlot slot) =>
      '${date.year}-${date.month}-${date.day}|${slot.name}';

  MealMenu? _findMenu(MealRow row) {
    for (final m in widget.menus) {
      if (m.date.year == row.date.year &&
          m.date.month == row.date.month &&
          m.date.day == row.date.day &&
          m.slot == row.slot) {
        return m;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();

    // 1. Gather all unique halls across selected meals
    final hallsSeen = <String, Hall>{};
    for (final row in _orderedRows) {
      final menu = _findMenu(row);
      if (menu != null) {
        for (final h in menu.halls) {
          hallsSeen.putIfAbsent(h.id, () => h);
        }
      }
    }

    _globalHall = hallsSeen.values.isNotEmpty ? hallsSeen.values.first : null;

    // 2. Initialize default options and halls for each row
    for (final row in _orderedRows) {
      final key = _key(row.date, row.slot);
      final menu = _findMenu(row);
      if (menu != null && menu.dishes.isNotEmpty) {
        _selectedOptions[key] = menu.dishes.first;
        _selectedHalls[key] = (_globalHall != null && menu.halls.any((h) => h.id == _globalHall!.id))
            ? _globalHall!
            : (menu.halls.isNotEmpty
                ? menu.halls.first
                : const Hall(id: '1', name: 'مرکزی'));
      }
    }
  }

  int get _totalPriceRial {
    return _selectedOptions.values.fold<int>(0, (sum, o) => sum + o.priceRial);
  }

  int? get _deficitRial {
    if (widget.currentBalanceRial == null) return null;
    final deficit = _totalPriceRial - widget.currentBalanceRial!;
    return deficit > 0 ? deficit : null;
  }

  List<MealOffering> _buildOfferings() {
    final list = <MealOffering>[];
    for (final row in _orderedRows) {
      final key = _key(row.date, row.slot);
      final opt = _selectedOptions[key];
      final hall = _selectedHalls[key];
      if (opt != null && hall != null) {
        list.add(MealOffering(
          date: row.date,
          slot: row.slot,
          hall: hall,
          option: opt,
          reservable: true,
        ));
      }
    }
    return list;
  }

  void _applyGlobalHall(Hall hall) {
    setState(() {
      _globalHall = hall;
      for (final row in _orderedRows) {
        final key = _key(row.date, row.slot);
        final menu = _findMenu(row);
        if (menu != null && menu.halls.any((h) => h.id == hall.id)) {
          _selectedHalls[key] = hall;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _totalPriceRial;
    final deficit = _deficitRial;

    // Unique halls available across all selected meals
    final hallsSeen = <String, Hall>{};
    for (final row in _orderedRows) {
      final menu = _findMenu(row);
      if (menu != null) {
        for (final h in menu.halls) {
          hallsSeen.putIfAbsent(h.id, () => h);
        }
      }
    }
    final uniqueHalls = hallsSeen.values.toList();

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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'رزرو دسته‌ای ${toPersianDigits(_orderedRows.length)} وعده',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'سلف و نوع غذای دلخواه هر وعده را انتخاب کنید.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  if (widget.accountName != null) ...[
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
              ),
              const SizedBox(height: 12),

              // Global Hall Selector (if multiple halls exist)
              if (uniqueHalls.length > 1) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.restaurant, size: 16, color: theme.colorScheme.primary),
                          const SizedBox(width: 6),
                          Text(
                            'سلف تحویل برای همه وعده‌ها:',
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: uniqueHalls.map((hall) {
                          final isSelected = _globalHall?.id == hall.id;
                          return ChoiceChip(
                            label: Text(hall.name),
                            selected: isSelected,
                            onSelected: (_) => _applyGlobalHall(hall),
                            visualDensity: VisualDensity.compact,
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // Meal Items List
              Expanded(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _orderedRows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final row = _orderedRows[index];
                    final key = _key(row.date, row.slot);
                    final menu = _findMenu(row);
                    final selectedOption = _selectedOptions[key];
                    final selectedHall = _selectedHalls[key];
                    final dishes = menu?.dishes ?? const [];
                    final halls = menu?.halls ?? const [];

                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Day and Slot Title
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                '${mealSlotPersian(row.slot)} — ${formatPersianDate(row.date)}',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (selectedOption != null)
                                MoneyText(
                                  selectedOption.priceRial,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),

                          // Dish choices (if 2 or more options)
                          if (dishes.length > 1) ...[
                            Text(
                              'انتخاب غذا:',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 4),
                            ...dishes.map((opt) {
                              final isChosen = selectedOption?.id == opt.id;
                              return InkWell(
                                onTap: () {
                                  setState(() {
                                    _selectedOptions[key] = opt;
                                  });
                                },
                                borderRadius: BorderRadius.circular(8),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 18,
                                        height: 18,
                                        margin: const EdgeInsets.only(left: 8),
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: isChosen ? theme.colorScheme.primary : theme.colorScheme.outline,
                                            width: 2,
                                          ),
                                        ),
                                        child: isChosen
                                            ? Center(
                                                child: Container(
                                                  width: 9,
                                                  height: 9,
                                                  decoration: BoxDecoration(
                                                    shape: BoxShape.circle,
                                                    color: theme.colorScheme.primary,
                                                  ),
                                                ),
                                              )
                                            : null,
                                      ),
                                      Expanded(
                                        child: Text(
                                          opt.name,
                                          style: TextStyle(
                                            fontWeight: isChosen ? FontWeight.bold : FontWeight.normal,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        formatTomanPersian(opt.priceRial),
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: isChosen ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }),
                          ] else if (dishes.isNotEmpty) ...[
                            Row(
                              children: [
                                Icon(Icons.check_circle_outline, size: 16, color: AppColors.heldOf(context)),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    dishes.first.name,
                                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                                  ),
                                ),
                              ],
                            ),
                          ],

                          // Per-meal hall override (if multiple halls for this slot)
                          if (halls.length > 1) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Text(
                                  'سلف این وعده: ',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                DropdownButton<String>(
                                  value: (selectedHall != null && halls.any((h) => h.id == selectedHall.id))
                                      ? selectedHall.id
                                      : halls.first.id,
                                  isDense: true,
                                  underline: const SizedBox(),
                                  items: halls.map((h) {
                                    return DropdownMenuItem<String>(
                                      value: h.id,
                                      child: Text(
                                        h.name,
                                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                      ),
                                    );
                                  }).toList(),
                                  onChanged: (val) {
                                    if (val != null) {
                                      final chosen = halls.firstWhere((h) => h.id == val);
                                      setState(() {
                                        _selectedHalls[key] = chosen;
                                      });
                                    }
                                  },
                                ),
                              ],
                            ),
                          ] else if (halls.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              'سلف: ${halls.first.name}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),

              const SizedBox(height: 12),

              // Bottom Summary & Actions
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('مجموع مبلغ:'),
                        Text(
                          formatTomanPersian(total),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                    if (widget.currentBalanceRial != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'موجودی حساب:',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            formatTomanPersian(widget.currentBalanceRial!),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (deficit != null) ...[
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
                                'کسری موجودی: ${formatTomanPersian(deficit)}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onErrorContainer,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // Action Buttons
              if (deficit != null)
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () {
                          Navigator.of(context).pop();
                          final offerings = _buildOfferings();
                          widget.onTopUp?.call(deficit, offerings);
                        },
                  icon: const Icon(Icons.account_balance_wallet_outlined),
                  label: Text('شارژ حساب (${formatTomanPersian(deficit)}) و رزرو خودکار'),
                )
              else
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          setState(() => _busy = true);
                          final offerings = _buildOfferings();
                          Navigator.of(context).pop();
                          await widget.onConfirm(offerings);
                        },
                  icon: _busy
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.onPrimary),
                        )
                      : const Icon(Icons.check),
                  label: Text('تایید و ثبت رزرو (${toPersianDigits(_orderedRows.length)} وعده)'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
