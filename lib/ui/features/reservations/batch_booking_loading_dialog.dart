import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/shared/persian.dart';

/// A modern animated dialog displayed while processing a batch meal reservation.
///
/// Features:
/// - Smooth 60fps pulsating badge with dining/food icon.
/// - Circular progress indicator styled with app theme.
/// - Dynamic rotating Persian status text indicating reservation progress.
/// - Persian formatted meal count display.
/// - Non-dismissible ([PopScope(canPop: false)]) to prevent accidental cancellation.
class BatchBookingLoadingDialog extends StatefulWidget {
  const BatchBookingLoadingDialog({
    super.key,
    required this.mealCount,
    this.title,
    this.subtitle,
  });

  /// The number of meals being reserved in this batch.
  final int mealCount;

  /// Optional custom title override.
  final String? title;

  /// Optional custom subtitle override.
  final String? subtitle;

  @override
  State<BatchBookingLoadingDialog> createState() =>
      _BatchBookingLoadingDialogState();
}

class _BatchBookingLoadingDialogState extends State<BatchBookingLoadingDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _opacityAnimation;

  Timer? _statusTimer;
  int _statusIndex = 0;

  static const List<String> _statusSteps = [
    'ارتباط امن با سامانه کالینان دانشگاه...',
    'بررسی اعتبار و ثبت ژتون‌های انتخابی...',
    'نهایی‌سازی رزروها... لطفاً شکیبا باشید.',
  ];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _scaleAnimation = Tween<double>(
      begin: 0.94,
      end: 1.06,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    _opacityAnimation = Tween<double>(
      begin: 0.75,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    _statusTimer = Timer.periodic(const Duration(milliseconds: 2200), (timer) {
      if (!mounted) return;
      setState(() {
        _statusIndex = (_statusIndex + 1) % _statusSteps.length;
      });
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final resolvedTitle =
        widget.title ??
        'در حال رزرو گروهی ${toPersianDigits(widget.mealCount)} وعده غذا...';
    final resolvedSubtitle = widget.subtitle ?? _statusSteps[_statusIndex];

    return PopScope(
      canPop: false,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        elevation: 6,
        backgroundColor: colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Animated icon container with glowing pulse
              SizedBox(
                width: 96,
                height: 96,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Outer spinning progress indicator
                    SizedBox(
                      width: 88,
                      height: 88,
                      child: CircularProgressIndicator(
                        strokeWidth: 3.5,
                        strokeCap: StrokeCap.round,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          colorScheme.primary,
                        ),
                      ),
                    ),
                    // Inner pulsing container with restaurant icon
                    AnimatedBuilder(
                      animation: _controller,
                      builder: (context, child) {
                        return Transform.scale(
                          scale: _scaleAnimation.value,
                          child: Opacity(
                            opacity: _opacityAnimation.value,
                            child: child,
                          ),
                        );
                      },
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: colorScheme.primaryContainer.withValues(
                            alpha: 0.7,
                          ),
                          border: Border.all(
                            color: colorScheme.primary.withValues(alpha: 0.3),
                            width: 1.5,
                          ),
                        ),
                        child: Icon(
                          Icons.restaurant_rounded,
                          size: 32,
                          color: colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              // Main title with Persian meal count
              Text(
                resolvedTitle,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              // Dynamic status message with smooth animated switcher
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (child, animation) {
                  return FadeTransition(opacity: animation, child: child);
                },
                child: Text(
                  resolvedSubtitle,
                  key: ValueKey<String>(resolvedSubtitle),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 14),
              // Safety advisory note
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.4,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 13,
                      color: colorScheme.outline,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      'لطفاً تا پایان عملیات از برنامه خارج نشوید',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.outline,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
