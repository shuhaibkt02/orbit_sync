import 'dart:io';
import 'package:test/test.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sync_server/sync_server.dart';

void main() {
  late Directory tempDir;
  late FakeSyncServer server;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('profile_test_');
    server = await FakeSyncServer.start(port: 0);
  });

  tearDown(() async {
    await server.stop();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('Issue 09: SyncProfile Tiers (Basic, Standard, Enterprise)', () {
    test('Test Case 1: SyncProfile.basic uses LWW conflict resolution and simple failure', () async {
      final dbPath = '${tempDir.path}/basic.db';
      final client = await OfflineSyncClient.initialize(
        databasePath: dbPath,
        serverUrl: server.baseUrl,
        profile: SyncProfile.basic,
      );

      await client.registerTable('tasks', {
        'title': 'TEXT',
        'status': 'TEXT',
      });

      expect(client.profile, SyncProfile.basic);
      expect(client.worker.profile, SyncProfile.basic);

      // Seed remote server with an initial record
      server.records['tasks:task-1'] = {
        'title': 'Server Title',
        'status': 'done',
      };
      server.cursor++;
      server.changelog.add({
        'cursor': server.cursor,
        'entity': 'tasks',
        'id': 'task-1',
        'data': {'title': 'Server Title', 'status': 'done'},
        'version': 1,
        '_deleted': false,
        'left_scope': false,
      });

      // Local client saves a conflicting optimistic mutation
      await client.save(
        entity: 'tasks',
        id: 'task-1',
        data: {'title': 'Local Title', 'status': 'in-progress'},
      );

      // Pull from server: basic profile should execute LWW (server overwrites local, outbox marked conflict)
      await client.worker.pullAll();

      final localRows = await client.query("SELECT title, status FROM tasks WHERE id = 'task-1'");
      expect(localRows.first['title'], 'Server Title', reason: 'LWW forces remote state to overwrite local');
      expect(localRows.first['status'], 'done');

      final outboxRows = await client.query("SELECT status FROM _sync_outbox WHERE entity_id = 'task-1'");
      expect(outboxRows.first['status'], 'conflict', reason: 'Overwritten local mutation marked conflict');

      // Test poison pill handling in basic mode: should be marked 'failed' instead of 'dlq'
      await client.save(
        entity: 'tasks',
        id: 'task-bad',
        data: {'title': 'Bad Task'},
      );
      final pushRes = await client.worker.pushBatch(chaos: 'bad_request');
      expect(pushRes.status, SyncPushStatus.poisonPill);

      final poisonRows = await client.query("SELECT status FROM _sync_outbox WHERE entity_id = 'task-bad'");
      expect(poisonRows.first['status'], 'failed', reason: 'Basic profile uses failed status instead of dlq');

      await client.close();
    });

    test('Test Case 2: SyncProfile.standard uses 3-way column merge and routes to DLQ', () async {
      final dbPath = '${tempDir.path}/standard.db';
      final client = await OfflineSyncClient.initialize(
        databasePath: dbPath,
        serverUrl: server.baseUrl,
        profile: SyncProfile.standard,
      );

      await client.registerTable('tasks', {
        'title': 'TEXT',
        'status': 'TEXT',
      });

      expect(client.profile, SyncProfile.standard);

      // Baseline save locally and commit to server
      await client.save(
        entity: 'tasks',
        id: 'task-2',
        data: {'title': 'Base Title', 'status': 'draft'},
      );
      await client.worker.pushBatch();

      // Local updates 'title' only
      await client.save(
        entity: 'tasks',
        id: 'task-2',
        data: {'title': 'Local Updated Title', 'status': 'draft'},
      );

      // Remote server updates 'status' to 'reviewed'
      server.records['tasks:task-2'] = {
        'title': 'Base Title',
        'status': 'reviewed',
      };
      server.cursor++;
      server.changelog.add({
        'cursor': server.cursor,
        'entity': 'tasks',
        'id': 'task-2',
        'data': {'title': 'Base Title', 'status': 'reviewed'},
        'version': 2,
        '_deleted': false,
        'left_scope': false,
      });

      // Pull: Standard profile performs 3-way column merge
      await client.worker.pullAll();

      final localRows = await client.query("SELECT title, status FROM tasks WHERE id = 'task-2'");
      expect(localRows.first['title'], 'Local Updated Title', reason: '3-way merge preserved local non-conflicting field');
      expect(localRows.first['status'], 'reviewed', reason: '3-way merge merged remote non-conflicting field');

      // Drain merged mutation to server
      await client.worker.pushBatch();

      // Test poison pill handling in standard mode: routes to DLQ
      await client.save(
        entity: 'tasks',
        id: 'task-poison',
        data: {'title': 'Poison'},
      );
      await client.worker.pushBatch(chaos: 'bad_request');

      final dlqRows = await client.query("SELECT status FROM _sync_outbox WHERE entity_id = 'task-poison'");
      expect(dlqRows.first['status'], 'dlq', reason: 'Standard profile routes poison pill to DLQ');

      await client.close();
    });

    test('Test Case 3: SyncProfile.enterprise activates Parent-Child DAG selective holding', () async {
      final dbPath = '${tempDir.path}/enterprise.db';
      final client = await OfflineSyncClient.initialize(
        databasePath: dbPath,
        serverUrl: server.baseUrl,
        profile: SyncProfile.enterprise,
        validateInvariants: (entity, record) {
          if (record['title'] == 'INVALID_ORDER') return 'Order is invalid';
          return null;
        },
      );

      await client.registerTable('orders', {'title': 'TEXT'});
      await client.registerTable('order_items', {'order_id': 'TEXT', 'item': 'TEXT'});

      expect(client.profile, SyncProfile.enterprise);

      // Save parent order that will fail invariant/quarantine
      final parentMutId = await client.save(
        entity: 'orders',
        id: 'order-1',
        data: {'title': 'Parent Order'},
      );

      // Save child dependent on parent
      final childMutId = await client.save(
        entity: 'order_items',
        id: 'item-1',
        data: {'order_id': 'order-1', 'item': 'Widget'},
        dependsOnMutationId: parentMutId,
      );

      // Save unrelated record
      final unrelatedMutId = await client.save(
        entity: 'orders',
        id: 'order-unrelated',
        data: {'title': 'Unrelated Order'},
      );

      // Quarantine parent into DLQ manually to simulate failure
      await client.storage.db.execute(
        "UPDATE _sync_outbox SET status = 'dlq' WHERE mutation_id = ?",
        [parentMutId],
      );

      // Push in Enterprise profile: child must be selectively held, unrelated pushes successfully
      final pushRes = await client.worker.pushBatch();
      expect(pushRes.applied, 1, reason: 'Only the unrelated mutation should be applied');

      final childRow = await client.storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [childMutId]);
      expect(childRow['status'], 'held', reason: 'Dependent child should be selectively held');

      final unrelatedRow = await client.storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [unrelatedMutId]);
      expect(unrelatedRow['status'], 'synced', reason: 'Unrelated order should sync without head-of-line blocking');

      await client.close();
    });
  });
}
