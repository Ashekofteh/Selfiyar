import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/account.dart';
import '../../core/local_meal_store.dart';
import '../../core/meal_invariant.dart' show MealSource;
import '../../core/models.dart';
import '../../core/persian.dart';
import '../../core/portal.dart' show ReserveType;
import '../../core/reminder.dart';
import '../../core/time.dart';
import '../../platform/platform_services.dart';
import '../app_state.dart';

/// Dedicated screen shown when the student taps a meal reminder notification,
/// or navigates from the reminders screen.
///
/// Presents the day's meals for the reminder slot (lunch today, or dinner tonight
/// and tomorrow's breakfast), with collection times, meal hall, receipt status,
/// quick actions to request or copy forgot-card receipt slips, and options to sell
/// or hunt for meals.
class MealReminderScreen extends StatefulWidget {
  const MealReminderScreen({
    super.key,
    required this.slot,
    required this.state,
    required this.services,
    this.onRefresh,
    this.onForgotReceipt,
    this.onSellMeal,
    this.onRemoveFromSell,
    this.onOpenHunt,
  });

  final ReminderSlot slot;
  final AppState state;
  final AppServices services;
  final Future<void> Function()? onRefresh;
  final Future<void> Function(
    DateTime date,
    MealSlot slot,
    String? dishName,
    ReserveType reserveType, {
    AccountId? targetAccount,
  })? onForgotReceipt;
  final Future<void> Function(
    DateTime date,
    MealSlot slot,
    String dishName, {
    AccountId? targetAccount,
  })? onSellMeal;
  final Future<void> Function(DateTime date, MealSlot slot)? onRemoveFromSell;
  final void Function(MealSlot slot, DateTime date)? onOpenHunt;

  @override
  State<MealReminderScreen> createState() => _MealReminderScreenState();
}

