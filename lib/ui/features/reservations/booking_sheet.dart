/// The booking sheet: choosing the dish and the hall for one meal.
///
/// ## Why a sheet and not a screen
///
/// Booking is a **commitment**. The cutoff is 17:00 two days before the
/// meal's delivery day, and after it the meal cannot be given back (F14) — so
/// the decision needs the dish, the price, the hall and the date all visible
/// at once, and it needs to be *finished* in one place.
///
/// A bottom sheet over the table keeps the student in the week they were
/// reading. A full screen would hide the table and make the student
/// remember where they were.
///
/// ## The one-meal rule
///
/// The portal does **not** enforce one meal per slot per day (F22): the
/// basket offers a meal the account already holds, and the server accepts a
/// second booking without complaint. So the rule is checked by the app before
/// the request goes out — and the app is the only thing standing between the
/// student and a double booking they cannot undo.
library;

import 'package:flutter/material.dart';

import '../../../core/hunt/hunt_notify.dart' show mealSlotPersian;
import '../../../core/meal/models.dart';
import '../../../core/shared/persian.dart';
import '../../theme/widgets.dart';

/// The sheet that books one meal.
class BookingSheet extends StatefulWidget {
  const BookingSheet({
    super.key,
    required this.menu,
    required this.onBook,
    this.accountName,
    this.currentBalanceRial,
    this.onTopUp,
    this.busy = false,
    this.error,
  });

  /// The name of the account this booking is made for.
  final String? accountName;

  /// The menu for the meal being booked.
  final MealMenu menu;

  /// Books the chosen offering. Returns the message to show, or null.
  final Future<String?> Function(MealOffering offering) onBook;

  /// The account's current balance in Rial, for deficit detection.
  final int? currentBalanceRial;

  /// Directs the student to increase balance when deficit is detected.
  final void Function(int deficitRial, MealOffering? offering)? onTopUp;

  /// Whether a booking is in flight.
  final bool busy;

  /// Why the last attempt failed.
  final String? error;

  /// Shows the sheet.
  static Future<void> show(
    BuildContext context, {
    required MealMenu menu,
    required Future<String?> Function(MealOffering offering) onBook,
    String? accountName,
    int? currentBalanceRial,
    void Function(int deficitRial, MealOffering? offering)? onTopUp,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => BookingSheet(
        menu: menu,
        onBook: onBook,
        accountName: accountName,
        currentBalanceRial: currentBalanceRial,
        onTopUp: onTopUp,
      ),
    );
  }

  @override
  State<BookingSheet> createState() => _BookingSheetState();
}

class _BookingSheetState extends State<BookingSheet> {
  OptionId? _dish;
  HallId? _hall;
  bool _busy = false;
  String? _error;

  /// The dishes of the currently selected hall.
  ///
  /// The portal's dish ids belong to one hall: the same lunch is `64574` in
  /// hall 1 and `64639` in hall 2. Reading [MealMenu.dishes] for a hall whose
  /// list was not read would offer another hall's ids. [MealMenu.dishesForHall]
  /// is empty in that case, which is honest — the sheet then says the list was
  /// not read instead of sending an id that means something else.
  List<MenuOption> get _dishes {
    final menu = widget.menu;
    final hall = _hall;
    if (hall == null) return menu.dishes;
    return menu.dishesForHall(hall);
  }

  @override
  void initState() {
    super.initState();
    final defaultHallId = widget.menu.optionsByHall.keys.firstOrNull;
    if (defaultHallId != null &&
        widget.menu.halls.any((h) => h.id == defaultHallId)) {
      _hall = defaultHallId;
    } else if (widget.menu.halls.isNotEmpty) {
      _hall = widget.menu.halls.first.id;
    }
    if (_dishes.length == 1) {
      _dish = _dishes.first.id;
    }
  }

  int? get _deficitRial {
    if (widget.currentBalanceRial == null || _dish == null) return null;
    final dish = _dishes.cast<MenuOption?>().firstWhere(
      (d) => d?.id == _dish,
      orElse: () => null,
    );
    if (dish == null) return null;
    final deficit = dish.priceRial - widget.currentBalanceRial!;
    return deficit > 0 ? deficit : null;
  }

  MealOffering? get _selectedOffering {
    if (_dish == null) return null;
    final dish = _dishes.cast<MenuOption?>().firstWhere(
      (d) => d?.id == _dish,
      orElse: () => null,
    );
    if (dish == null || widget.menu.halls.isEmpty) return null;
    final hall = _hall == null
        ? widget.menu.halls.first
        : widget.menu.halls.firstWhere(
            (h) => h.id == _hall,
            orElse: () => widget.menu.halls.first,
          );
    return MealOffering(
      date: widget.menu.date,
      slot: widget.menu.slot,
      hall: hall,
      option: dish,
      reservable: widget.menu.reservable,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
            maxHeight: MediaQuery.of(context).size.height * 0.8,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${mealSlotPersian(menu.slot)} — ${formatPersianDate(menu.date)}',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'غذای مورد نظر را انتخاب کنید.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (widget.accountName != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer.withValues(
                            alpha: 0.7,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.3,
                            ),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.person,
                              size: 14,
                              color: theme.colorScheme.primary,
                            ),
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
                const SizedBox(height: 16),

                if (_error != null) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: theme.colorScheme.errorContainer,
                    ),
                    child: Text(
                      _error!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                _Dishes(
                  dishes: _dishes,
                  selected: _dish,
                  onChanged: (id) => setState(() => _dish = id),
                ),

                if (_deficitRial != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer.withValues(
                        alpha: 0.6,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.account_balance_wallet_outlined,
                          size: 20,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'کسری موجودی: ${formatTomanPersian(_deficitRial!)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onErrorContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (widget.onTopUp != null)
                          TextButton(
                            onPressed: () {
                              final deficit = _deficitRial!;
                              final offering = _selectedOffering;
                              Navigator.of(context).pop();
                              widget.onTopUp!(deficit, offering);
                            },
                            child: const Text('افزایش موجودی'),
                          ),
                      ],
                    ),
                  ),
                ],

