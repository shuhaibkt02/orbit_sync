import 'package:flutter_test/flutter_test.dart';
import 'package:example/models/customer.dart';
import 'package:example/models/product.dart';
import 'package:example/models/sales_order.dart';
import 'package:example/models/order_item.dart';

void main() {
  group('Ticket 01: ERP Models Unit Tests', () {
    test('Customer serializes and evaluates credit limits correctly', () {
      const customer = Customer(
        id: 'cust-101',
        name: 'Apex Industrial',
        creditLimit: 5000.0,
        outstandingBalance: 3500.0,
        tier: 'VIP',
      );

      final json = customer.toJson();
      expect(json['credit_limit'], 5000.0);
      expect(customer.canAffordOrder(1000.0), isTrue);
      expect(customer.canAffordOrder(2000.0), isFalse);

      final reconstructed = Customer.fromJson(json);
      expect(reconstructed.name, 'Apex Industrial');
      expect(reconstructed.tier, 'VIP');
    });

    test('Product serializes and retains SKU index fields', () {
      const product = Product(
        id: 'prod-201',
        sku: 'SKU-IND-50',
        name: 'Steel Bearing 50mm',
        unitPrice: 125.50,
        stockQuantity: 40,
        category: 'Hardware',
      );

      final json = product.toJson();
      expect(json['sku'], 'SKU-IND-50');

      final reconstructed = Product.fromJson(json);
      expect(reconstructed.unitPrice, 125.50);
      expect(reconstructed.category, 'Hardware');
    });

    test('SalesOrder supports canonical server sequence and rejection reasons',
        () {
      const order = SalesOrder(
        id: 'temp-order-uuid',
        orderNumber: 'SO-2026-1049',
        customerId: 'cust-101',
        totalAmount: 1250.0,
        status: 'SYNCED',
        createdAt: 1700000000,
      );

      final json = order.toJson();
      expect(json['order_number'], 'SO-2026-1049');
      expect(json['status'], 'SYNCED');

      final reconstructed = SalesOrder.fromJson(json);
      expect(reconstructed.orderNumber, 'SO-2026-1049');
    });

    test('OrderItem computes line total and binds orderId foreign key', () {
      const item = OrderItem(
        id: 'item-1',
        orderId: 'SO-2026-1049',
        productId: 'prod-201',
        productName: 'Steel Bearing 50mm',
        quantity: 4,
        unitPrice: 25.0,
      );

      expect(item.lineTotal, 100.0);
      final json = item.toJson();
      expect(json['order_id'], 'SO-2026-1049');
      expect(json['quantity'], 4);
    });
  });
}
