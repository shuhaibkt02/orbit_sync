import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../apple_theme.dart';
import 'apple_pressable.dart';

/// Floating Apple capsule toast providing non-intrusive Undo agency.
class UndoToast extends StatelessWidget {
  final String message;
  final VoidCallback onUndo;
  final VoidCallback onDismiss;

  const UndoToast({
    super.key,
    required this.message,
    required this.onUndo,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppleTheme.radiusPill),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          decoration: BoxDecoration(
            color: const Color(0xE01C1C1E),
            borderRadius: BorderRadius.circular(AppleTheme.radiusPill),
            border: Border.all(
              color: const Color(0x33FFFFFF),
              width: 0.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                CupertinoIcons.trash,
                size: 16,
                color: Color(0xFF8E8E93),
              ),
              const SizedBox(width: 8),
              Text(
                message,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 14),
              ApplePressable(
                onTap: () {
                  HapticFeedback.lightImpact();
                  onUndo();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppleTheme.systemBlue.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(AppleTheme.radiusPill),
                  ),
                  child: const Text(
                    'Undo',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0A84FF),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onDismiss,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(
                    CupertinoIcons.xmark,
                    size: 14,
                    color: Color(0xFF636366),
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
