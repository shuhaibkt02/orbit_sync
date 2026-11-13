import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'consensus_test_helpers.dart';
import '../shared/harness/transport/fault.dart';
import '../shared/harness/transport/fault_injection_http_client.dart';

class TaskModel {
  final String id;
  final String title;

  TaskModel({required this.id, required this.title});

  factory TaskModel.fromJson(Map<String, dynamic> json) => TaskModel(
        id: json['id'] as String,
        title: json['title'] as String,
      );

  Map<String, dynamic> toJson() => {'id': id, 'title': title};
}

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

      final beforeEdit = await env.storage.db.get("SELECT json_extract(data_json, '\$.title') as title FROM tasks WHERE id = 'task-422';");
      expect(beforeEdit['title'], 'Original Title');

      final editMut = await env.storage.save(
        entity: 'tasks',
        id: 'task-422',
        data: {'title': '', 'priority': 'low'},
      );

      final optimisticRow = await env.storage.db.get("SELECT json_extract(data_json, '\$.title') as title FROM tasks WHERE id = 'task-422';");
      expect(optimisticRow['title'], '');

      final pushRes = await env.worker.pushBatch(chaos: 'validation_error');
      expect(pushRes.status, SyncPushStatus.validationError);

      final restoredRow = await env.storage.db.get("SELECT json_extract(data_json, '\$.title') as title FROM tasks WHERE id = 'task-422';");
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
        "SELECT json_extract(data_json, '\$.title') as title FROM tasks WHERE id = 'offline-draft-1';",
      );
      expect(activeDraft, isNotNull);
      expect(activeDraft!['title'], 'Unpushed Draft Task');

      final draftOutbox = await env.storage.db.get(
        "SELECT status FROM _sync_outbox WHERE entity_id = 'offline-draft-1';",
      );
      expect(draftOutbox['status'], 'pending');

      final newRow = await env.storage.db.get("SELECT json_extract(data_json, '\$.title') as title FROM tasks WHERE id = 't-11';");
      expect(newRow['title'], 'Task 11 (Fresh Generation)');
      final deletedRow = await env.storage.db.getOptional("SELECT json_extract(data_json, '\$.title') as title FROM tasks WHERE id = 't-10';");
      expect(deletedRow, isNull);

      final newCursor = await env.worker.getLastSyncedCursor();
      expect(newCursor, 100);
    });

    test('Test Case 3: HTTP 422 rejected draft streamed via watchRecords() with isRejected=true and errorMessage', () async {
      final faultClient = FaultInjectionHttpClient(
        script: [
          // 1. Initial creation succeeds
          const ReturnStatus(200, body: '{"id": "t-watch-1", "title": "Original Task"}'),
          // 2. Offline edit fails with 422 Unprocessable Entity
          const ReturnStatus(422, body: '{"error": "Title must not be blank"}'),
        ],
      );

      final client = await OrbitClient.initialize(
        databasePath: '${env.tempDir.path}/watch_records_422.db',
        httpClient: faultClient,
      );

      final table = client.collection<TaskModel>(
        name: 'tasks',
        endpoint: '/tasks',
        fromJson: TaskModel.fromJson,
        toJson: (t) => t.toJson(),
      );

      // Save initial baseline record and sync it
      await table.save(TaskModel(id: 't-watch-1', title: 'Original Task'));
      await client.sync();

      var raw = await table.get('t-watch-1');
      expect(raw?.title, equals('Original Task'));

      // Edit offline to an invalid state that server rejects
      await table.save(TaskModel(id: 't-watch-1', title: 'Invalid Blank Title'));

      // Trigger sync which encounters 422
      await client.sync();

      // Domain table has rolled back to Original Task baseline
      raw = await table.get('t-watch-1');
      expect(raw?.title, equals('Original Task'));

      // BUT watchRecords preserves the draft with isRejected = true, errorMessage, and rejected data
      final records = await table.watchRecords().first;
      expect(records, isNotEmpty);
      final record = records.firstWhere((r) => r.data.id == 't-watch-1');
      expect(record.isRejected, isTrue);
      expect(record.errorMessage, contains('Title must not be blank'));
      expect(record.data.title, equals('Invalid Blank Title'));
      expect(record.previousData?.title, equals('Original Task'));

      // Verify draft in _sync_outbox was preserved with status = 'validation_error' and zero records deleted
      final outboxRows = await client.query("SELECT status, payload_json, error_details_json FROM _sync_outbox WHERE entity_id = 't-watch-1'");
      expect(outboxRows.length, equals(2)); // Synced baseline mutation + rejected edit mutation preserved
      final validationRows = outboxRows.where((r) => r['status'] == 'validation_error').toList();
      expect(validationRows.length, equals(1));
      expect(validationRows.first['status'], equals('validation_error'));
      expect(validationRows.first['error_details_json'], contains('Title must not be blank'));

      await client.close();
      faultClient.close();
    });

    test('Test Case 4: HTTP 422 on CustomRestPusher preserves outbox draft and rolls back optimistic cache', () async {
      final faultClient = FaultInjectionHttpClient(
        script: [
          const ReturnStatus(422, body: '{"error": "Validation failed on entity"}'),
        ],
      );

      final client = await OrbitClient.initialize(
        databasePath: '${env.tempDir.path}/custom_pusher_422.db',
        httpClient: faultClient,
      );
      await client.registerEntity('items', url: 'https://example.com/api/items');

      final itemId = await client.store('items', {'name': 'Bad Item'});
      // Before sync, raw table has optimistic item
      final rawBefore = await client.query('SELECT * FROM items WHERE id = ?', [itemId]);
      expect(rawBefore, isNotEmpty);

      // Trigger sync
      final result = await client.sync();
      expect(result.failed, equals(1));

      // Domain table has rolled back (empty because it was a new record)
      final rawAfter = await client.query('SELECT * FROM items WHERE id = ?', [itemId]);
      expect(rawAfter, isEmpty);

      // Outbox preserves the draft with status = 'validation_error' and error_details_json
      final outboxRows = await client.query('SELECT status, error_details_json, payload_json FROM _sync_outbox WHERE entity_id = ?', [itemId]);
      expect(outboxRows, isNotEmpty);
      expect(outboxRows.first['status'], equals('validation_error'));
      expect(outboxRows.first['error_details_json'], contains('Validation failed on entity'));

      await client.close();
      faultClient.close();
    });
  });
}
