import 'package:flutter/material.dart';

import '../../core/hunt_notify.dart' show mealSlotPersian;
import '../../core/models.dart';
import '../../core/persian.dart';

/// A celebratory dialog displayed when a food hunt succeeds.
///
/// Shows:
/// - Celebratory icon badge.
/// - Dish name, dining hall, price paid in Toman, and meal slot / date.
/// - Action button to navigate directly to the reservations tab.
class HuntSuccessDialog extends StatelessWidget {
  const HuntSuccessDialog({
    super.key,
    required this.dishName,
    required this.hallName,
    this.priceRial,
    this.date,
    this.slot,
    this.onViewReservations,
  });

  final String dishName;
  final String hallName;
  final int? priceRial;
  final DateTime? date;
  final MealSlot? slot;
  final VoidCallback? onViewReservations;

  /// Convenience helper to show the dialog.
  static Future<void> show({
    required BuildContext context,
    required String dishName,
    required String hallName,
    int? priceRial,
    DateTime? date,
    MealSlot? slot,
    VoidCallback? onViewReservations,
  }) {
    return showDialog<void>(
      context: context,
      builder: (context) => HuntSuccessDialog(
        dishName: dishName,
        hallName: hallName,
        priceRial: priceRial,
        date: date,
        slot: slot,
        onViewReservations: onViewReservations,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final dateText = date != null ? formatPersianDate(date!) : null;
    final slotText = slot != null ? mealSlotPersian(slot!) : null;
    final mealTimeText = [
      ?slotText,
      ?dateText,
    ].join(' • ');

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Celebratory badge
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.check_circle_rounded,
                size: 38,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'شکار موفق غذا!',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'غذای انتخابی شما با موفقیت از بازار سبد غذا خریداری و رزرو شد.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            // Details Card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: Column(
                children: [
                  _DetailRow(
                    icon: Icons.restaurant_menu_rounded,
                    label: 'غذای خریداری‌شده:',
                    value: dishName,
                    isHighlight: true,
                    theme: theme,
                  ),
                  const Divider(height: 20),
                  _DetailRow(
                    icon: Icons.location_on_outlined,
                    label: 'سلف سرویس:',
                    value: hallName,
                    theme: theme,
                  ),
                  if (priceRial != null) ...[
                    const Divider(height: 20),
                    _DetailRow(
                      icon: Icons.payments_outlined,
                      label: 'قیمت پرداختی:',
                      value: formatTomanPersian(priceRial!),
                      valueColor: colorScheme.primary,
                      theme: theme,
                    ),
                  ],
                  if (mealTimeText.isNotEmpty) ...[
                    const Divider(height: 20),
                    _DetailRow(
                      icon: Icons.event_available_outlined,
                      label: 'وعده و تاریخ:',
                      value: mealTimeText,
                      theme: theme,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('بستن'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      onViewReservations?.call();
                    },
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.receipt_long_outlined, size: 18),
                    label: const Text('مشاهده رزروها'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.theme,
    this.isHighlight = false,
    this.valueColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final ThemeData theme;
  final bool isHighlight;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const Spacer(),
        Flexible(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: isHighlight ? FontWeight.bold : FontWeight.w600,
              color: valueColor ?? theme.colorScheme.onSurface,
            ),
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
