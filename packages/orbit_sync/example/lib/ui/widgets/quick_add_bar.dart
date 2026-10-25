import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../apple_theme.dart';
import 'apple_pressable.dart';

/// Apple Reminders-style frosted quick-add capsule.
class QuickAddBar extends StatefulWidget {
  final ValueChanged<String> onAdd;

  const QuickAddBar({
    super.key,
    required this.onAdd,
  });

  @override
  State<QuickAddBar> createState() => _QuickAddBarState();
}

class _QuickAddBarState extends State<QuickAddBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final has = _controller.text.trim().isNotEmpty;
      if (has != _hasText) {
        setState(() => _hasText = has);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    widget.onAdd(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppleTheme.radiusSheet),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: AppleTheme.glass(context, opacity: isDark ? 0.75 : 0.85),
            borderRadius: BorderRadius.circular(AppleTheme.radiusSheet),
            border: Border.all(
              color: AppleTheme.specularBorder(context),
              width: 0.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            children: [
              Icon(
                CupertinoIcons.circle,
                size: 20,
                color: AppleTheme.tertiaryLabel(context),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  textInputAction: TextInputAction.done,
                  style: TextStyle(
                    fontSize: 16,
                    color: AppleTheme.label(context),
                  ),
                  decoration: InputDecoration(
                    hintText: 'Add a new task (works offline)...',
                    hintStyle: TextStyle(
                      fontSize: 15,
                      color: AppleTheme.tertiaryLabel(context),
                    ),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              AnimatedScale(
                scale: _hasText ? 1.0 : 0.8,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutBack,
                child: AnimatedOpacity(
                  opacity: _hasText ? 1.0 : 0.3,
                  duration: const Duration(milliseconds: 180),
                  child: ApplePressable(
                    onTap: _hasText ? _submit : null,
                    pressedScale: 0.9,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: AppleTheme.accent(context),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        CupertinoIcons.arrow_up,
                        size: 18,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
