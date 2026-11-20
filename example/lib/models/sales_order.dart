class SalesOrder {
  final String id;
  final String? orderNumber; // Canonical server sequence ID (e.g. SO-2026-1001)
  final String customerId;
  final double totalAmount;
  final String status; // DRAFT, PENDING_SYNC, SYNCED, REJECTED
  final String? rejectionReason;
  final int createdAt;

  const SalesOrder({
    required this.id,
    this.orderNumber,
    required this.customerId,
    required this.totalAmount,
    this.status = 'PENDING_SYNC',
    this.rejectionReason,
    required this.createdAt,
  });

  factory SalesOrder.fromJson(Map<String, dynamic> json) => SalesOrder(
        id: json['id'] as String,
        orderNumber: json['order_number'] as String?,
        customerId: json['customer_id'] as String,
        totalAmount: (json['total_amount'] as num).toDouble(),
        status: json['status'] as String? ?? 'PENDING_SYNC',
        rejectionReason: json['rejection_reason'] as String?,
        createdAt: (json['created_at'] as num).toInt(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        if (orderNumber != null) 'order_number': orderNumber,
        'customer_id': customerId,
        'total_amount': totalAmount,
        'status': status,
        if (rejectionReason != null) 'rejection_reason': rejectionReason,
        'created_at': createdAt,
      };
}
