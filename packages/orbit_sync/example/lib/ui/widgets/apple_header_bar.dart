import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:orbit_sync/orbit_sync.dart';
import '../apple_theme.dart';
import 'apple_pressable.dart';
import 'sync_telemetry_sheet.dart';

/// Frosted-glass header bar with live synchronization telemetry capsule.
class AppleHeaderBar extends StatelessWidget {
  final OrbitClient orbit;
  final Future<void> Function() onSeedDemo;

  const AppleHeaderBar({
    super.key,
    required this.orbit,
    required this.onSeedDemo,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: AppleTheme.glass(context, opacity: isDark ? 0.75 : 0.82),
            border: Border(
              bottom: BorderSide(
                color: AppleTheme.divider(context),
                width: 0.5,
              ),
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Tasks',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.6,
                              color: AppleTheme.label(context),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppleTheme.systemIndigo.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(AppleTheme.radiusPill),
                            ),
                            child: const Text(
                              'Orbit',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppleTheme.systemIndigo,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Text(
                        'Offline-First Sync Engine',
                        style: TextStyle(
                          fontSize: 12,
                          letterSpacing: -0.1,
                          color: AppleTheme.secondaryLabel(context),
                        ),
                      ),
                    ],
                  ),
                  StreamBuilder<SyncStatusSummary>(
                    stream: orbit.watchSummary(),
                    builder: (context, snapshot) => _buildCapsule(context, snapshot.data),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCapsule(BuildContext context, SyncStatusSummary? summary) {
    final pending = summary?.pending ?? 0;
    final inFlight = summary?.inFlight ?? 0;
    final hasFailures = summary?.hasFailures == true;

    Color bg;
    Color fg;
    IconData icon;
    String label;

    if (hasFailures) {
      bg = AppleTheme.destructive(context);
      fg = Colors.white;
      icon = CupertinoIcons.exclamationmark_triangle_fill;
      label = '${summary!.failed} Failed';
    } else if (inFlight > 0) {
      bg = AppleTheme.accent(context);
      fg = Colors.white;
      icon = CupertinoIcons.arrow_2_circlepath;
      label = 'Syncing';
    } else if (pending > 0) {
      bg = AppleTheme.warning(context).withValues(alpha: 0.18);
      fg = AppleTheme.warning(context);
      icon = CupertinoIcons.cloud_upload_fill;
      label = '$pending Pending';
    } else {
      bg = AppleTheme.success(context).withValues(alpha: 0.16);
      fg = AppleTheme.success(context);
      icon = CupertinoIcons.checkmark_alt_circle_fill;
      label = 'Synced';
    }

    return ApplePressable(
      onTap: () {
        HapticFeedback.lightImpact();
        SyncTelemetrySheet.show(context, client: orbit, onSeedDemo: onSeedDemo);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(AppleTheme.radiusPill),
          border: Border.all(color: fg.withValues(alpha: 0.3), width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
          ],
        ),
      ),
    );
  }
}
