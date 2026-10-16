import 'dart:io';
import 'package:test/test.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sync_server/sync_server.dart';

void main() {
  late Directory tempDir;
  late FakeSyncServer server;
  late SyncStorage storageA;
  late SyncStorage storageB;
  late SyncWorker workerA;
  late SyncWorker workerB;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('two_client_test_');
    server = await FakeSyncServer.start(port: 0);

    // Initialize Client A
    storageA = await SyncStorage.open(
      path: '${tempDir.path}/client_a.db',
      maxReaders: 2,
    );
    await storageA.registerEntityTable('tasks', {
      'title': 'TEXT',
      'priority': 'TEXT',
      'start_time': 'TEXT',
      'end_time': 'TEXT',
    });
    workerA = SyncWorker(storage: storageA, serverUrl: server.baseUrl);

    // Initialize Client B
    storageB = await SyncStorage.open(
      path: '${tempDir.path}/client_b.db',
      maxReaders: 2,
    );
    await storageB.registerEntityTable('tasks', {
      'title': 'TEXT',
      'priority': 'TEXT',
      'start_time': 'TEXT',
      'end_time': 'TEXT',
    });
    workerB = SyncWorker(storage: storageB, serverUrl: server.baseUrl);
  });

  tearDown(() async {
    await storageA.close();
    await storageB.close();
    await server.stop();
    tempDir.deleteSync(recursive: true);
  });

  group('Issue 04: Two-Client Conflict, Invariants & Convergence', () {
    test('Test Case 1: Non-Conflicting Field Merge & Convergence across Two Clients', () async {
      // 1. Initial shared record seeded on server: Task(id: 't-1', title: 'Initial', priority: 'low')
      server.records['tasks:t-1'] = {'title': 'Initial Title', 'priority': 'low'};
      server.cursor++;
      server.changelog.add({
        'cursor': server.cursor,
        'entity': 'tasks',
        'id': 't-1',
        'op': 'upsert',
        '_deleted': false,
        'data': {'title': 'Initial Title', 'priority': 'low'},
        'version': 1,
      });

      // Both clients pull baseline
      await workerA.pullAll();
      await workerB.pullAll();

      final aInit = await storageA.db.get("SELECT title, priority FROM tasks WHERE id = 't-1';");
      final bInit = await storageB.db.get("SELECT title, priority FROM tasks WHERE id = 't-1';");
      expect(aInit['title'], 'Initial Title');
      expect(bInit['title'], 'Initial Title');

      // 2. Both clients go offline and make disjoint modifications:
      // Client A updates title
      await storageA.save(
        entity: 'tasks',
        id: 't-1',
        data: {'title': 'Updated by A', 'priority': 'low'},
        version: 1,
      );

      // Client B updates priority
      await storageB.save(
        entity: 'tasks',
        id: 't-1',
        data: {'title': 'Initial Title', 'priority': 'high'},
        version: 1,
      );

      // 3. Client A syncs first: pushes its update
      final pushA = await workerA.pushBatch();
      expect(pushA.status, SyncPushStatus.success);

      // 4. Client B pulls Client A's change while having pending local priority change
      final pullB = await workerB.pullAll();
      expect(pullB, greaterThan(0));

      // Assert Client B merged remote title with local priority change!
      final bMerged = await storageB.db.get("SELECT title, priority FROM tasks WHERE id = 't-1';");
      expect(bMerged['title'], 'Updated by A');
      expect(bMerged['priority'], 'high');

      // 5. Client B now pushes its merged state
      final pushB = await workerB.pushBatch();
      expect(pushB.status, SyncPushStatus.success);

      // 6. Client A pulls latest server state
      await workerA.pullAll();

      // 7. Verify CONVERGENCE: Both clients arrive at exact same deterministic state!
      final aFinal = await storageA.db.get("SELECT title, priority FROM tasks WHERE id = 't-1';");
      final bFinal = await storageB.db.get("SELECT title, priority FROM tasks WHERE id = 't-1';");

      expect(aFinal['title'], 'Updated by A');
      expect(aFinal['priority'], 'high');

      expect(bFinal['title'], 'Updated by A');
      expect(bFinal['priority'], 'high');
      expect(aFinal, equals(bFinal));
    });

    test('Test Case 2: Co-Dependent Invariant Violation Rejects Auto-Merge (Challenge 7)', () async {
      // Invariant validator: start_time must be strictly less than end_time
      String? invariantCheck(String entity, Map<String, dynamic> record) {
        if (entity == 'tasks') {
          final start = record['start_time'] as String?;
          final end = record['end_time'] as String?;
          if (start != null && end != null && start.compareTo(end) >= 0) {
            return 'start_time ($start) must be strictly before end_time ($end)';
          }
        }
        return null;
      }

      workerB.validateInvariants = invariantCheck;

      // Baseline: start 09:00, end 17:00 (valid)
      server.records['tasks:event-1'] = {'title': 'Meeting', 'start_time': '09:00', 'end_time': '17:00'};
      server.cursor++;
      server.changelog.add({
        'cursor': server.cursor,
        'entity': 'tasks',
        'id': 'event-1',
        'op': 'upsert',
        '_deleted': false,
        'data': {'title': 'Meeting', 'start_time': '09:00', 'end_time': '17:00'},
        'version': 1,
      });

      await workerA.pullAll();
      await workerB.pullAll();

      // Client A sets start_time = 18:00
      await storageA.save(
        entity: 'tasks',
        id: 'event-1',
        data: {'title': 'Meeting', 'start_time': '18:00', 'end_time': '17:00'},
      );
      // Client B sets end_time = 12:00
      final mutB = await storageB.save(
        entity: 'tasks',
        id: 'event-1',
        data: {'title': 'Meeting', 'start_time': '09:00', 'end_time': '12:00'},
      );

      // Client A pushes start_time = 18:00 to server
      await workerA.pushBatch();

      // Client B pulls: 3-way merge would yield start_time: 18:00 and end_time: 12:00
      // Invariant validator must intercept and reject this merge!
      await workerB.pullAll();

      // Assert Client B mutation enters 'conflict' status with RFC 9457 details
      final conflictOutbox = await storageB.db.get("SELECT status, error_details_json FROM _sync_outbox WHERE mutation_id = ?;", [mutB]);
      expect(conflictOutbox['status'], 'conflict');
      expect(conflictOutbox['error_details_json'], contains('must be strictly before'));

      // Client B local row retains its valid local edit (not corrupted by invalid merge)
      final localRow = await storageB.db.get("SELECT start_time, end_time FROM tasks WHERE id = 'event-1';");
      expect(localRow['start_time'], '09:00');
      expect(localRow['end_time'], '12:00');
    });

    test('Test Case 3: Optimistic Rollback on Server 422 Unprocessable Entity (Challenge 6)', () async {
      // 1. Initial saved state: Task(title: 'Original Title')
      await storageA.save(
        entity: 'tasks',
        id: 'task-422',
        data: {'title': 'Original Title', 'priority': 'low'},
      );
      await workerA.pushBatch();

      final beforeEdit = await storageA.db.get("SELECT title FROM tasks WHERE id = 'task-422';");
      expect(beforeEdit['title'], 'Original Title');

      // 2. Offline optimistic edit
      final editMut = await storageA.save(
        entity: 'tasks',
        id: 'task-422',
        data: {'title': '', 'priority': 'low'}, // blank title triggers 422
      );

      // Verify domain table shows optimistic edit immediately
      final optimisticRow = await storageA.db.get("SELECT title FROM tasks WHERE id = 'task-422';");
      expect(optimisticRow['title'], '');

      // 3. Worker pushes with chaos=validation_error (returns 422 RFC 9457)
      final pushRes = await workerA.pushBatch(chaos: 'validation_error');
      expect(pushRes.status, SyncPushStatus.validationError);

      // 4. Assert domain table rolled back to pre-mutation baseline
      final restoredRow = await storageA.db.get("SELECT title FROM tasks WHERE id = 'task-422';");
      expect(restoredRow['title'], 'Original Title');

      // 5. Assert outbox preserves the user's rejected edit with status 'validation_error' and error RFC 9457 details
      final outboxDraft = await storageA.db.get("SELECT status, payload_json, error_details_json FROM _sync_outbox WHERE mutation_id = ?;", [editMut]);
      expect(outboxDraft['status'], 'validation_error');
      expect(outboxDraft['payload_json'], contains('""'));
      expect(outboxDraft['error_details_json'], contains('must not be blank'));
    });

    test('Test Case 4: Generation-Swap Resync on HTTP 410 Gone (Challenge 5 & 9)', () async {
      // 1. Seed server with 10 tasks
      for (var i = 1; i <= 10; i++) {
        server.records['tasks:t-$i'] = {'title': 'Task $i'};
        server.cursor++;
        server.changelog.add({
          'cursor': server.cursor,
          'entity': 'tasks',
          'id': 't-$i',
          'op': 'upsert',
          '_deleted': false,
          'data': {'title': 'Task $i'},
          'version': 1,
        });
      }

      // Client A syncs to cursor 10
      await workerA.pullAll();
      final countBefore = await storageA.db.get('SELECT COUNT(*) as count FROM tasks;');
      expect(countBefore['count'], 10);

      // Client A prepares an offline pending mutation (must be preserved during swap)
      await storageA.save(
        entity: 'tasks',
        id: 't-pending-swap',
        data: {'title': 'Must survive generation swap'},
      );

      // 2. Server triggers compaction: sets retention_cursor = 100, purging old changelogs!
      server.retentionCursor = 100;

      // 3. Client A tries regular pull -> receives HTTP 410 Gone
      final pull410 = await workerA.pullPage();
      expect(pull410.status, SyncPullStatus.expiredCursor);

      // 4. Trigger generation swap
      final swapSuccess = await workerA.resyncGeneration(['tasks']);
      expect(swapSuccess, isTrue);

      // 5. Assert:
      // - Server snapshot rows are fully populated
      // - Pending outbox mutation survived and is materialized on the newly swapped active table!
      final pendingOnSwapped = await storageA.db.get("SELECT title FROM tasks WHERE id = 't-pending-swap';");
      expect(pendingOnSwapped['title'], 'Must survive generation swap');

      final pendingOutbox = await storageA.db.get("SELECT status FROM _sync_outbox WHERE entity_id = 't-pending-swap';");
      expect(pendingOutbox['status'], 'pending');
    });
  });
}
