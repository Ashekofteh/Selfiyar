import 'package:flutter/material.dart';

/// A modern animated dialog displayed while waiting for the forgot receipt slip.
///
/// Features:
/// - Smooth 60fps pulsating badge with receipt icon.
/// - Circular progress indicator styled with app theme.
/// - Informative Persian status texts.
/// - Non-dismissible ([PopScope(canPop: false)]) to prevent accidental cancellation.
class ForgotReceiptLoadingDialog extends StatefulWidget {
  const ForgotReceiptLoadingDialog({
    super.key,
    this.title = 'در حال صدور فیش فراموشی...',
    this.subtitle = 'ارتباط امن با سامانه کالینان دانشگاه و دریافت ژتون موقت',
  });

  final String title;
  final String subtitle;

  @override
  State<ForgotReceiptLoadingDialog> createState() => _ForgotReceiptLoadingDialogState();
}

class _ForgotReceiptLoadingDialogState extends State<ForgotReceiptLoadingDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _scaleAnimation = Tween<double>(begin: 0.94, end: 1.06).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    _opacityAnimation = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return PopScope(
      canPop: false,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
                    // Inner pulsing container with receipt icon
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
                          color: colorScheme.primaryContainer.withValues(alpha: 0.7),
                          border: Border.all(
                            color: colorScheme.primary.withValues(alpha: 0.3),
                            width: 1.5,
                          ),
                        ),
                        child: Icon(
                          Icons.receipt_long_rounded,
                          size: 32,
                          color: colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              // Main title
              Text(
                widget.title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              // Subtitle
              Text(
                widget.subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
