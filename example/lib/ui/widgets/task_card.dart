import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:orbit_sync/orbit_sync.dart';
import '../../models/task.dart';
import '../apple_theme.dart';
import 'apple_checkbox.dart';
import 'apple_pressable.dart';

/// Grouped inset task row with Apple swipe gestures, haptic feedback, and outbox indicators.
class TaskCard extends StatelessWidget {
  final OrbitRecord<Task> record;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;
  final bool isLast;

  const TaskCard({
    super.key,
    required this.record,
    required this.onToggle,
    required this.onDelete,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final task = record.data;
    final isDone = task.isDone;
    final status = record.status;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Dismissible(
      key: ValueKey(task.id ?? task.title),
      direction: DismissDirection.horizontal,
      onUpdate: (details) {
        if (details.reached && !details.previousReached) {
          HapticFeedback.selectionClick();
        }
      },
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.endToStart) {
          // Swipe left to delete
          HapticFeedback.mediumImpact();
          onDelete();
          return false; // Handled by callback
        } else {
          // Swipe right to toggle
          HapticFeedback.lightImpact();
          onToggle(!isDone);
          return false;
        }
      },
      background: Container(
        color: AppleTheme.success(context),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        child: const Icon(
          CupertinoIcons.checkmark_alt_circle_fill,
          color: Colors.white,
          size: 24,
        ),
      ),
      secondaryBackground: Container(
        color: AppleTheme.destructive(context),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(
          CupertinoIcons.trash_fill,
          color: Colors.white,
          size: 22,
        ),
      ),
      child: Column(
        children: [
          ApplePressable(
            onTap: () => onToggle(!isDone),
            behavior: HitTestBehavior.opaque,
            pressedScale: 0.99,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  // Circular Apple Checkbox
                  AppleCheckbox(
                    value: isDone,
                    onChanged: (val) => onToggle(val),
                  ),
                  const SizedBox(width: 12),

                  // Title & Metadata
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 180),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight:
                                isDone ? FontWeight.w400 : FontWeight.w500,
                            letterSpacing: -0.2,
                            color: isDone
                                ? AppleTheme.secondaryLabel(context)
                                : AppleTheme.label(context),
                            decoration: isDone
                                ? TextDecoration.lineThrough
                                : TextDecoration.none,
                            decorationColor: AppleTheme.secondaryLabel(context),
                          ),
                          child: Text(task.title),
                        ),
                      ],
                    ),
                  ),

                  // Sync Status Indicator Badge
                  _buildSyncStatusBadge(context, status),

                  const SizedBox(width: 4),

                  // Quick Action Menu
                  PopupMenuButton<String>(
                    icon: Icon(
                      CupertinoIcons.ellipsis,
                      size: 18,
                      color: AppleTheme.tertiaryLabel(context),
                    ),
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(AppleTheme.radiusMedium),
                    ),
                    color: isDark ? const Color(0xFF2C2C2E) : Colors.white,
                    itemBuilder: (ctx) => [
                      PopupMenuItem(
                        value: 'toggle',
                        child: Row(
                          children: [
                            Icon(
                              isDone
                                  ? CupertinoIcons.circle
                                  : CupertinoIcons.checkmark_circle,
                              size: 16,
                              color: AppleTheme.label(context),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              isDone ? 'Mark as Incomplete' : 'Mark as Done',
                              style: TextStyle(
                                fontSize: 14,
                                color: AppleTheme.label(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(
                              CupertinoIcons.trash,
                              size: 16,
                              color: AppleTheme.destructive(context),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Delete Task',
                              style: TextStyle(
                                fontSize: 14,
                                color: AppleTheme.destructive(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    onSelected: (val) {
                      if (val == 'toggle') onToggle(!isDone);
                      if (val == 'delete') onDelete();
                    },
                  ),
                ],
              ),
            ),
          ),
          if (!isLast)
            Padding(
              padding: const EdgeInsets.only(left: 48),
              child: Divider(
                height: 1,
                thickness: 0.5,
                color: AppleTheme.divider(context),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSyncStatusBadge(BuildContext context, OrbitSyncStatus status) {
    switch (status) {
      case OrbitSyncStatus.pending:
        return Tooltip(
          message: 'Saved locally in SQLite outbox. Waiting for sync.',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
            decoration: BoxDecoration(
              color: AppleTheme.warning(context).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppleTheme.radiusPill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  CupertinoIcons.cloud_upload,
                  size: 12,
                  color: AppleTheme.warning(context),
                ),
                const SizedBox(width: 4),
                Text(
                  'Offline',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppleTheme.warning(context),
                  ),
                ),
              ],
            ),
          ),
        );

      case OrbitSyncStatus.inFlight:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
          decoration: BoxDecoration(
            color: AppleTheme.accent(context).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppleTheme.radiusPill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  valueColor:
                      AlwaysStoppedAnimation(AppleTheme.accent(context)),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                'Syncing',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppleTheme.accent(context),
                ),
              ),
            ],
          ),
        );

      case OrbitSyncStatus.failed:
      case OrbitSyncStatus.rejected:
        return Tooltip(
          message: record.errorMessage ?? 'Sync failure in dead letter queue',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
            decoration: BoxDecoration(
              color: AppleTheme.destructive(context).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppleTheme.radiusPill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  CupertinoIcons.exclamationmark_circle,
                  size: 12,
                  color: AppleTheme.destructive(context),
                ),
                const SizedBox(width: 4),
                Text(
                  'Failed',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppleTheme.destructive(context),
                  ),
                ),
              ],
            ),
          ),
        );

      case OrbitSyncStatus.synced:
      case OrbitSyncStatus.pendingDelete:
        return const SizedBox.shrink();
    }
  }
}
