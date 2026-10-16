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

    storage = await SyncStorage.open(
      path: '${tempDir.path}/dag_client.db',
      maxReaders: 2,
    );

    // Enable SQLite foreign key constraints
    await storage.db.execute('PRAGMA foreign_keys = ON;');

    // Register parent table 'orders'
    await storage.registerEntityTable('orders', {
      'customer': 'TEXT',
      'total': 'REAL',
    });

    // Register child table 'order_items' with foreign key referencing orders(id)
    await storage.registerEntityTable(
      'order_items',
      {
        'order_id': 'TEXT',
        'item_name': 'TEXT',
        'price': 'REAL',
      },
      foreignKeyClause: 'FOREIGN KEY(order_id) REFERENCES orders(id) ON DELETE CASCADE',
    );

    // Register independent entity table 'tasks'
    await storage.registerEntityTable('tasks', {
      'title': 'TEXT',
    });

    worker = SyncWorker(storage: storage, serverUrl: server.baseUrl);
  });

  tearDown(() async {
    await storage.close();
    await server.stop();
    tempDir.deleteSync(recursive: true);
  });

  group('Issue 05: Parent-Child DAG Dependencies & Selective Holding (Challenge 3)', () {
    test('Test Case 1: Universal UUIDv7 & Local FK Integrity Without Temp ID Rewrites', () async {
      // 1. Generate client-side permanent UUIDv7 IDs
      final orderId = UuidV7.generate();
      final itemId1 = UuidV7.generate();
      final itemId2 = UuidV7.generate();

      // 2. Insert parent order
      final parentMutId = await storage.save(
        entity: 'orders',
        id: orderId,
        data: {'customer': 'Acme Corp', 'total': 250.0},
      );

      // 3. Insert child items referencing permanent parent orderId
      await storage.save(
        entity: 'order_items',
        id: itemId1,
        data: {'order_id': orderId, 'item_name': 'Widget A', 'price': 100.0},
        dependsOnMutationId: parentMutId,
      );

      await storage.save(
        entity: 'order_items',
        id: itemId2,
        data: {'order_id': orderId, 'item_name': 'Widget B', 'price': 150.0},
        dependsOnMutationId: parentMutId,
      );

      // 4. Verify local SQLite FK queries execute cleanly
      final items = await storage.db.getAll(
        'SELECT * FROM order_items WHERE order_id = ? ORDER BY price ASC',
        [orderId],
      );
      expect(items.length, 2);
      expect(items.first['item_name'], 'Widget A');
      expect(items.last['item_name'], 'Widget B');
    });

    test('Test Case 2: Topological Push Ordering (Parent Committed Before Child)', () async {
      final orderId = UuidV7.generate();
      final itemId = UuidV7.generate();

      // Parent created first
      final pMut = await storage.save(
        entity: 'orders',
        id: orderId,
        data: {'customer': 'Global Industries', 'total': 99.0},
      );

      // Child created second
      await storage.save(
        entity: 'order_items',
        id: itemId,
        data: {'order_id': orderId, 'item_name': 'Component 1', 'price': 99.0},
        dependsOnMutationId: pMut,
      );

      // Push both mutations to server
      final pushRes = await worker.pushBatch(batchSize: 10);
      expect(pushRes.status, SyncPushStatus.success);
      expect(pushRes.applied, 2);

      // Server received parent order first, child FK passed
      final pRow = await storage.db.get("SELECT status FROM _sync_outbox WHERE entity_name = 'orders';");
      final cRow = await storage.db.get("SELECT status FROM _sync_outbox WHERE entity_name = 'order_items';");
      expect(pRow['status'], 'synced');
      expect(cRow['status'], 'synced');
    });

    test('Test Case 3: Selective Holding on Quarantined Parent (Zero HoL Blocking)', () async {
      // 1. Create a parent order that triggers a poison pill (ID: 'poison-pill' -> server returns 400)
      final poisonOrderId = 'poison-pill';
      final parentMutId = await storage.save(
        entity: 'orders',
        id: poisonOrderId,
        data: {'customer': 'Invalid Corp', 'total': 0.0},
      );

      // 2. Create child order_item dependent on this poison order
      final childItemId = UuidV7.generate();
      final childMutId = await storage.save(
        entity: 'order_items',
        id: childItemId,
        data: {'order_id': poisonOrderId, 'item_name': 'Child Item', 'price': 10.0},
        dependsOnMutationId: parentMutId,
      );

      // 3. Create an independent task (unrelated to orders)
      final taskMutId = await storage.save(
        entity: 'tasks',
        id: 'indep-task-1',
        data: {'title': 'Unrelated urgent task'},
      );

      // 4. First push attempt: processes poison parent order
      final push1 = await worker.pushBatch(batchSize: 1);
      expect(push1.status, SyncPushStatus.poisonPill);

      // Assert parent routed to DLQ
      final pOut = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [parentMutId]);
      expect(pOut['status'], 'dlq');

      // 5. Second push attempt: evaluates child and independent task
      final push2 = await worker.pushBatch(batchSize: 5);
      expect(push2.status, SyncPushStatus.success);

      // Verify SELECTIVE HOLDING:
      // - Dependent child was selectively marked 'held' (preventing orphaned server FK rejection)
      final cOut = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [childMutId]);
      expect(cOut['status'], 'held');

      // - Independent task was NOT blocked and synced successfully!
      final tOut = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [taskMutId]);
      expect(tOut['status'], 'synced');
    });

    test('Test Case 4: Parent Recovery Automatically Unblocks Held Children', () async {
      // 1. Quarantined parent in DLQ with child held
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
