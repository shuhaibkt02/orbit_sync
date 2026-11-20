import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'package:example/mock_backend.dart';
import 'package:example/models/customer.dart';
import 'package:example/models/order_item.dart';
import 'package:example/services/erp_service.dart';

void main() {
  group('Ticket 03: Master-Detail Parent-Child DAG & Canonical ID Remapping', () {
    late Directory tempDir;
    late MockBackend backend;
    late OrbitClient client;
    late ErpService erp;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('orbit_erp_dag_test_');
      backend = await MockBackend.start();
      client = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/erp_dag.db',
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
        'Offline multi-line order booking holds children and remaps to canonical server ID upon reconnect',
        () async {
      // 1. Simulate field offline operation (Airplane Mode)
      backend.isOutage = true;

      const customer = Customer(
        id: 'cust-101',
        name: 'Acme Corp Industrial',
        creditLimit: 5000.0,
        outstandingBalance: 1000.0,
      );

      final items = [
        const OrderItem(
          id: 'item-uuid-1',
          orderId: 'temp-so-99',
          productId: 'prod-001',
          productName: 'Precision Ball Bearing 50mm',
          quantity: 2,
          unitPrice: 45.0,
        ),
        const OrderItem(
          id: 'item-uuid-2',
          orderId: 'temp-so-99',
          productId: 'prod-002',
          productName: 'Hydraulic Flow Control Valve',
          quantity: 1,
          unitPrice: 320.0,
        ),
      ];

      // 2. Commit order offline with zero delay (0ms)
      final tempOrderId = await erp.createOrder(
        customer: customer,
        items: items,
        tempOrderId: 'temp-so-99',
      );

      // Verify immediate local presence in SQLite WAL
      final localOrder = await erp.orders.get(tempOrderId);
      expect(localOrder, isNotNull);
      expect(localOrder!.totalAmount, 410.0);

      final localItems = await erp.orderItems
          .query(where: 'order_id = ?', whereArgs: [tempOrderId]);
      expect(localItems.length, 2);

      // Verify outbox staging
      final outboxRows = await client.storage.db
          .getAll('SELECT * FROM _sync_outbox ORDER BY sequence_id ASC');
      expect(outboxRows.length, 3); // 1 parent order + 2 child items

      // 3. Reconnect to network
      backend.isOutage = false;

      // 4. Trigger sync and await completion
      await client.syncNow();

      // Wait a moment for background workers to settle
      await Future.delayed(const Duration(milliseconds: 300));

      // 5. Verify ID Remapping in _sync_id_map
      final idMapRows = await client.storage.db.getAll('SELECT * FROM _sync_id_map');
      expect(idMapRows.isNotEmpty, isTrue);
      expect(idMapRows.first['local_temp_id'], 'temp-so-99');
      expect(idMapRows.first['canonical_server_id'], 'SO-2026-1001');

      // 6. Verify children were uploaded without errors
      final remainingOutbox = await client.storage.db.getAll("SELECT * FROM _sync_outbox WHERE status != 'synced'");
      expect(remainingOutbox.isEmpty, isTrue);
    });
  });
}
