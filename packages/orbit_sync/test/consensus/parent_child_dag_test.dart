import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
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
    worker = SyncWorker(storage: storage, baseUrl: server.baseUrl);
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

      final activeItems = await storage.db.getAll(
        "SELECT json_extract(data_json, '\$.item_name') as item_name, json_extract(data_json, '\$.price') as price FROM order_items WHERE json_extract(data_json, '\$.order_id') = ? ORDER BY json_extract(data_json, '\$.price') ASC;",
        [orderId],
      );
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
      final childMut = await storage.save(entity: 'order_items', id: itemId, data: {'order_id': orderId, 'item_name': 'Gadget'}, dependsOnMutationId: parentMut);

      final push1 = await worker.pushBatch(batchSize: 2);
      expect(push1.status, SyncPushStatus.success);
      expect(push1.applied, 1);

      final pRow = await storage.db.get("SELECT status FROM _sync_outbox WHERE mutation_id = ?;", [parentMut]);
      expect(pRow['status'], 'synced');

      final push2 = await worker.pushBatch(batchSize: 2);
      expect(push2.status, SyncPushStatus.success);
      expect(push2.applied, 1);

      final cRow = await storage.db.get("SELECT status FROM _sync_outbox WHERE mutation_id = ?;", [childMut]);
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

    test('Test DAG Dependency Hold: Child mutation remains held while parent is pending or in_flight', () async {
      final parentMut = await storage.save(
        entity: 'orders',
        id: UuidV7.generate(),
        data: {'customer': 'Pending Parent'},
      );
      final childMut = await storage.save(
        entity: 'order_items',
        id: UuidV7.generate(),
        data: {'item': 'Held Child'},
        dependsOnMutationId: parentMut,
      );

      // Parent is 'pending' -> Child should be 'held'
      final childBefore = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [childMut]);
      expect(childBefore['status'], 'held');

      // Transition parent to 'in_flight'
      await storage.db.execute("UPDATE _sync_outbox SET status = 'in_flight' WHERE mutation_id = ?", [parentMut]);

      // Child must remain held while parent is in_flight
      final childDuringInFlight = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [childMut]);
      expect(childDuringInFlight['status'], 'held');

      // Attempting pushBatch must not dispatch the held child
      final pushRes = await worker.pushBatch(batchSize: 2);
      expect(pushRes.applied, 0);

      final childStillHeld = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [childMut]);
      expect(childStillHeld['status'], 'held');
    });

    test('Test Automatic Unlock: When parent reaches synced, child transitions to pending and pushes successfully', () async {
      final parentMut = await storage.save(
        entity: 'orders',
        id: UuidV7.generate(),
        data: {'customer': 'Unlock Customer'},
      );
      final childMut = await storage.save(
        entity: 'order_items',
        id: UuidV7.generate(),
        data: {'item': 'Unlocked Item'},
        dependsOnMutationId: parentMut,
      );

      // Child is initially held
      final cInit = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [childMut]);
      expect(cInit['status'], 'held');

      // Push parent -> parent reaches synced
      final push1 = await worker.pushBatch(batchSize: 1);
      expect(push1.status, SyncPushStatus.success);
      expect(push1.applied, 1);

      final pStatus = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [parentMut]);
      expect(pStatus['status'], 'synced');

      // Child automatically transitioned to 'pending'
      final cUnlocked = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [childMut]);
      expect(cUnlocked['status'], 'pending');

      // Child pushes successfully
      final push2 = await worker.pushBatch(batchSize: 1);
      expect(push2.status, SyncPushStatus.success);
      expect(push2.applied, 1);

      final cSynced = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [childMut]);
      expect(cSynced['status'], 'synced');
    });

    test('Test Doomed Child Protection: If parent fails to dlq or validation_error, child remains held and does not dispatch', () async {
      // 1. Test parent failure to DLQ (400 Bad Request)
      final dlqParentMut = await storage.save(
        entity: 'orders',
        id: 'dlq-parent-1',
        data: {'customer': 'poison-pill'},
      );
      final dlqChildMut = await storage.save(
        entity: 'order_items',
        id: UuidV7.generate(),
        data: {'item': 'Doomed Child 1'},
        dependsOnMutationId: dlqParentMut,
      );

      // Push parent with bad request chaos -> parent enters DLQ
      final pushDlq = await worker.pushBatch(batchSize: 1, chaos: 'bad_request');
      expect(pushDlq.status, SyncPushStatus.poisonPill);

      final dlqParentStatus = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [dlqParentMut]);
      expect(dlqParentStatus['status'], 'dlq');

      final dlqChildStatus = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [dlqChildMut]);
      expect(dlqChildStatus['status'], 'held');

      // Try pushing again: child must remain held and must not dispatch
      final pushDlqChild = await worker.pushBatch(batchSize: 1);
      expect(pushDlqChild.applied, 0);

      final dlqChildStillHeld = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [dlqChildMut]);
      expect(dlqChildStillHeld['status'], 'held');

      // 2. Test parent failure to validation_error (422 Unprocessable Entity)
      final valParentMut = await storage.save(
        entity: 'orders',
        id: 'val-parent-1',
        data: {'customer': 'Invalid Schema Parent'},
      );
      final valChildMut = await storage.save(
        entity: 'order_items',
        id: UuidV7.generate(),
        data: {'item': 'Doomed Child 2'},
        dependsOnMutationId: valParentMut,
      );

      // Simulate HTTP 422 on parent
      await storage.db.execute("UPDATE _sync_outbox SET status = 'validation_error' WHERE mutation_id = ?", [valParentMut]);

      // Push batch
      final pushVal = await worker.pushBatch(batchSize: 1);
      expect(pushVal.applied, 0);

      final valChildStatus = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [valChildMut]);
      expect(valChildStatus['status'], 'held');
    });

    test('Test Two-Step Media Coordination: Parent entity POST extracts ID and triggers child multipart upload with the extracted ID', () async {
      final inMemoryTransport = InMemorySyncTransport(
        pushStatusCode: 201,
        pushResponseBody: '{"id": "ord_srv_99", "status": "created"}',
      );

      final mediaWorker = SyncWorker(
        storage: storage,
        transport: inMemoryTransport,
      );

      mediaWorker.registerIdExtractor('orders', (json) => (json as Map)['id'] as String?);

      await storage.registerEntityTable('order_attachments', {'description': 'TEXT'});

      final parentMut = await storage.save(
        entity: 'orders',
        id: 'temp-order-100',
        data: {'customer': 'Corporate Client', 'total': 999.0},
        endpointUrl: '/api/v1/orders',
        httpMethod: 'POST',
      );

      final childMut = await storage.save(
        entity: 'order_attachments',
        id: 'att-100',
        data: {'field_name': 'receipt', 'file_name': 'receipt.pdf'},
        endpointUrl: '/api/v1/orders/{id}/receipt',
        httpMethod: 'POST',
        mediaPath: '/documents/receipt.pdf',
        dependsOnMutationId: parentMut,
      );

      // Step 0: Child is initially held
      final initChildRow = await storage.db.get('SELECT status, endpoint_url FROM _sync_outbox WHERE mutation_id = ?', [childMut]);
      expect(initChildRow['status'], 'held');
      expect(initChildRow['endpoint_url'], '/api/v1/orders/{id}/receipt');

      // Step 1: Push parent JSON document
      final push1 = await mediaWorker.pushBatch(batchSize: 1);
      expect(push1.status, SyncPushStatus.success);
      expect(push1.applied, 1);

      // Verify parent reached synced
      final parentRow = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [parentMut]);
      expect(parentRow['status'], 'synced');

      // Verify child mutation was updated with canonical server ID ord_srv_99 and unlocked to pending
      final childAfterStep1 = await storage.db.get('SELECT status, endpoint_url FROM _sync_outbox WHERE mutation_id = ?', [childMut]);
      expect(childAfterStep1['status'], 'pending');
      expect(childAfterStep1['endpoint_url'], '/api/v1/orders/ord_srv_99/receipt');

      // Step 2: Push child binary media upload via pushMultipart
      final push2 = await mediaWorker.pushBatch(batchSize: 1);
      expect(push2.status, SyncPushStatus.success);
      expect(push2.applied, 1);

      // Verify multipart streaming was invoked with the confirmed parent ID
      expect(inMemoryTransport.multipartPushes.length, 1);
      final multipartCall = inMemoryTransport.multipartPushes.first;
      expect(multipartCall['uri'].toString(), '/api/v1/orders/ord_srv_99/receipt');
      expect(multipartCall['filePath'], '/documents/receipt.pdf');
      expect(multipartCall['fieldName'], 'receipt');
      expect(multipartCall['fileName'], 'receipt.pdf');

      // Verify child reached synced
      final childSynced = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [childMut]);
      expect(childSynced['status'], 'synced');

      mediaWorker.dispose();
    });
  });
}
