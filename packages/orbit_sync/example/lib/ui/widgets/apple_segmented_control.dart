import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../apple_theme.dart';

/// iOS Segmented Control with animated sliding pill thumb and counts.
class AppleSegmentedControl<T> extends StatelessWidget {
  final Map<T, String> items;
  final Map<T, int>? counts;
  final T selected;
  final ValueChanged<T> onSelected;

  const AppleSegmentedControl({
    super.key,
    required this.items,
    this.counts,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final keys = items.keys.toList();

    return Container(
      height: 38,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppleTheme.tertiaryBg(context),
        borderRadius: BorderRadius.circular(AppleTheme.radiusMedium),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final totalWidth = constraints.maxWidth;
          final itemWidth = totalWidth / keys.length;
          final selectedIndex = keys.indexOf(selected);

          return Stack(
            children: [
              // Smooth sliding thumb
              AnimatedPositioned(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                left: selectedIndex * itemWidth,
                top: 0,
                bottom: 0,
                width: itemWidth,
                child: Container(
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF636366) : Colors.white,
                    borderRadius: BorderRadius.circular(AppleTheme.radiusMedium - 3),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                        blurRadius: 4,
                        offset: const Offset(0, 1.5),
                      ),
                    ],
                  ),
                ),
              ),
              // Interactive tabs
              Row(
                children: keys.map((key) {
                  final isSelected = key == selected;
                  final title = items[key]!;
                  final count = counts?[key];

                  return Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        if (key != selected) {
                          HapticFeedback.selectionClick();
                          onSelected(key);
                        }
                      },
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                                letterSpacing: -0.2,
                                color: isSelected
                                    ? (isDark ? Colors.white : Colors.black)
                                    : AppleTheme.secondaryLabel(context),
                              ),
                            ),
                            if (count != null && count > 0) ...[
                              const SizedBox(width: 5),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? AppleTheme.accent(context).withValues(alpha: 0.18)
                                      : AppleTheme.quaternaryBg(context),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '$count',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: isSelected
                                        ? AppleTheme.accent(context)
                                        : AppleTheme.secondaryLabel(context),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          );
        },
      ),
    );
  }
}
