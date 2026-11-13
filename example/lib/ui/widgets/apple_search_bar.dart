import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../apple_theme.dart';

/// Clean iOS-style search input with one-tap clear action.
class AppleSearchBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const AppleSearchBar({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: AppleTheme.tertiaryBg(context),
        borderRadius: BorderRadius.circular(AppleTheme.radiusMedium),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Icon(
            CupertinoIcons.search,
            size: 17,
            color: AppleTheme.secondaryLabel(context),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: TextStyle(fontSize: 14, color: AppleTheme.label(context)),
              decoration: InputDecoration(
                hintText: 'Search tasks...',
                hintStyle: TextStyle(
                  fontSize: 14,
                  color: AppleTheme.secondaryLabel(context),
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            GestureDetector(
              onTap: onClear,
              child: Icon(
                CupertinoIcons.clear_circled_solid,
                size: 16,
                color: AppleTheme.tertiaryLabel(context),
              ),
            ),
        ],
      ),
    );
  }
}
