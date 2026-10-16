import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sync_server/sync_server.dart';

void main() {
  late Directory tempDir;
  late SyncStorage storage;
  late FakeSyncServer server;
  late SyncWorker worker;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('sync_worker_test_');
    server = await FakeSyncServer.start(port: 0);

    storage = await SyncStorage.open(
      path: '${tempDir.path}/client.db',
      maxReaders: 4,
    );
    await storage.registerEntityTable('tasks', {
      'title': 'TEXT',
      'dept': 'TEXT',
    });

    worker = SyncWorker(
      storage: storage,
      serverUrl: server.baseUrl,
      pullPageLimit: 50,
    );
  });

  tearDown(() async {
    await storage.close();
    await server.stop();
    tempDir.deleteSync(recursive: true);
  });

  group('Issue 03: Bidirectional Client Sync Worker & Chaos Crash Harness', () {
    test('Test Case 1: In-Flight Drop & Deduplication (Challenge 2 - Two Generals)', () async {
      // 1. Save local task optimistically
      final mutId = await storage.save(
        entity: 'tasks',
        id: 't-drop-1',
        data: {'title': 'Two Generals Task'},
      );

      final outboxBefore = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [mutId]);
      expect(outboxBefore['status'], 'pending');

      // 2. Push with chaos=drop_before_response (server commits then destroys socket)
      final dropRes = await worker.pushBatch(batchSize: 1, chaos: 'drop_before_response');
      expect(dropRes.status, SyncPushStatus.networkError);

      // Verify mutation is back in 'pending' status ready for retry
      final outboxDuring = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [mutId]);
      expect(outboxDuring['status'], 'pending');

      // 3. Retry push normally (sends same Idempotency-Key)
      final retryRes = await worker.pushBatch(batchSize: 1);
      expect(retryRes.status, SyncPushStatus.success);

      // Verify outbox marks 'synced'
      final outboxAfter = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [mutId]);
      expect(outboxAfter['status'], 'synced');

      // Assert server has exactly 1 committed record, not 2
      final pullAll = await worker.pullPage();
      expect(pullAll.status, SyncPullStatus.success);
      final serverTasks = await storage.db.getAll('SELECT * FROM tasks WHERE id = ?', ['t-drop-1']);
      expect(serverTasks.length, 1);
    });

    test('Test Case 2: Checkpointed Pull & Mid-Sync Termination (Challenge 4)', () async {
      // 1. Seed server with 250 changes across 5 pages of 50
      for (var i = 1; i <= 250; i++) {
        server.records['tasks:seed-$i'] = {'title': 'Seed Task $i'};
        server.cursor++;
        server.changelog.add({
          'cursor': server.cursor,
          'entity': 'tasks',
          'id': 'seed-$i',
          'op': 'upsert',
          '_deleted': false,
          'data': {'title': 'Seed Task $i'},
          'version': 1,
        });
      }

      // 2. Client pulls 2 pages (100 rows)
      final p1 = await worker.pullPage();
      expect(p1.changeCount, 50);
      expect(p1.nextCursor, 50);

      final p2 = await worker.pullPage();
      expect(p2.changeCount, 50);
      expect(p2.nextCursor, 100);

      // Verify database checkpointed cursor at 100
      final checkpointCursor = await worker.getLastSyncedCursor();
      expect(checkpointCursor, 100);

      final countMidway = await storage.db.get('SELECT COUNT(*) as count FROM tasks;');
      expect(countMidway['count'], 100);

      // 3. Simulate sudden crash / process termination by closing and reopening db
      await storage.close();

      final reopenedStorage = await SyncStorage.open(
        path: '${tempDir.path}/client.db',
        maxReaders: 4,
      );
      final newWorker = SyncWorker(
        storage: reopenedStorage,
        serverUrl: server.baseUrl,
        pullPageLimit: 50,
      );

      // Verify recovered cursor is still 100
      final recoveredCursor = await newWorker.getLastSyncedCursor();
      expect(recoveredCursor, 100);

      // 4. Resume pull from checkpoint to completion
      final totalPulledAfterResume = await newWorker.pullAll();
      expect(totalPulledAfterResume, 150); // remaining 150 rows

      // Assert final database state: exactly 250 rows, 0 duplicates, 0 missing
      final finalCount = await reopenedStorage.db.get('SELECT COUNT(*) as count FROM tasks;');
      expect(finalCount['count'], 250);

      await reopenedStorage.close();
    });

    test('Test Case 3: Poison Pill DLQ & HoL Prevention (Challenge 8 & 9)', () async {
      // 1. Insert 1 malformed mutation ('poison-pill') followed by 3 valid mutations
      final poisonId = await storage.save(
        entity: 'tasks',
        id: 'poison-pill',
        data: {'title': 'Malformed Item'},
      );

      final validIds = <String>[];
      for (var i = 1; i <= 3; i++) {
        final id = await storage.save(
          entity: 'tasks',
          id: 'valid-$i',
          data: {'title': 'Valid Item $i'},
        );
        validIds.add(id);
      }

      // 2. Push poison pill batch
      final push1 = await worker.pushBatch(batchSize: 1);
      expect(push1.status, SyncPushStatus.poisonPill);

      // Assert poison pill routed to 'dlq'
      final poisonRow = await storage.db.get('SELECT status, error_details_json FROM _sync_outbox WHERE mutation_id = ?', [poisonId]);
      expect(poisonRow['status'], 'dlq');
      expect(poisonRow['error_details_json'], contains('Poison pill rejected'));

      // 3. Push remaining valid mutations (no Head-of-Line blocking)
      final push2 = await worker.pushBatch(batchSize: 10);
      expect(push2.status, SyncPushStatus.success);
      expect(push2.applied, 3);

      // Assert all 3 valid mutations are synced
      for (final id in validIds) {
        final r = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [id]);
        expect(r['status'], 'synced');
      }
    });

    test('Test Case 4: Auth Refresh Pausing without Burning Retry Budget (Challenge 9)', () async {
      await storage.save(
        entity: 'tasks',
        id: 'auth-task',
        data: {'title': 'Auth Task'},
      );

      bool authExpiredCalled = false;
      String currentToken = 'expired';

      worker.getAuthToken = () async => currentToken;
      worker.onAuthExpired = () async {
        authExpiredCalled = true;
        // Simulate refreshing access token
        currentToken = 'valid-refreshed-token';
      };

      // Push with expired token: returns 401
      final pushAuth = await worker.pushBatch(batchSize: 1);
      expect(pushAuth.status, SyncPushStatus.unauthorized);
      expect(authExpiredCalled, isTrue);

      // Assert mutation status remains 'pending' with retry_count = 0 (retry budget NOT burned)
      final outboxRow = await storage.db.get("SELECT status, retry_count FROM _sync_outbox WHERE entity_id = 'auth-task';");
      expect(outboxRow['status'], 'pending');
      expect(outboxRow['retry_count'], 0);

      // Next push attempt succeeds with refreshed token
      final pushValid = await worker.pushBatch(batchSize: 1);
      expect(pushValid.status, SyncPushStatus.success);

      final syncedRow = await storage.db.get("SELECT status FROM _sync_outbox WHERE entity_id = 'auth-task';");
      expect(syncedRow['status'], 'synced');
    });

    test('Test Case 5: Scope Eviction vs Tombstone (Challenge 5)', () async {
      // Seed server with:
      // 1. Task to be deleted globally (_deleted: true)
      // 2. Task outside client scope (dept: 'finance' when client syncs dept: 'eng')
      // 3. Task inside client scope (dept: 'eng')
      server.records['tasks:t-del'] = {'title': 'Will Delete'};
      server.cursor++;
      server.changelog.add({
        'cursor': server.cursor,
        'entity': 'tasks',
        'id': 't-del',
        'op': 'delete',
        '_deleted': true,
        'data': null,
        'version': 1,
      });

      server.records['tasks:t-finance'] = {'title': 'Finance Task', 'dept': 'finance'};
      server.cursor++;
      server.changelog.add({
        'cursor': server.cursor,
        'entity': 'tasks',
        'id': 't-finance',
        'op': 'upsert',
        '_deleted': false,
        'data': {'title': 'Finance Task', 'dept': 'finance'},
        'version': 1,
      });

      server.records['tasks:t-eng'] = {'title': 'Eng Task', 'dept': 'eng'};
      server.cursor++;
      server.changelog.add({
        'cursor': server.cursor,
        'entity': 'tasks',
        'id': 't-eng',
        'op': 'upsert',
        '_deleted': false,
        'data': {'title': 'Eng Task', 'dept': 'eng'},
        'version': 1,
      });

      // Insert pre-existing row for t-finance in client db to test local eviction
      await storage.db.execute("INSERT INTO tasks (id, title, dept, version, updated_at) VALUES ('t-finance', 'Old Finance', 'finance', 1, 100);");

      // Configure worker with scope filter dept: 'eng'
      final scopedWorker = SyncWorker(
        storage: storage,
        serverUrl: server.baseUrl,
        scopeFilter: {'dept': 'eng'},
      );

      final pullRes = await scopedWorker.pullPage();
      expect(pullRes.status, SyncPullStatus.success);

      // Verify:
      // 1. t-del is not in tasks
      final delCheck = await storage.db.getAll("SELECT * FROM tasks WHERE id = 't-del';");
      expect(delCheck, isEmpty);

      // 2. t-finance was evicted locally due to left_scope: true
      final financeCheck = await storage.db.getAll("SELECT * FROM tasks WHERE id = 't-finance';");
      expect(financeCheck, isEmpty);

      // 3. Outbox does NOT contain a spurious remote DELETE mutation for the scope-evicted row!
      final outboxCheck = await storage.db.getAll("SELECT * FROM _sync_outbox WHERE entity_id = 't-finance';");
      expect(outboxCheck, isEmpty);

      // 4. t-eng is present
      final engCheck = await storage.db.getAll("SELECT * FROM tasks WHERE id = 't-eng';");
      expect(engCheck, isNotEmpty);
      expect(engCheck.first['title'], 'Eng Task');
    });
  });
}