class _MealReminderScreenState extends State<MealReminderScreen> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = widget.services.clock.portalTodayUtc;
    final tomorrow = today.add(const Duration(days: 1));

    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final meals = _matchingMeals(today, tomorrow);

        return Scaffold(
          appBar: AppBar(
            title: Text(widget.slot == ReminderSlot.lunch
                ? 'وعده‌های ناهار امروز'
                : 'وعده‌های شام و صبحانه'),
            actions: [
              if (widget.onRefresh != null)
                IconButton(
                  onPressed: _busy || widget.state.isSyncing
                      ? null
                      : () async {
                          setState(() => _busy = true);
                          try {
                            await widget.onRefresh!();
                          } finally {
                            if (mounted) setState(() => _busy = false);
                          }
                        },
                  icon: _busy || widget.state.isSyncing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  tooltip: 'به‌روزرسانی از سامانه',
                ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: () async {
              if (widget.onRefresh != null) {
                await widget.onRefresh!();
              }
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _buildHeaderBanner(context, today),
                const SizedBox(height: 16),
                if (meals.isEmpty)
                  _buildEmptyState(context, today)
                else ...[
                  Row(
                    children: [
                      Icon(
                        Icons.restaurant_menu,
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'غذاهای رزروشده شما (${toPersianDigits(meals.length)} وعده)',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  for (final meal in meals) ...[
                    _buildMealCard(context, meal),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 8),
                  _buildHelpNote(context),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// Finds meals in the store matching the reminder slot.
  List<StoredMeal> _matchingMeals(DateTime today, DateTime tomorrow) {
    final all = widget.services.mealStore.store.all;

    return all.where((m) {
      if (widget.slot == ReminderSlot.lunch) {
        return m.slot == MealSlot.lunch &&
            m.date.year == today.year &&
            m.date.month == today.month &&
            m.date.day == today.day;
      } else {
        // Evening reminder: today's dinner + tomorrow's breakfast!
        final isDinnerToday = m.slot == MealSlot.dinner &&
            m.date.year == today.year &&
            m.date.month == today.month &&
            m.date.day == today.day;
        final isBreakfastTomorrow = m.slot == MealSlot.breakfast &&
            m.date.year == tomorrow.year &&
            m.date.month == tomorrow.month &&
            m.date.day == tomorrow.day;
        return isDinnerToday || isBreakfastTomorrow;
      }
    }).toList();
  }

  /// Top summary banner with date and distribution hours.
  Widget _buildHeaderBanner(BuildContext context, DateTime today) {
    final theme = Theme.of(context);
    final isLunch = widget.slot == ReminderSlot.lunch;

    final bannerColor = isLunch
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.tertiaryContainer;
    final onBannerColor = isLunch
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onTertiaryContainer;

    final scheduleText = isLunch
        ? 'ساعت توزیع ناهار: ۱۱:۱۵ الی ۱۵:۳۰'
        : 'ساعت توزیع شام و صبحانه فردا: ۱۶:۳۰ الی ۲۰:۳۰';

    final dateLabel = isLunch
        ? formatPersianDateWithYear(today)
        : 'عصر ${formatPersianDate(today)} (شام امروز و صبحانه فردا)';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bannerColor.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: bannerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: bannerColor,
                child: Icon(
                  isLunch ? Icons.wb_sunny_rounded : Icons.nights_stay_rounded,
                  color: onBannerColor,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      dateLabel,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: onBannerColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      scheduleText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: onBannerColor.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    isLunch
                        ? 'فراموش نکنید: کارت دانشجویی یا فیش فراموشی را همراه داشته باشید.'
                        : 'توجه: صبحانه فردا نیز هم‌اکنون به همراه شام در سلف توزیع می‌شود.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11.5,
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

  /// Single meal card with dish details and receipt / action options.
  Widget _buildMealCard(BuildContext context, StoredMeal meal) {
    final theme = Theme.of(context);
    final account = widget.state.accounts.cast<SavedAccount?>().firstWhere(
          (a) => a?.id == meal.accountId,
          orElse: () => null,
        );
    final accountName = account?.resolvedName ?? meal.accountId;
    final isDistributionPassed = isMealDistributionPassed(
      meal.date,
      meal.slot,
      clock: widget.services.clock,
    );
    final cachedCode = widget.state.receiptCodeFor(meal.accountId, meal.date, meal.slot);

    final slotLabel = switch (meal.slot) {
      MealSlot.breakfast => 'صبحانه فردا',
      MealSlot.lunch => 'ناهار',
      MealSlot.dinner => 'شام',
    };

    final slotColor = switch (meal.slot) {
      MealSlot.breakfast => Colors.teal,
      MealSlot.lunch => Colors.orange.shade800,
      MealSlot.dinner => Colors.indigo,
    };

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row: Account identity and Slot badge
            Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Text(
                    accountName.isNotEmpty ? accountName.characters.first : '؟',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    accountName,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: slotColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: slotColor.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    slotLabel,
                    style: TextStyle(
                      color: slotColor,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 20),

            // Dish and Hall
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        meal.dishName ?? 'غذای رزروشده',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            Icons.location_on_outlined,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            meal.hallName ?? 'سلف نامشخص',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      if (meal.priceRial != null && meal.priceRial! > 0) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.payments_outlined,
                              size: 16,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              formatTomanPersian(meal.priceRial!),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                // Status Chip
                _buildStatusChip(context, meal, isDistributionPassed),
              ],
            ),
            const SizedBox(height: 16),

            // Cached receipt banner or Action Buttons
            if (cachedCode != null && cachedCode.isNotEmpty)
              _buildCachedReceiptBox(context, meal, cachedCode, accountName, slotLabel)
            else
              _buildActionRow(context, meal, isDistributionPassed, accountName, slotLabel),
          ],
        ),
      ),
    );
  }

  /// Status badge chip (consumed / distribution passed / ready).
  Widget _buildStatusChip(BuildContext context, StoredMeal meal, bool isDistributionPassed) {
    final theme = Theme.of(context);

    if (meal.isConsumed) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_rounded, size: 14, color: Colors.green),
            SizedBox(width: 4),
            Text(
              'تحویل گرفته شد',
              style: TextStyle(
                color: Colors.green,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }

    if (isDistributionPassed) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_toggle_off, size: 14, color: theme.colorScheme.outline),
            const SizedBox(width: 4),
            Text(
              'توزیع خاتمه یافته',
              style: TextStyle(
                color: theme.colorScheme.outline,
                fontSize: 11,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_outlined, size: 14, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          Text(
            'آماده تحویل در سلف',
            style: TextStyle(
              color: theme.colorScheme.primary,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  /// Box showing the already received forgot-receipt code.
  Widget _buildCachedReceiptBox(
    BuildContext context,
    StoredMeal meal,
    String code,
    String accountName,
    String slotLabel,
  ) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.receipt_rounded, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Text(
                'کد فیش فراموشی کارت شما:',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              SelectableText(
                code,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 4,
                  color: theme.colorScheme.primary,
                ),
              ),
              const Spacer(),
              IconButton.filledTonal(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: 'کپی کد فیش',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: code));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('کد فیش در حافظه کپی شد')),
                  );
                },
              ),
              const SizedBox(width: 4),
              IconButton.filledTonal(
                icon: const Icon(Icons.share, size: 18),
                tooltip: 'ارسال / پیامک',
                onPressed: () => _shareCode(context, code, accountName, slotLabel, meal),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Action buttons for requesting receipt or selling meal.
  Widget _buildActionRow(
    BuildContext context,
    StoredMeal meal,
    bool isDistributionPassed,
    String accountName,
    String slotLabel,
  ) {
    final isListed = widget.state.isListedInBasket(meal.accountId, meal.date, meal.slot);
    final canAct = !meal.isConsumed && !isDistributionPassed;
    final canGetReceipt = canAct && !isListed;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (widget.onForgotReceipt != null)
          OutlinedButton.icon(
            onPressed: !canGetReceipt
                ? null
                : () async {
                    final reserveType = meal.source == MealSource.basketPurchase
                        ? ReserveType.foodBasket
                        : ReserveType.weekly;
                    await widget.onForgotReceipt!(
                      meal.date,
                      meal.slot,
                      meal.dishName,
                      reserveType,
                      targetAccount: meal.accountId,
                    );
                  },
            icon: const Icon(Icons.receipt_long_outlined, size: 18),
            label: Text(isListed ? 'دریافت فیش (در سبد فروش)' : 'دریافت فیش فراموشی'),
          ),
        if (widget.onRemoveFromSell != null && isListed)
          OutlinedButton.icon(
            onPressed: !canAct
                ? null
                : () async {
                    await widget.onRemoveFromSell!(meal.date, meal.slot);
                    if (mounted) setState(() {});
                  },
            icon: const Icon(Icons.remove_shopping_cart_outlined, size: 18),
            label: const Text('انصراف از فروش در سبد'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.orange.shade800,
            ),
          )
        else if (widget.onSellMeal != null)
          OutlinedButton.icon(
            onPressed: (!canAct || isListed)
                ? null
                : () async {
                    await widget.onSellMeal!(
                      meal.date,
                      meal.slot,
                      meal.dishName ?? slotLabel,
                      targetAccount: meal.accountId,
                    );
                    if (mounted) setState(() {});
                  },
            icon: const Icon(Icons.storefront_outlined, size: 18),
            label: Text(isListed ? 'در سبد فروش قرار دارد' : 'فروش به سبد غذا'),
          ),
      ],
    );
  }

  /// Empty state when no meals exist for this slot.
  Widget _buildEmptyState(BuildContext context, DateTime today) {
    final isLunch = widget.slot == ReminderSlot.lunch;
    final slotName = isLunch ? 'ناهار امروز' : 'شام امروز یا صبحانه فردا';

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
        child: Column(
          children: [
            Icon(
              Icons.no_meals_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'غذایی برای $slotName رزرو نشده است',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'در هیچ‌یک از حساب‌های شما برای این وعده رزروی ثبت نشده است.\nاگر تمایل دارید، می‌توانید از سبد غذای دانشگاه خرید کنید.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            if (widget.onOpenHunt != null)
              FilledButton.icon(
                onPressed: () {
                  final targetSlot = isLunch ? MealSlot.lunch : MealSlot.dinner;
                  widget.onOpenHunt!(targetSlot, today);
                },
                icon: const Icon(Icons.shopping_bag_outlined),
                label: const Text('خرید از سبد غذا (شکار)'),
              ),
          ],
        ),
      ),
    );
  }

  /// Helpful reminder note footer.
  Widget _buildHelpNote(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lightbulb_outline, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'راهنما: در صورتی که کارت دانشجویی همراه ندارید، روی دکمه «دریافت فیش فراموشی» بزنید تا کد برای شما صادر شود. دستگاه سلف بدون کارت و با همین کد غذا را تحویل می‌دهد.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Shares receipt code via native sharing.
  Future<void> _shareCode(
    BuildContext context,
    String code,
    String accountName,
    String slotLabel,
    StoredMeal meal,
  ) async {
    final dateStr = formatPersianDate(meal.date);
    final dish = meal.dishName ?? slotLabel;
    final shareText = 'کد فیش فراموشی غذای سلف دانشگاه باهنر:\n'
        'دانشجو: $accountName\n'
        'وعده: $slotLabel ($dateStr)\n'
        'غذا: $dish\n'
        'سلف: ${meal.hallName ?? "سلف دانشگاه"}\n\n'
        'کد فیش تحویل غذا: $code';

    try {
      await widget.services.bridge.shareText(
        text: shareText,
        title: 'کد فیش فراموشی سلف',
      );
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: shareText));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('متن فیش در حافظه کپی شد')),
        );
      }
    }
  }
}
