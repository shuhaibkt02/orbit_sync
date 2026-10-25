import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sync_server/sync_server.dart';

void main() {
  late Directory tempDir;
  late FakeSyncServer server;
  late SyncStorage storage;
  late SyncWorker worker;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dag_test_');
    server = await FakeSyncServer.start(port: 0);

    storage = await SyncStorage.open(path: '${tempDir.path}/dag_client.db', maxReaders: 2);
    await storage.db.execute('PRAGMA foreign_keys = ON;');

    await storage.registerEntityTable('orders', {'customer': 'TEXT', 'total': 'REAL'});
    await storage.registerEntityTable('order_items', {'order_id': 'TEXT', 'item_name': 'TEXT', 'price': 'REAL'}, foreignKeyClause: 'FOREIGN KEY(order_id) REFERENCES orders(id) ON DELETE CASCADE');
    await storage.registerEntityTable('tasks', {'title': 'TEXT'});
    worker = SyncWorker(storage: storage, serverUrl: server.baseUrl);
  });

  tearDown(() async {
    await storage.close();
    await server.stop();
    tempDir.deleteSync(recursive: true);
  });

  group('Layer 2 Consensus: Parent-Child DAG Dependencies', () {
    test('Test Case 1: Universal UUIDv7 & Local FK Integrity Without Temp ID Rewrites', () async {
      final orderId = UuidV7.generate();
      final itemId1 = UuidV7.generate();
      final itemId2 = UuidV7.generate();

      final parentMutId = await storage.save(entity: 'orders', id: orderId, data: {'customer': 'Acme Corp', 'total': 250.0});
      final childMut1 = await storage.save(entity: 'order_items', id: itemId1, data: {'order_id': orderId, 'item_name': 'Widget A', 'price': 100.0}, dependsOnMutationId: parentMutId);
      final childMut2 = await storage.save(entity: 'order_items', id: itemId2, data: {'order_id': orderId, 'item_name': 'Widget B', 'price': 150.0}, dependsOnMutationId: parentMutId);

      final activeItems = await storage.db.getAll('SELECT item_name, price FROM order_items WHERE order_id = ? ORDER BY price ASC;', [orderId]);
      expect(activeItems.length, 2);
      expect(activeItems[0]['item_name'], 'Widget A');
      expect(activeItems[1]['item_name'], 'Widget B');

      final outboxItems = await storage.db.getAll("SELECT mutation_id, entity_id, depends_on_mutation_id, payload_json FROM _sync_outbox WHERE mutation_id IN (?, ?) ORDER BY created_at ASC;", [childMut1, childMut2]);
      for (final row in outboxItems) {
        expect(row['depends_on_mutation_id'], parentMutId);
        final payload = jsonDecode(row['payload_json'] as String) as Map<String, dynamic>;
        expect(payload['order_id'], orderId);
      }
    });

    test('Test Case 2: Topological Push Ordering (Parent Committed Before Child)', () async {
      final orderId = UuidV7.generate();
      final itemId = UuidV7.generate();

      final parentMut = await storage.save(entity: 'orders', id: orderId, data: {'customer': 'Globex Corp'});
      await storage.save(entity: 'order_items', id: itemId, data: {'order_id': orderId, 'item_name': 'Gadget'}, dependsOnMutationId: parentMut);

      final pushRes = await worker.pushBatch(batchSize: 2);
      expect(pushRes.status, SyncPushStatus.success);
      expect(pushRes.applied, 2);

      final pRow = await storage.db.get("SELECT status FROM _sync_outbox WHERE entity_name = 'orders';");
      final cRow = await storage.db.get("SELECT status FROM _sync_outbox WHERE entity_name = 'order_items';");
      expect(pRow['status'], 'synced');
      expect(cRow['status'], 'synced');
    });

    test('Test Case 3: Selective Holding on Quarantined Parent (Zero HoL Blocking)', () async {
      final badOrderId = 'poison-pill';
      final badChildId = UuidV7.generate();
      final independentTaskId = UuidV7.generate();

      final badParentMut = await storage.save(entity: 'orders', id: badOrderId, data: {'customer': 'Poison Parent'});
      final badChildMut = await storage.save(entity: 'order_items', id: badChildId, data: {'order_id': badOrderId, 'item_name': 'Child Item'}, dependsOnMutationId: badParentMut);
      final taskMut = await storage.save(entity: 'tasks', id: independentTaskId, data: {'title': 'Independent Task'});

      final push1 = await worker.pushBatch(batchSize: 1, chaos: 'bad_request');
      expect(push1.status, SyncPushStatus.poisonPill);

      final parentStatus = await storage.db.get("SELECT status FROM _sync_outbox WHERE mutation_id = ?;", [badParentMut]);
      expect(parentStatus['status'], 'dlq');

      final push2 = await worker.pushBatch(batchSize: 2);
      expect(push2.status, SyncPushStatus.success);
      expect(push2.applied, 1);

      final childStatus = await storage.db.get("SELECT status FROM _sync_outbox WHERE mutation_id = ?;", [badChildMut]);
      expect(childStatus['status'], 'held');

      final taskStatus = await storage.db.get("SELECT status FROM _sync_outbox WHERE mutation_id = ?;", [taskMut]);
      expect(taskStatus['status'], 'synced');
    });

    test('Test Case 4: Parent Recovery Automatically Unblocks Held Children', () async {
      final orderId = UuidV7.generate();
      final childItemId = UuidV7.generate();

      final parentMutId = await storage.save(
        entity: 'orders',
        id: orderId,
        data: {'customer': 'poison-pill', 'total': 0.0},
      );
      final childMutId = await storage.save(
        entity: 'order_items',
        id: childItemId,
        data: {'order_id': orderId, 'item_name': 'Pending Item', 'price': 50.0},
        dependsOnMutationId: parentMutId,
      );

      // Trigger poison pill -> parent enters DLQ, child becomes held
      await worker.pushBatch(batchSize: 1);
      await worker.pushBatch(batchSize: 1);

      final cBefore = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [childMutId]);
      expect(cBefore['status'], 'held');

      // 2. Correct parent mutation (customer: 'Repaired Corp', re-queue to pending)
      await storage.db.execute('''
        UPDATE _sync_outbox 
        SET status = 'pending', payload_json = ? 
        WHERE mutation_id = ?
      ''', [
        jsonEncode({'customer': 'Repaired Corp', 'total': 50.0}),
        parentMutId,
      ]);

      // 3. Push parent: parent syncs successfully
      final pushParent = await worker.pushBatch(batchSize: 1);
      expect(pushParent.status, SyncPushStatus.success);

      final pAfter = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [parentMutId]);
      expect(pAfter['status'], 'synced');

      // 4. Next pushBatch automatically unblocks held child and syncs it!
      final pushChild = await worker.pushBatch(batchSize: 1);
      expect(pushChild.status, SyncPushStatus.success);

      final cAfter = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [childMutId]);
      expect(cAfter['status'], 'synced');
    });
  });
}