                if (menu.halls.length > 1) ...[
                  const SizedBox(height: 20),
                  _Halls(
                    halls: menu.halls,
                    selected: _hall,
                    onChanged: (id) {
                      setState(() {
                        _hall = id;
                        // The new hall's dish ids are its own. Keep the
                        // previous choice only when this hall lists it;
                        // otherwise fall back to a single dish or none — never
                        // to the previous hall's id (C3).
                        final dishes = menu.dishesForHall(id);
                        if (_dish != null &&
                            dishes.any((d) => d.id == _dish)) {
                          // Still valid for this hall.
                        } else if (dishes.length == 1) {
                          _dish = dishes.first.id;
                        } else {
                          _dish = null;
                        }
                      });
                    },
                  ),
                ],

                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _dish == null || _busy ? null : _book,
                    icon: Icon(_busy ? Icons.hourglass_empty : Icons.check),
                    label: Text(_busy ? 'در حال ثبت' : 'ثبت رزرو'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Books the chosen dish and hall.
  Future<void> _book() async {
    final menu = widget.menu;
    final dishId = _dish;
    if (dishId == null) return;

    final dish = _dishes.cast<MenuOption?>().firstWhere(
      (d) => d?.id == dishId,
      orElse: () => null,
    );
    if (dish == null) {
      setState(() {
        _error = 'این غذا برای سلف انتخاب‌شده خوانده نشده است. سلف را دوباره '
            'انتخاب کنید.';
      });
      return;
    }

    final deficit = _deficitRial;
    if (deficit != null && widget.onTopUp != null) {
      final goToTopUp = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('کمبود موجودی حساب'),
          content: Text(
            'موجودی حساب برای رزرو این غذا کافی نیست.\n'
            'کسری موجودی: ${formatTomanPersian(deficit)}\n\n'
            'آیا مایلید برای افزایش اعتبار به صفحه پرداخت هدایت شوید؟ (پس از پرداخت موفق، غذا خودکار رزرو می‌شود)',
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
        final offering = _selectedOffering;
        Navigator.of(context).pop();
        widget.onTopUp!(deficit, offering);
        return;
      }
    }

    if (menu.halls.isEmpty) return;

    // The hall is a choice, but the dish belongs to it. The UI never pairs a
    // dish with a hall it was not read for.
    final hall = _hall == null
        ? menu.halls.first
        : menu.halls.firstWhere(
            (h) => h.id == _hall,
            orElse: () => menu.halls.first,
          );

    setState(() {
      _busy = true;
      _error = null;
    });

    final message = await widget.onBook(
      MealOffering(
        date: menu.date,
        slot: menu.slot,
        hall: hall,
        option: dish,
        reservable: menu.reservable,
      ),
    );

    if (!mounted) return;

    if (message == null) {
      Navigator.of(context).pop();
      return;
    }

    setState(() {
      _busy = false;
      _error = message;
    });
  }
}

/// The dishes on offer for the selected hall.
class _Dishes extends StatelessWidget {
  const _Dishes({
    required this.dishes,
    required this.selected,
    required this.onChanged,
  });

  final List<MenuOption> dishes;
  final OptionId? selected;
  final void Function(OptionId) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('غذا', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        if (dishes.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.5,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'لیست غذای این سلف خوانده نشده است. سلف دیگری انتخاب کنید.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          RadioGroup<String>(
            groupValue: selected,
            onChanged: (v) {
              if (v == null) return;
              onChanged(v);
            },
            child: Column(
              children: [
                for (final dish in dishes)
                  RadioListTile<String>(
                    value: dish.id,
                    title: Text(dish.name),
                    subtitle: MoneyText(
                      dish.priceRial,
                      style: theme.textTheme.bodySmall,
                      colour: theme.colorScheme.onSurfaceVariant,
                    ),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The halls the meal is served in.
class _Halls extends StatelessWidget {
  const _Halls({
    required this.halls,
    required this.selected,
    required this.onChanged,
  });

  final List<Hall> halls;
  final HallId? selected;
  final void Function(HallId) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('سلف', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 2),
        Text(
          'سلفی که می‌خواهید غذا را از آن بگیرید.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        RadioGroup<String>(
          groupValue: selected,
          onChanged: (v) {
            if (v == null) return;
            onChanged(v);
          },
          child: Column(
            children: [
              for (final hall in halls)
                RadioListTile<String>(
                  value: hall.id,
                  title: Text(hall.name),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
