import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../apple_theme.dart';

/// Apple Reminders-style circular checkbox with spring checkmark animation.
class AppleCheckbox extends StatefulWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? activeColor;

  const AppleCheckbox({
    super.key,
    required this.value,
    this.onChanged,
    this.activeColor,
  });

  @override
  State<AppleCheckbox> createState() => _AppleCheckboxState();
}

class _AppleCheckboxState extends State<AppleCheckbox> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _checkScale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: widget.value ? 1.0 : 0.0,
    );
    _checkScale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOutBack,
      ),
    );
  }

  @override
  void didUpdateWidget(AppleCheckbox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      if (widget.value) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    if (widget.onChanged == null) return;
    HapticFeedback.lightImpact();
    widget.onChanged!(!widget.value);
  }

  @override
  Widget build(BuildContext context) {
    final activeColor = widget.activeColor ?? AppleTheme.accent(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = widget.value
        ? activeColor
        : (isDark ? const Color(0xFF48484A) : const Color(0xFFC7C7CC));

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _handleTap,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.value ? activeColor : Colors.transparent,
            border: Border.all(
              color: borderColor,
              width: 1.8,
            ),
          ),
          child: Center(
            child: ScaleTransition(
              scale: _checkScale,
              child: const Icon(
                CupertinoIcons.checkmark_alt,
                size: 14,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
