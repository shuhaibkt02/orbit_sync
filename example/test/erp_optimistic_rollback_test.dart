import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'package:example/mock_backend.dart';
import 'package:example/models/customer.dart';
import 'package:example/models/order_item.dart';
import 'package:example/services/erp_service.dart';

void main() {
  group('Ticket 04: Optimistic Baseline Snapshot Rollback & RFC 9457 Rejection', () {
    late Directory tempDir;
    late MockBackend backend;
    late OrbitClient client;
    late ErpService erp;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('orbit_erp_rollback_test_');
      backend = await MockBackend.start();
      client = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/erp_rollback.db',
        baseUrl: backend.url,
      );
      erp = ErpService(client);
    });

    tearDown(() async {
      await client.close();
      await backend.stop();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'Server HTTP 422 business rejection rolls back optimistic state and captures RFC 9457 error in outbox DLQ',
        () async {
      // 1. Enable credit rejection on backend
      backend.simulateCreditRejection = true;

      // Customer cust-102 has creditLimit: 3000, outstandingBalance: 2400 (available: 600)
      const customer = Customer(
        id: 'cust-102',
        name: 'Apex Manufacturing',
        creditLimit: 3000.0,
        outstandingBalance: 2400.0,
      );

      final items = [
        const OrderItem(
          id: 'item-exceed-1',
          orderId: 'temp-so-overlimit',
          productId: 'prod-003',
          productName: 'Modular PLC CPU Unit 24V',
          quantity: 2,
          unitPrice: 850.0, // Total = 1700.0 (exceeds available 600.0)
        ),
      ];

      // 2. Commit order locally (0ms)
      final tempOrderId = await erp.createOrder(
        customer: customer,
        items: items,
        tempOrderId: 'temp-so-overlimit',
      );

      // Verify order was saved locally before sync
      final orderBeforeSync = await erp.orders.get(tempOrderId);
      expect(orderBeforeSync, isNotNull);
      expect(orderBeforeSync!.totalAmount, 1700.0);

      // 3. Trigger sync to push to backend
      await client.syncNow();

      // Give worker a moment to process the 422 response
      await Future.delayed(const Duration(milliseconds: 300));

      // 4. Verify outbox captured the validation error
      final outboxRows = await client.storage.db.getAll(
        "SELECT * FROM _sync_outbox WHERE entity_name = 'orders' AND entity_id = ?",
        [tempOrderId],
      );
      expect(outboxRows.isNotEmpty, isTrue);
      final outboxRecord = outboxRows.first;
      expect(outboxRecord['status'], 'validation_error');
      expect(outboxRecord['error_details_json'], contains('Credit Limit Exceeded'));

      // 5. Verify local active entity table was rolled back (removed optimistic insert)
      final orderAfterRollback = await erp.orders.get(tempOrderId);
      expect(orderAfterRollback, isNull);
    });
  });
}
