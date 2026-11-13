import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:orbit_sync/orbit_sync.dart';
import '../apple_theme.dart';
import 'apple_pressable.dart';

/// Apple modal sheet displaying real-time Orbit offline sync engine metrics.
class SyncTelemetrySheet extends StatefulWidget {
  final OrbitClient client;
  final Future<void> Function() onSeedDemo;

  const SyncTelemetrySheet({
    super.key,
    required this.client,
    required this.onSeedDemo,
  });

  static Future<void> show(BuildContext context, {
    required OrbitClient client,
    required Future<void> Function() onSeedDemo,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SyncTelemetrySheet(
        client: client,
        onSeedDemo: onSeedDemo,
      ),
    );
  }

  @override
  State<SyncTelemetrySheet> createState() => _SyncTelemetrySheetState();
}

class _SyncTelemetrySheetState extends State<SyncTelemetrySheet> with SingleTickerProviderStateMixin {
  late final AnimationController _syncSpinController;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _syncSpinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  @override
  void dispose() {
    _syncSpinController.dispose();
    super.dispose();
  }

  Future<void> _triggerSync() async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);
    _syncSpinController.repeat();
    HapticFeedback.mediumImpact();

    try {
      await widget.client.sync(force: true);
    } catch (e) {
      debugPrint('[Orbit Sync Demo] Sync error: $e');
    } finally {
      if (mounted) {
        _syncSpinController.stop();
        _syncSpinController.reset();
        setState(() => _isSyncing = false);
      }
    }
  }

  Future<void> _retryFailures() async {
    HapticFeedback.lightImpact();
    await widget.client.retryAllFailed(syncNow: true);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = AppleTheme.secondaryBg(context);

    return Container(
      decoration: BoxDecoration(
        color: AppleTheme.bg(context),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppleTheme.radiusSheet),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 30,
            offset: const Offset(0, -10),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Grabber Handle
              Center(
                child: Container(
                  width: 38,
                  height: 5,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF48484A) : const Color(0xFFD1D1D6),
                    borderRadius: BorderRadius.circular(AppleTheme.radiusPill),
                  ),
                ),
              ),
              const SizedBox(height: 18),

              // Sheet Header
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: isDark
                            ? [AppleTheme.systemIndigoDark, AppleTheme.systemBlueDark]
                            : [AppleTheme.systemIndigo, AppleTheme.systemBlue],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      CupertinoIcons.cloud_upload_fill,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Orbit Sync Engine',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                            color: AppleTheme.label(context),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'SQLite Outbox & Reactive Observability',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppleTheme.secondaryLabel(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      CupertinoIcons.xmark_circle_fill,
                      color: AppleTheme.tertiaryLabel(context),
                      size: 26,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Live Stream Summary Metrics
              StreamBuilder<SyncStatusSummary>(
                stream: widget.client.watchSummary(),
                builder: (context, snapshot) {
                  final summary = snapshot.data;
                  final pending = summary?.pending ?? 0;
                  final inFlight = summary?.inFlight ?? 0;
                  final synced = summary?.synced ?? 0;
                  final failed = summary?.failed ?? 0;

                  return Column(
                    children: [
                      // 4-Card Metric Grid
                      Row(
                        children: [
                          Expanded(
                            child: _buildMetricTile(
                              context,
                              title: 'Pending',
                              value: '$pending',
                              subtitle: 'In local outbox',
                              color: AppleTheme.warning(context),
                              icon: CupertinoIcons.clock_fill,
                              cardBg: cardBg,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildMetricTile(
                              context,
                              title: 'In Flight',
                              value: '$inFlight',
                              subtitle: 'Crossing network',
                              color: AppleTheme.accent(context),
                              icon: CupertinoIcons.arrow_2_circlepath,
                              cardBg: cardBg,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _buildMetricTile(
                              context,
                              title: 'Synced',
                              value: '$synced',
                              subtitle: 'Remote confirmed',
                              color: AppleTheme.success(context),
                              icon: CupertinoIcons.checkmark_circle_fill,
                              cardBg: cardBg,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildMetricTile(
                              context,
                              title: 'Failed (DLQ)',
                              value: '$failed',
                              subtitle: failed > 0 ? 'Action required' : 'Zero failures',
                              color: failed > 0
                                  ? AppleTheme.destructive(context)
                                  : AppleTheme.secondaryLabel(context),
                              icon: CupertinoIcons.exclamationmark_triangle_fill,
                              cardBg: cardBg,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Health Details Card
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(AppleTheme.radiusMedium),
                          border: Border.all(
                            color: AppleTheme.specularBorder(context),
                            width: 0.5,
                          ),
                        ),
                        child: Column(
                          children: [
                            _buildInfoRow(
                              context,
                              label: 'Database Status',
                              value: 'orbit_tasks.db (WAL)',
                              valueColor: AppleTheme.label(context),
                            ),
                            Divider(
                              height: 16,
                              thickness: 0.5,
                              color: AppleTheme.divider(context),
                            ),
                            _buildInfoRow(
                              context,
                              label: 'Outbox State',
                              value: pending == 0 && inFlight == 0 && failed == 0
                                  ? 'All records up to date'
                                  : '$pending mutation(s) queued',
                              valueColor: pending == 0
                                  ? AppleTheme.success(context)
                                  : AppleTheme.warning(context),
                            ),
                            if (failed > 0) ...[
                              Divider(
                                height: 16,
                                thickness: 0.5,
                                color: AppleTheme.divider(context),
                              ),
                              _buildInfoRow(
                                context,
                                label: 'Dead Letter Queue',
                                value: '$failed failed operations',
                                valueColor: AppleTheme.destructive(context),
                              ),
                            ],
                          ],
                        ),
                      ),

                      if (failed > 0) ...[
                        const SizedBox(height: 12),
                        ApplePressable(
                          onTap: _retryFailures,
                          child: Container(
                            height: 44,
                            decoration: BoxDecoration(
                              color: AppleTheme.destructive(context).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(AppleTheme.radiusMedium),
                            ),
                            child: Center(
                              child: Text(
                                'Retry Failed Mutations',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: AppleTheme.destructive(context),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),

              // Action Buttons
              Row(
                children: [
                  Expanded(
                    child: ApplePressable(
                      onTap: () async {
                        HapticFeedback.lightImpact();
                        await widget.onSeedDemo();
                        if (context.mounted) {
                          Navigator.of(context).pop();
                        }
                      },
                      child: Container(
                        height: 50,
                        decoration: BoxDecoration(
                          color: AppleTheme.tertiaryBg(context),
                          borderRadius: BorderRadius.circular(AppleTheme.radiusMedium),
                        ),
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                CupertinoIcons.sparkles,
                                size: 18,
                                color: AppleTheme.label(context),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Seed Demo Tasks',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: AppleTheme.label(context),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ApplePressable(
                      onTap: _triggerSync,
                      child: Container(
                        height: 50,
                        decoration: BoxDecoration(
                          color: AppleTheme.accent(context),
                          borderRadius: BorderRadius.circular(AppleTheme.radiusMedium),
                          boxShadow: [
                            BoxShadow(
                              color: AppleTheme.accent(context).withValues(alpha: 0.3),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              RotationTransition(
                                turns: _syncSpinController,
                                child: const Icon(
                                  CupertinoIcons.arrow_2_circlepath,
                                  size: 18,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _isSyncing ? 'Syncing...' : 'Sync Now',
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetricTile(
    BuildContext context, {
    required String title,
    required String value,
    required String subtitle,
    required Color color,
    required IconData icon,
    required Color cardBg,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(AppleTheme.radiusMedium),
        border: Border.all(
          color: AppleTheme.specularBorder(context),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppleTheme.secondaryLabel(context),
                ),
              ),
              Icon(icon, size: 16, color: color),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.6,
              color: AppleTheme.label(context),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 11,
              color: AppleTheme.secondaryLabel(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(
    BuildContext context, {
    required String label,
    required String value,
    required Color valueColor,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: AppleTheme.secondaryLabel(context),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: valueColor,
          ),
        ),
      ],
    );
  }
}
