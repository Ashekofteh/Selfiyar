import 'dart:math' as math;
import 'package:flutter/material.dart';

/// An animated refresh button that rotates smoothly while syncing.
///
/// While [isSyncing] is true, the button spins continuously and user taps are
/// disabled to prevent re-entrant calls. When [isSyncing] flips back to false,
/// the rotation gracefully completes to its initial upright position using
/// [Curves.easeOut] instead of snapping to an abrupt stop.
class RotatingRefreshButton extends StatefulWidget {
  const RotatingRefreshButton({
    super.key,
    required this.isSyncing,
    this.onPressed,
    this.icon = Icons.refresh,
    this.iconSize,
    this.tooltip = 'به‌روزرسانی از سامانه',
    this.syncingTooltip = 'در حال به‌روزرسانی...',
  });

  /// Whether a sync or refresh operation is actively running.
  final bool isSyncing;

  /// Triggered when the button is tapped while not syncing.
  final VoidCallback? onPressed;

  /// The icon to display, defaults to [Icons.refresh].
  final IconData icon;

  /// Custom icon size if desired.
  final double? iconSize;

  /// Tooltip displayed when idle.
  final String tooltip;

  /// Tooltip displayed when syncing.
  final String syncingTooltip;

  @override
  State<RotatingRefreshButton> createState() => _RotatingRefreshButtonState();
}

class _RotatingRefreshButtonState extends State<RotatingRefreshButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    if (widget.isSyncing) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant RotatingRefreshButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isSyncing != oldWidget.isSyncing) {
      if (widget.isSyncing) {
        _controller.repeat();
      } else {
        _completeRotationSmoothly();
      }
    }
  }

  Future<void> _completeRotationSmoothly() async {
    final current = _controller.value;
    if (current == 0.0 || current >= 0.98) {
      if (mounted && !widget.isSyncing) {
        _controller.reset();
      }
      return;
    }

    final remaining = 1.0 - current;
    final remainingMillis = (remaining * 1000).round().clamp(50, 1000);

    try {
      await _controller.animateTo(
        1.0,
        duration: Duration(milliseconds: remainingMillis),
        curve: Curves.easeOut,
      );
      if (mounted && !widget.isSyncing) {
        _controller.reset();
      }
    } on TickerCanceled {
      // Ignored if cancelled by new animation or disposal.
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isSyncing = widget.isSyncing;
    final effectiveTooltip = isSyncing ? widget.syncingTooltip : widget.tooltip;
    final effectiveOnPressed = isSyncing ? null : widget.onPressed;

    return IconButton(
      iconSize: widget.iconSize,
      tooltip: effectiveTooltip,
      onPressed: effectiveOnPressed,
      icon: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Transform.rotate(
            angle: _controller.value * 2 * math.pi,
            child: child,
          );
        },
        child: Icon(widget.icon),
      ),
    );
  }
}
