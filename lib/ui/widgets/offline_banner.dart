import 'dart:async';
import 'package:flutter/material.dart';

/// A slim, modern banner displayed when the application is offline
/// or when connectivity has just been restored.
class OfflineBanner extends StatefulWidget {
  const OfflineBanner({
    super.key,
    required this.isOffline,
    this.offlineMessage,
    this.restoredMessage,
  });

  /// Whether the device is offline.
  final bool isOffline;

  /// Custom offline message.
  final String? offlineMessage;

  /// Custom restored message.
  final String? restoredMessage;

  @override
  State<OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends State<OfflineBanner> {
  bool _showRestored = false;
  Timer? _restoredTimer;

  @override
  void didUpdateWidget(OfflineBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When transitioning from offline to online, show the restored message briefly.
    if (oldWidget.isOffline && !widget.isOffline) {
      _restoredTimer?.cancel();
      setState(() {
        _showRestored = true;
      });
      _restoredTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            _showRestored = false;
          });
        }
      });
    } else if (widget.isOffline) {
      _restoredTimer?.cancel();
      if (_showRestored) {
        setState(() {
          _showRestored = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _restoredTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final visible = widget.isOffline || _showRestored;

    return AnimatedCrossFade(
      crossFadeState:
          visible ? CrossFadeState.showFirst : CrossFadeState.showSecond,
      duration: const Duration(milliseconds: 250),
      firstCurve: Curves.easeOut,
      secondCurve: Curves.easeIn,
      firstChild: visible
          ? Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: widget.isOffline
                    ? (isDark
                        ? const Color(0xFF4A3410)
                        : const Color(0xFFFFF3CD))
                    : (isDark
                        ? const Color(0xFF1B432A)
                        : const Color(0xFFD4EDDA)),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: widget.isOffline
                      ? (isDark
                          ? const Color(0xFF8A6520)
                          : const Color(0xFFFFEEBA))
                      : (isDark
                          ? const Color(0xFF2E7D4E)
                          : const Color(0xFFC3E6CB)),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    widget.isOffline
                        ? Icons.wifi_off_rounded
                        : Icons.wifi_rounded,
                    size: 18,
                    color: widget.isOffline
                        ? (isDark
                            ? const Color(0xFFFFD580)
                            : const Color(0xFF856404))
                        : (isDark
                            ? const Color(0xFF85E3A0)
                            : const Color(0xFF155724)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.isOffline
                          ? (widget.offlineMessage ??
                              'حالت آفلاین • به اینترنت متصل نیستید (اطلاعات ذخیره‌شده نمایش داده می‌شوند)')
                          : (widget.restoredMessage ??
                              'اتصال به اینترنت برقرار شد'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: widget.isOffline
                            ? (isDark
                                ? const Color(0xFFFFD580)
                                : const Color(0xFF856404))
                            : (isDark
                                ? const Color(0xFF85E3A0)
                                : const Color(0xFF155724)),
                        fontWeight: FontWeight.w500,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox.shrink(),
      secondChild: const SizedBox.shrink(),
    );
  }
}
