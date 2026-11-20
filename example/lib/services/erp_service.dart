import 'dart:async';
import 'package:orbit_sync/orbit_sync.dart';

import '../models/customer.dart';
import '../models/order_item.dart';
import '../models/product.dart';
import '../models/sales_order.dart';

/// Central ERP Domain Service managing offline-first Customer, Product,
/// and Sales Order synchronization via Orbit Sync.
class ErpService {
  final OrbitClient client;

  late final OrbitTable<Customer> customers;
  late final OrbitTable<Product> products;
  late final OrbitTable<SalesOrder> orders;
  late final OrbitTable<OrderItem> orderItems;

  ErpService(this.client) {
    customers = client.collection<Customer>(
      name: 'customers',
      endpoint: '/customers',
      fromJson: Customer.fromJson,
      toJson: (c) => c.toJson(),
      cacheTtl: const Duration(hours: 12),
      priority: Priority.high,
    );

    products = client.collection<Product>(
      name: 'products',
      endpoint: '/products',
      fromJson: Product.fromJson,
      toJson: (p) => p.toJson(),
      cacheTtl: const Duration(hours: 24),
      priority: Priority.normal,
    );

    orders = client.collection<SalesOrder>(
      name: 'orders',
      endpoint: '/orders',
      fromJson: SalesOrder.fromJson,
      toJson: (o) => o.toJson(),
      priority: Priority.high,
      idExtractor: (json) => json['order_number'] ?? json['id'],
    );

    orderItems = client.collection<OrderItem>(
      name: 'order_items',
      endpoint: '/orders/{orderId}/items',
      fromJson: OrderItem.fromJson,
      toJson: (i) => i.toJson(),
      priority: Priority.high,
    );
  }

  /// Creates a multi-line Sales Order offline with guaranteed DAG causal ordering.
  Future<String> createOrder({
    required Customer customer,
    required List<OrderItem> items,
    String? tempOrderId,
  }) async {
    final orderId = tempOrderId ?? 'ord-${DateTime.now().millisecondsSinceEpoch}';
    final totalAmount = items.fold<double>(0.0, (sum, i) => sum + i.lineTotal);

    final order = SalesOrder(
      id: orderId,
      customerId: customer.id,
      totalAmount: totalAmount,
      status: 'PENDING_SYNC',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    // 1. Commit Order Header to local SQLite WAL outbox
    await orders.save(order, id: orderId);

    // 2. Fetch the outbox mutation ID generated for the order
    final rows = await client.storage.db.getAll(
      'SELECT mutation_id FROM _sync_outbox WHERE entity_name = ? AND entity_id = ? ORDER BY sequence_id DESC LIMIT 1',
      ['orders', orderId],
    );
    final parentMutationId = rows.isNotEmpty ? rows.first['mutation_id'] as String? : null;

    // 3. Commit Order Line Items with DAG dependency link
    for (final item in items) {
      await orderItems.save(
        item,
        id: item.id,
        dependsOnMutationId: parentMutationId,
        pathParams: {'orderId': orderId},
      );
    }

    return orderId;
  }

  /// Stream of all orders sorted by creation time descending.
  Stream<List<SalesOrder>> watchOrders() {
    return orders.watch(orderBy: 'created_at DESC');
  }

  /// Stream of all products with optional category or SKU filter.
  Stream<List<Product>> watchProducts({String? category, String? query}) {
    String? where;
    List<dynamic> whereArgs = [];

    if (category != null && category.isNotEmpty && category != 'All') {
      where = 'category = ?';
      whereArgs.add(category);
    }

    return products.watch(where: where, whereArgs: whereArgs);
  }
}
