import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/shared/persian.dart';
import '../../core/shared/platform_stores.dart';
import '../theme/theme.dart';

/// Shows the onboarding interactive guide dialog.
Future<void> showOnboardingGuide(
  BuildContext context, {
  required PlainStore plainStore,
  VoidCallback? onComplete,
  bool isFirstLaunch = false,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: !isFirstLaunch,
    builder: (context) =>
        _OnboardingDialog(plainStore: plainStore, onComplete: onComplete),
  );
}

class _OnboardingDialog extends StatefulWidget {
  const _OnboardingDialog({required this.plainStore, this.onComplete});

  final PlainStore plainStore;
  final VoidCallback? onComplete;

  static const String keyCompleted = 'onboarding_completed';

  @override
  State<_OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends State<_OnboardingDialog> {
  final PageController _controller = PageController();
  int _currentPage = 0;
  static const int _totalPages = 5;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    await widget.plainStore.writeBool(_OnboardingDialog.keyCompleted, true);
    if (mounted) {
      Navigator.of(context).pop();
      widget.onComplete?.call();
    }
  }

  void _nextPage() {
    if (_currentPage < _totalPages - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      // The page is finished; the completion of `_finish` is irrelevant here,
      // so it is deliberately left unawaited.
      unawaited(_finish());
    }
  }

