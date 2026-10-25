import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:offline_sync/offline_sync.dart';
import 'storage_test_helpers.dart';

void main() {
  group('Layer 1 Storage: Dynamic Schema, Typings & Reactivity', () {
    late Directory tempDir;
    late SyncStorage storage;

    setUp(() async {
      final res = await createTestStorage();
      tempDir = res.tempDir;
      storage = res.storage;
    });

    tearDown(() async {
      await storage.close();
      tempDir.deleteSync(recursive: true);
    });

    test('Test Case 4: Zero-Codegen Reactivity with db.watch()', () async {
      final emissions = <int>[];
      final completer = Completer<void>();

      final sub = storage.watch('SELECT * FROM tasks ORDER BY id;').listen((rs) {
        emissions.add(rs.length);
        if (emissions.length == 3) {
          completer.complete();
        }
      });

      await Future<void>.delayed(const Duration(milliseconds: 50));

      await storage.save(
        entity: 'tasks',
        id: 'task-watch-1',
        data: {'title': 'First reactive item', 'priority': 'high'},
      );

      await storage.save(
        entity: 'tasks',
        id: 'task-watch-2',
        data: {'title': 'Second reactive item', 'priority': 'medium'},
      );

      await completer.future.timeout(const Duration(seconds: 3));
      await sub.cancel();

      expect(emissions, equals([0, 1, 2]));
    });

    test('Test Case 5: Native SQLite Data Type Affinity on Dynamic Columns', () async {
      await storage.save(
        entity: 'tasks',
        id: 'task-types-1',
        data: {
          'title': 'Typed Task',
          'total_count': 50,
          'unit_price': 19.95,
          'is_completed': true,
        },
      );

      final tableInfo = await storage.db.getAll('PRAGMA table_info(tasks);');
      final typeMap = {for (final r in tableInfo) r['name'] as String: r['type'] as String};

      expect(typeMap['total_count'], 'INTEGER');
      expect(typeMap['unit_price'], 'REAL');
      expect(typeMap['is_completed'], 'INTEGER');

      final gtResult = await storage.db.getAll('SELECT id FROM tasks WHERE total_count > 40;');
      expect(gtResult.length, 1);
      expect(gtResult.first['id'], 'task-types-1');
    });

    test('Test Case 10: External Host Domain Model (End-to-End Serialization & Query Cycle)', () async {
      final order1 = MockExternalOrder(
        id: 'ord-alpha-101',
        customerId: 'cust-alpha-99',
        totalAmount: 149.99,
        itemCount: 3,
        isTaxExempt: true,
        metadata: {
          'notes': 'Leave at door',
          'tags': ['fragile', 'expedited']
        },
        createdAt: DateTime.utc(2026, 10, 25, 10, 0, 0),
      );

      final order2 = MockExternalOrder(
        id: 'ord-beta-202',
        customerId: 'cust-beta-88',
        totalAmount: 24.50,
        itemCount: 1,
        isTaxExempt: false,
        metadata: {'notes': 'Standard shipping'},
        createdAt: DateTime.utc(2026, 10, 25, 12, 30, 0),
      );

      await storage.save(
        entity: 'orders',
        id: order1.id,
        data: order1.toJson(),
      );

      await storage.save(
        entity: 'orders',
        id: order2.id,
        data: order2.toJson(),
      );

      final rows = await storage.db.getAll(
        'SELECT * FROM orders WHERE total_amount > ? AND is_tax_exempt = 1 ORDER BY total_amount DESC;',
        [50.0],
      );

      expect(rows.length, 1);

      final restored = MockExternalOrder.fromJson(Map<String, dynamic>.from(rows.first));

      expect(restored.id, order1.id);
      expect(restored.customerId, 'cust-alpha-99');
      expect(restored.totalAmount, 149.99);
      expect(restored.itemCount, 3);
      expect(restored.isTaxExempt, isTrue);
      expect(restored.metadata['notes'], 'Leave at door');
      expect(restored.metadata['tags'], equals(['fragile', 'expedited']));
      expect(restored.createdAt, order1.createdAt);

      final outboxRow = await storage.db.get(
        "SELECT payload_json FROM _sync_outbox WHERE entity_name = 'orders' AND entity_id = ?;",
        [order1.id],
      );
      final outboxPayload = jsonDecode(outboxRow['payload_json'] as String) as Map<String, dynamic>;

      expect(outboxPayload['id'], order1.id);
      expect(outboxPayload['customer_id'], 'cust-alpha-99');
      expect(outboxPayload['total_amount'], 149.99);
      expect(outboxPayload['_base_snapshot_json'], isNull);
      expect(outboxPayload['mutation_id'], isNull);

      final updatedOrder1 = MockExternalOrder(
        id: order1.id,
        customerId: order1.customerId,
        totalAmount: 299.99,
        itemCount: 5,
        isTaxExempt: true,
        metadata: {'notes': 'Upgraded to premium'},
        createdAt: order1.createdAt,
      );

      final updateMutId = await storage.save(
        entity: 'orders',
        id: updatedOrder1.id,
        data: updatedOrder1.toJson(),
        version: 2,
      );

      final updateOutbox = await storage.db.get(
        'SELECT base_snapshot_json, payload_json FROM _sync_outbox WHERE mutation_id = ?;',
        [updateMutId],
      );

      final capturedBase = jsonDecode(updateOutbox['base_snapshot_json'] as String) as Map<String, dynamic>;
      expect(capturedBase['total_amount'], 149.99);
      expect(capturedBase['item_count'], 3);

      final newPayload = jsonDecode(updateOutbox['payload_json'] as String) as Map<String, dynamic>;
      expect(newPayload['total_amount'], 299.99);
      expect(newPayload['item_count'], 5);

      final domainRow = await storage.db.get("SELECT data_json FROM orders WHERE id = ?;", [updatedOrder1.id]);
      final storedDataJson = jsonDecode(domainRow['data_json'] as String) as Map<String, dynamic>;
      expect(storedDataJson['total_amount'], 299.99);
      expect(storedDataJson['customer_id'], 'cust-alpha-99');
    });
  });
}
