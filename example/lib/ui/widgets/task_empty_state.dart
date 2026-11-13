import 'package:flutter/cupertino.dart';
import '../apple_theme.dart';
import 'apple_pressable.dart';

/// Clean Apple-style empty state with offline readiness explanation and suggestion chips.
class TaskEmptyState extends StatelessWidget {
  final bool hasAnyTasks;
  final bool isSearching;
  final ValueChanged<String> onSelectSuggestion;

  const TaskEmptyState({
    super.key,
    required this.hasAnyTasks,
    required this.isSearching,
    required this.onSelectSuggestion,
  });

  @override
  Widget build(BuildContext context) {
    if (!hasAnyTasks) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: AppleTheme.accent(context).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  CupertinoIcons.checkmark_shield_fill,
                  size: 36,
                  color: AppleTheme.accent(context),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Ready For Offline Tasks',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                  color: AppleTheme.label(context),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Everything you create is saved to SQLite immediately and synced when connected.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: AppleTheme.secondaryLabel(context),
                ),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _chip(context, '🛒 Buy groceries'),
                  _chip(context, '🚀 Test airplane mode'),
                  _chip(context, '📚 WWDC design study'),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            CupertinoIcons.tray,
            size: 40,
            color: AppleTheme.tertiaryLabel(context),
          ),
          const SizedBox(height: 12),
          Text(
            isSearching ? 'No Matching Tasks' : 'No Tasks in this Filter',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppleTheme.secondaryLabel(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String text) {
    return ApplePressable(
      onTap: () => onSelectSuggestion(text),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppleTheme.secondaryBg(context),
          borderRadius: BorderRadius.circular(AppleTheme.radiusPill),
          border: Border.all(
            color: AppleTheme.specularBorder(context),
            width: 0.5,
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: AppleTheme.label(context),
          ),
        ),
      ),
    );
  }
}
