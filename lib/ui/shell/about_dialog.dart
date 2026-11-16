import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/shared/app_version.dart';
import '../../core/shared/persian.dart';
import '../../platform/app_update_service.dart';
import '../../platform/platform_services.dart';
import '../app_state.dart';
import 'onboarding_sheet.dart';

/// Opens the official Material 3 "About Selfiyar" dialog.
Future<void> showAboutSelfiyarDialog(
  BuildContext context,
  AppServices services, {
  AppState? state,
}) async {
  await showDialog<void>(
    context: context,
    builder: (context) =>
        _AboutSelfiyarDialog(services: services, state: state),
  );
}

class _AboutSelfiyarDialog extends StatefulWidget {
  const _AboutSelfiyarDialog({required this.services, this.state});

  final AppServices services;
  final AppState? state;

  @override
  State<_AboutSelfiyarDialog> createState() => _AboutSelfiyarDialogState();
}

class _AboutSelfiyarDialogState extends State<_AboutSelfiyarDialog> {
  bool _isCheckingUpdate = false;
  AppUpdateCheckResult? _updateResult;

  @override
  void initState() {
    super.initState();
    unawaited(_checkUpdate(force: false));
  }

  Future<void> _checkUpdate({required bool force}) async {
    setState(() {
      _isCheckingUpdate = true;
    });

    final result = await widget.services.updates.checkForUpdates(force: force);

    if (mounted) {
      setState(() {
        _isCheckingUpdate = false;
        _updateResult = result;
      });

      if (result.hasUpdate && widget.state != null) {
        widget.state!.setHasAvailableUpdate(
          result.status == AppUpdateStatus.updateAvailable,
        );
      }
    }
  }

  Future<void> _openLink(String url, String title) async {
    try {
      await widget.services.bridge.openUrl(url);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('امکان باز کردن خودکار لینک وجود نداشت: $url'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // App Logo & Header
                Center(
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: colorScheme.primary.withValues(alpha: 0.15),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Image.asset(
                      'assets/images/app_logo.png',
                      errorBuilder: (context, error, stackTrace) => Container(
                        color: colorScheme.primaryContainer,
                        child: Icon(
                          Icons.restaurant,
                          size: 36,
                          color: colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'سِلفیار',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'دستیار هوشمند سامانه تغذیه دانشگاه شهید باهنر کرمان',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.secondaryContainer.withValues(
                        alpha: 0.5,
                      ),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'نسخه ${toPersianDigits(kAppVersion)}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colorScheme.onSecondaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Update Status Section
                _buildUpdateCard(theme, colorScheme),
                const SizedBox(height: 16),

                // Guide & Developer Cards
                _buildInfoTile(
                  icon: Icons.menu_book_rounded,
                  title: 'راهنمای استفاده از برنامه',
                  subtitle: 'مرور نکات مهم و امکانات کلیدی سِلفیار',
                  onTap: () => showOnboardingGuide(
                    context,
                    plainStore: widget.services.plainStore,
                  ),
                ),
                _buildInfoTile(
                  icon: Icons.code_rounded,
                  title: 'توسعه‌دهنده',
                  subtitle: 'صفحه گیت‌هاب Ashekofteh',
                  onTap: () =>
                      _openLink(kGitHubDeveloperUrl, 'گیت‌هاب توسعه‌دهنده'),
                ),
                _buildInfoTile(
                  icon: Icons.folder_special_outlined,
                  title: 'مخزن رسمی سورس‌کد',
                  subtitle: 'مشاهده پروژه آزاد در گیت‌هاب',
                  onTap: () =>
                      _openLink(kGitHubRepoUrl, 'مخزن گیت‌هاب سِلفیار'),
                ),
                _buildInfoTile(
                  icon: Icons.bug_report_outlined,
                  title: 'گزارش مشکل یا پیشنهاد',
                  subtitle: 'ثبت خطاها و پیشنهادات در GitHub Issues',
                  onTap: () =>
                      _openLink(kGitHubIssuesUrl, 'گزارش مشکل در گیت‌هاب'),
                ),

                const SizedBox(height: 12),
                Text(
                  'توسعه‌یافته به صورت متن‌باز و آزاد (FOSS) برای رفاه دانشجویان ❤️',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 16),

                // Close Button
                FilledButton.tonal(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('بستن'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUpdateCard(ThemeData theme, ColorScheme colorScheme) {
    if (_isCheckingUpdate) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'در حال بررسی نسخه جدید...',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }

    final result = _updateResult;
    if (result == null) {
      return const SizedBox.shrink();
    }

    switch (result.status) {
      case AppUpdateStatus.updateAvailable:
      case AppUpdateStatus.skipped:
        final release = result.release!;
        final downloadUrl = widget.services.updates.resolvePlatformDownloadUrl(
          release,
        );

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: colorScheme.primary.withValues(alpha: 0.3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.system_update_rounded,
                    color: colorScheme.primary,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'نسخه جدید (${toPersianDigits(release.version)}) موجود است!',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
              if (release.releaseNotes.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  release.releaseNotes,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onPrimaryContainer.withValues(
                      alpha: 0.85,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.download_rounded, size: 18),
                      label: const Text('دانلود و دریافت'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                      onPressed: () =>
                          _openLink(downloadUrl, 'دانلود بروزرسانی'),
                    ),
                  ),
                  if (result.status == AppUpdateStatus.updateAvailable) ...[
                    const SizedBox(width: 8),
                    TextButton(
                      child: const Text('نادیده گرفتن'),
                      onPressed: () async {
                        await widget.services.updates.skipVersion(
                          release.version,
                        );
                        if (mounted) {
                          setState(() {
                            _updateResult = AppUpdateCheckResult.skipped(
                              release: release,
                              checkedAt: DateTime.now(),
                            );
                          });
                          widget.state?.setHasAvailableUpdate(false);
                        }
                      },
                    ),
                  ],
                ],
              ),
            ],
          ),
        );

      case AppUpdateStatus.upToDate:
      case AppUpdateStatus.throttled:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(
                Icons.check_circle_outline_rounded,
                color: colorScheme.primary,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'شما از آخرین نسخه سِلفیار استفاده می‌کنید.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 20),
                tooltip: 'بررسی مجدد',
                onPressed: () => _checkUpdate(force: true),
              ),
            ],
          ),
        );

      case AppUpdateStatus.error:
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.errorContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline, color: colorScheme.error, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  result.errorMessage ?? 'خطا در بررسی بروزرسانی',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onErrorContainer,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => _checkUpdate(force: true),
                child: const Text('تلاش مجدد'),
              ),
            ],
          ),
        );
    }
  }

  Widget _buildInfoTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        leading: Icon(icon, color: colorScheme.primary, size: 22),
        title: Text(
          title,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: Icon(
          Icons.arrow_forward_ios_rounded,
          size: 14,
          color: colorScheme.outline,
        ),
        dense: true,
        onTap: onTap,
      ),
    );
  }
}
