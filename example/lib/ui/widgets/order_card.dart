import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../models/sales_order.dart';
import '../apple_theme.dart';
import 'apple_pressable.dart';

/// Card displaying Sales Order summary with live sync status badge.
class OrderCard extends StatelessWidget {
  final SalesOrder order;
  final VoidCallback? onTap;

  const OrderCard({super.key, required this.order, this.onTap});

  @override
  Widget build(BuildContext context) {
    final (badgeText, badgeColor, badgeBg) = switch (order.status) {
      'SYNCED' => (
          order.orderNumber ?? 'Synced',
          CupertinoColors.systemGreen,
          CupertinoColors.systemGreen.withValues(alpha: 0.12)
        ),
      'REJECTED' => (
          'Rejected',
          CupertinoColors.systemRed,
          CupertinoColors.systemRed.withValues(alpha: 0.12)
        ),
      'HELD' => (
          'Held (DAG)',
          CupertinoColors.systemPurple,
          CupertinoColors.systemPurple.withValues(alpha: 0.12)
        ),
      _ => (
          'Pending Sync',
          CupertinoColors.systemOrange,
          CupertinoColors.systemOrange.withValues(alpha: 0.12)
        ),
    };

    final dateStr = DateTime.fromMillisecondsSinceEpoch(order.createdAt)
        .toLocal()
        .toString()
        .split('.')[0];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ApplePressable(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: order.status == 'REJECTED'
                  ? CupertinoColors.systemRed.withValues(alpha: 0.4)
                  : Colors.black.withValues(alpha: 0.06),
              width: order.status == 'REJECTED' ? 1.5 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    order.orderNumber ?? order.id,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: badgeBg,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      badgeText,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: badgeColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Customer: ${order.customerId}',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    '\$${order.totalAmount.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: AppleTheme.accentBlue,
                    ),
                  ),
                ],
              ),
              if (order.rejectionReason != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: CupertinoColors.systemRed.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(CupertinoIcons.exclamationmark_triangle_fill,
                          color: CupertinoColors.systemRed, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          order.rejectionReason!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: CupertinoColors.systemRed,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Text(
                dateStr,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
