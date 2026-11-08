/// Small shared widgets, and the app's money formatting.
///
/// ## The money rule
///
/// Every amount the user sees is in **Toman**. The domain keeps Rial because
/// that is the portal's unit and every comparison must be exact; the conversion
/// happens here, at the display boundary, exactly once.
///
/// [MoneyText] is the ONLY way a screen should render an amount, which is what
/// makes the rule enforceable rather than aspirational — a screen cannot
/// accidentally reach for a Rial formatter, because there is no convenient
/// Rial formatter to reach for.
library;

export 'widgets/rotating_refresh_button.dart';
export 'widgets/receipt_loading_dialog.dart';
export 'widgets/offline_banner.dart';

import 'package:flutter/material.dart';

import '../core/persian.dart';

/// A monetary amount, in Toman.
class MoneyText extends StatelessWidget {
  const MoneyText(
    this.amountRial, {
    super.key,
    this.style,
    this.colour,
    this.suffix,
    this.compact = false,
  });

  /// The amount, in **Rial** (the portal's unit). Converted for display.
  final int amountRial;

  final TextStyle? style;
  final Color? colour;

  /// Appended after the amount, e.g. a per-meal marker.
  final String? suffix;

  /// Drops the unit word, for use inside a larger phrase.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final text = compact
        ? toPersianDigits(rialToToman(amountRial))
        : formatTomanPersian(amountRial);
    return Text(
      suffix == null ? text : '$text $suffix',
      style: (style ?? Theme.of(context).textTheme.bodyLarge)?.copyWith(
        color: colour,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      textDirection: TextDirection.rtl,
    );
  }
}

/// A screen section with a heading.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// An empty-state message, with an optional action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              title,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// A label/value row, the workhorse of the detail panels.
class DetailRow extends StatelessWidget {
  const DetailRow({super.key, required this.label, required this.value});

  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          value,
        ],
      ),
    );
  }
}