  void _prevPage() {
    if (_currentPage > 0) {
      _controller.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 600),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                // Top Header (Step Counter and Skip Button)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest.withValues(
                          alpha: 0.5,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'گام ${toPersianDigits(_currentPage + 1)} از ${toPersianDigits(_totalPages)}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    TextButton(onPressed: _finish, child: const Text('رد شدن')),
                  ],
                ),
                const SizedBox(height: 12),

                // Main Page View Carousel
                Expanded(
                  child: PageView(
                    controller: _controller,
                    onPageChanged: (page) =>
                        setState(() => _currentPage = page),
                    children: [
                      _buildSlide(
                        icon: Icons.bolt_rounded,
                        iconColor: AppColors.primary,
                        bgColor: AppColors.primaryContainer,
                        title: 'ورود هوشمند و بدون معطلی',
                        description: 'سِلفیار کدهای امنیتی (کپچا) را به صورت خودکار و در کسری از ثانیه حل می‌کند. همچنین می‌توانید چندین حساب دانشجویی را به صورت هم‌زمان و با امنیت کامل ذخیره و مدیریت کنید.',
                        chips: const [
                          '⚡ حل فوری و محلی کپچا',
                          '👥 مدیریت چند حسابه',
                          '🔒 ذخیره‌سازی امن و آفلاین',
                        ],
                      ),
                      _buildSlide(
                        icon: Icons.restaurant_menu_rounded,
                        iconColor: colorScheme.primary,
                        bgColor: colorScheme.primaryContainer,
                        title: 'دریافت منو و رزرو غذا',
                        alertBox: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.primaryContainer.withValues(
                              alpha: 0.8,
                            ),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: AppColors.primary.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.refresh_rounded,
                                color: AppColors.primary,
                                size: 24,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'نکته مهم برای اولین استفاده:\nپس از ورود به برنامه و رفتن به تب «رزروها»، حتماً ابتدا یک‌بار دکمه به‌روزرسانی (رفرش 🔄) را لمس کنید تا منوی جدید غذاها و سلف‌ها از سامانه دانشگاه بارگذاری شوند.',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: colorScheme.onSurface,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        description: 'با لمس آیکون چک‌لیست (📋) در بالای صفحه، وارد حالت رزرو گروهی شوید؛ وعده‌های دلخواه کل هفته را علامت بزنید و با یک لمس، سلف و غذای همه را یک‌جا تعیین و رزرو کنید!',
                        chips: const [
                          '📋 رزرو گروهی کل هفته با ۱ لمس',
                          '🏛 انتخاب سریع سلف و نوع غذا',
                          '💳 محاسبه زنده جمع کل هزینه',
                        ],
                      ),
                      _buildSlide(
                        icon: Icons.pie_chart_rounded,
                        iconColor: AppColors.secondary,
                        bgColor: AppColors.secondaryContainer,
                        title: 'مدیریت و شفافیت مالی',
                        description: 'در تب «مالی» می‌توانید نمودار هزینه‌کرد و تراکنش‌های خود را به تفکیک وعده‌های صبحانه، ناهار و شام با مبالغ خوانا به تومان مشاهده کنید و با فیلترهای هفتگی و ماهانه، مدیریت دقیقی بر هزینه‌های سلف خود داشته باشید.',
                        chips: const [
                          '📊 نمودار تفکیک وعده‌ها',
                          '💰 مبالغ شفاف به تومان',
                          '📅 فیلترهای هفتگی و ماهانه',
                        ],
                      ),
                      _buildSlide(
                        icon: Icons.shopping_basket_rounded,
                        iconColor: AppColors.secondary,
                        bgColor: AppColors.secondaryContainer,
                        title: 'سبد غذایی و شکار خودکار',
                        description: 'اگر برنامه‌تان عوض شد و نتوانستید به سلف بروید، غذای رزرو شده را در «سبد غذایی» برای فروش بگذارید تا پولتان نسوزد!\n\nهمچنین اگر از مهلت رزرو جا ماندید، غذای مازاد دیگران را بخرید یا به «شکارچی خودکار» بسپارید تا در لحظه آزاد شدن ظرفیت‌ها برایتان صید کند.',
                        chips: const [
                          '🍱 فروش ژتون مازاد در سبد',
                          '🛒 خرید غذاهای آزاد شده',
                          '🎯 شکار خودکار با هوش مصنوعی',
                        ],
                      ),
                      _buildSlide(
                        icon: Icons.notifications_active_rounded,
                        iconColor: AppColors.primary,
                        bgColor: AppColors.primaryContainer,
                        title: 'یادآورها و فیش فراموشی کارت',
                        description: 'با تنظیم یادآورها در تب «یادآورها»، موعد توزیع غذا و مهلت نهایی رزرو هفته آینده به شما اعلام می‌شود تا وعده‌ای نسوزد.\n\nهمچنین در صورت جا گذاشتن کارت فیزیکی، می‌توانید فوراً بارکد فیش فراموشی بگیرید یا آن را برای دوستانتان پیامک کنید.',
                        chips: const [
                          '⏰ یادآوری ناهار و شام',
                          '🔔 تلنگر رزرو هفته آینده',
                          '🧾 بارکد و پیامک فیش فراموشی',
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Bottom Indicators and Navigation Buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Dot Indicators
                    Row(
                      children: List.generate(
                        _totalPages,
                        (index) => AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          width: _currentPage == index ? 16 : 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: _currentPage == index
                                ? colorScheme.primary
                                : colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ),

                    // Actions
                    Flexible(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_currentPage > 0) ...[
                            IconButton.filledTonal(
                              visualDensity: VisualDensity.compact,
                              onPressed: _prevPage,
                              icon: const Icon(
                                Icons.arrow_forward_rounded,
                                size: 18,
                              ),
                              tooltip: 'قبلی',
                            ),
                            const SizedBox(width: 6),
                          ],
                          FilledButton(
                            onPressed: _nextPage,
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                            ),
                            child: Text(
                              _currentPage == _totalPages - 1
                                  ? 'شروع کار'
                                  : 'بعدی',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSlide({
    required IconData icon,
    required Color iconColor,
    required Color bgColor,
    required String title,
    required String description,
    Widget? alertBox,
    List<String> chips = const [],
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Center(
            child: Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: bgColor.withValues(alpha: 0.6),
                shape: BoxShape.circle,
                border: Border.all(
                  color: iconColor.withValues(alpha: 0.2),
                  width: 2,
                ),
              ),
              child: Icon(icon, size: 40, color: iconColor),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          if (alertBox != null) ...[alertBox, const SizedBox(height: 12)],
          Text(
            description,
            textAlign: TextAlign.justify,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),
          if (chips.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: chips
                  .map(
                    (chip) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest.withValues(
                          alpha: 0.4,
                        ),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: colorScheme.outlineVariant.withValues(
                            alpha: 0.3,
                          ),
                        ),
                      ),
                      child: Text(
                        chip,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}
