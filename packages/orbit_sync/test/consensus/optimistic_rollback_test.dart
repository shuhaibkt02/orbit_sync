import 'package:test/test.dart';
import 'package:orbit_sync/offline_sync.dart';
import 'consensus_test_helpers.dart';

void main() {
  late TestConsensusEnv env;

  setUp(() async {
    env = await TestConsensusEnv.create();
  });

  tearDown(() async {
    await env.dispose();
  });

  group('Layer 2 Consensus: Optimistic Rollback & Resync', () {
    test('Test Case 1: Optimistic Rollback on Server 422 Unprocessable Entity', () async {
      await env.storage.save(
        entity: 'tasks',
        id: 'task-422',
        data: {'title': 'Original Title', 'priority': 'high'},
      );
      await env.worker.pushBatch();

      final beforeEdit = await env.storage.db.get("SELECT title FROM tasks WHERE id = 'task-422';");
      expect(beforeEdit['title'], 'Original Title');

      final editMut = await env.storage.save(
        entity: 'tasks',
        id: 'task-422',
        data: {'title': '', 'priority': 'low'},
      );

      final optimisticRow = await env.storage.db.get("SELECT title FROM tasks WHERE id = 'task-422';");
      expect(optimisticRow['title'], '');

      final pushRes = await env.worker.pushBatch(chaos: 'validation_error');
      expect(pushRes.status, SyncPushStatus.validationError);

      final restoredRow = await env.storage.db.get("SELECT title FROM tasks WHERE id = 'task-422';");
      expect(restoredRow['title'], 'Original Title');

      final outboxDraft = await env.storage.db.get(
        'SELECT status, payload_json, error_details_json FROM _sync_outbox WHERE mutation_id = ?;',
        [editMut],
      );
      expect(outboxDraft['status'], 'validation_error');
      expect(outboxDraft['payload_json'], contains('""'));
      expect(outboxDraft['error_details_json'], contains('must not be blank'));
    });

    test('Test Case 2: Generation-Swap Resync on HTTP 410 Gone', () async {
      for (var i = 1; i <= 10; i++) {
        env.server.records['tasks:t-$i'] = {'title': 'Task $i'};
        env.server.cursor++;
        env.server.changelog.add({
          'cursor': env.server.cursor,
          'entity': 'tasks',
          'id': 't-$i',
          'op': 'upsert',
          '_deleted': false,
          'data': {'title': 'Task $i'},
          'version': 1,
        });
      }

      await env.worker.pullAll();

      final countBefore = await env.storage.db.get('SELECT COUNT(*) as cnt FROM tasks;');
      expect(countBefore['cnt'], 10);

      await env.storage.save(
        entity: 'tasks',
        id: 'offline-draft-1',
        data: {'title': 'Unpushed Draft Task'},
      );

      final pullRes = await env.worker.pullPage(chaos: 'expired_cursor');
      expect(pullRes.status, SyncPullStatus.expiredCursor);

      env.server.records.remove('tasks:t-10');
      env.server.records['tasks:t-11'] = {'title': 'Task 11 (Fresh Generation)'};
      env.server.cursor = 100;

      final resyncOk = await env.worker.resyncGeneration(['tasks']);
      expect(resyncOk, isTrue);

      final activeDraft = await env.storage.db.getOptional(
        "SELECT title FROM tasks WHERE id = 'offline-draft-1';",
      );
      expect(activeDraft, isNotNull);
      expect(activeDraft!['title'], 'Unpushed Draft Task');

      final draftOutbox = await env.storage.db.get(
        "SELECT status FROM _sync_outbox WHERE entity_id = 'offline-draft-1';",
      );
      expect(draftOutbox['status'], 'pending');

      final newRow = await env.storage.db.get("SELECT title FROM tasks WHERE id = 't-11';");
      expect(newRow['title'], 'Task 11 (Fresh Generation)');
      final deletedRow = await env.storage.db.getOptional("SELECT title FROM tasks WHERE id = 't-10';");
      expect(deletedRow, isNull);

      final newCursor = await env.worker.getLastSyncedCursor();
      expect(newCursor, 100);
    });
  });
}
