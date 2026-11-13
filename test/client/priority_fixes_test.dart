import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'package:orbit_sync/src/consensus/services/batch_envelope_pusher.dart';
import 'package:orbit_sync/src/consensus/services/custom_rest_pusher.dart';
import 'package:orbit_sync/src/storage/infrastructure/sqlite/sqlite_baseline_manager.dart';

class TaskItem {
  final String? id;
  final String title;
  final bool isDone;
  final String status;

  TaskItem(
      {this.id,
      required this.title,
      this.isDone = false,
      this.status = 'active'});

  factory TaskItem.fromJson(Map<String, dynamic> json) => TaskItem(
        id: json['id'] as String?,
        title: json['title'] as String,
        isDone: json['is_done'] as bool, // Strict type cast! Crashes if int 1/0
        status: (json['status'] as String?) ?? 'active',
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'title': title,
        'is_done': isDone,
        'status': status,
      };
}

void main() {
  late String dbPath;
  late OrbitClient client;

  setUp(() async {
    dbPath =
        '${Directory.systemTemp.path}/test_priority_${DateTime.now().microsecondsSinceEpoch}.db';
    client = await OrbitClient.initialize(
      databasePath: dbPath,
      baseUrl: 'https://api.example.com',
    );
  });

  tearDown(() async {
    await client.close();
    final f = File(dbPath);
    if (await f.exists()) await f.delete();
  });

  group('Priority 1: Fix registerTable Recursion Loop', () {
    test('OrbitClient.registerTable executes without StackOverflowError',
        () async {
      final legacyClient = await OrbitClient.initialize(
        databasePath:
            '${Directory.systemTemp.path}/legacy_${DateTime.now().microsecondsSinceEpoch}.db',
        baseUrl: 'https://api.example.com',
      );

      // This previously crashed with StackOverflowError
      await expectLater(
        legacyClient.registerTable('categories', {
          'name': 'TEXT NOT NULL',
        }),
        completes,
      );

      final tables = await legacyClient.query(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='categories'",
      );
      expect(tables, isNotEmpty);
      await legacyClient.close();
    });
  });

  group('Priority 2: Fix Double ID in REST Wire Route', () {
    test(
        'HttpSyncTransport does not duplicate entityId when URL already contains it',
        () async {
      String? capturedUrl;
      final mockClient = MockClient((request) async {
        capturedUrl = request.url.toString();
        return http.Response('{"ok": true}', 200);
      });

      final transport = SyncTransport.http(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
      );

      // Endpoint URL already resolved with entityId '/tasks/task-123'
      await transport.pushCustom(
        url: 'https://api.example.com/tasks/task-123',
        method: 'PUT',
        mutationId: 'mut-001',
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        entityId: 'task-123',
        payload: {'title': 'Updated Title'},
      );

      // Must NOT be 'https://api.example.com/tasks/task-123/task-123'
      expect(capturedUrl, equals('https://api.example.com/tasks/task-123'));
    });

    test(
        'HttpSyncTransport appends entityId when base path is passed without it',
        () async {
      String? capturedUrl;
      final mockClient = MockClient((request) async {
        capturedUrl = request.url.toString();
        return http.Response('', 204);
      });

      final transport = SyncTransport.http(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
      );

      await transport.pushCustom(
        url: 'https://api.example.com/tasks',
        method: 'DELETE',
        mutationId: 'mut-002',
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        entityId: 'task-999',
      );

      expect(capturedUrl, equals('https://api.example.com/tasks/task-999'));
    });
  });

  group('Priority 3: Fix Cold-Start Query Crash (no such column)', () {
    test(
        'collection<T> with explicit columns permits immediate watch/query on empty table',
        () async {
      final tasks = client.collection<TaskItem>(
        name: 'tasks',
        endpoint: '/tasks',
        columns: {
          'title': 'TEXT NOT NULL',
          'is_done': 'INTEGER NOT NULL DEFAULT 0',
          'status': 'TEXT NOT NULL DEFAULT "active"',
        },
        fromJson: TaskItem.fromJson,
        toJson: (t) => t.toJson(),
      );

      // Querying an empty table with where clause on a column must NOT throw 'no such column'
      final emptyResult =
          await tasks.query(where: 'status = ?', whereArgs: ['active']);
      expect(emptyResult, isEmpty);

      // Watching an empty table must emit an empty list without error
      final streamFuture =
          tasks.watch(where: 'status = ?', whereArgs: ['active']).first;
      expect(await streamFuture, isEmpty);
    });
  });

  group('Priority 4: Batch Push HTTP 422 & 409 Queue Unfreeze', () {
    test(
        'HTTP 422 rolls back first mutation and unfreezes remaining mutations to pending',
        () async {
      final mockClient = MockClient((request) async {
        return http.Response('{"error": "Validation failed on item 1"}', 422);
      });

      final transport = SyncTransport.http(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
      );

      // Ensure table exists for rollback
      await (client as dynamic)
          .storage
          .registerEntityTable('tasks', {'title': 'TEXT'});

      // Seed 3 mutations in _sync_outbox
      final now = DateTime.now().millisecondsSinceEpoch;
      final db = (client as dynamic).storage.db;
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, 'in_flight', ?, ?)",
        [
          'm-1',
          'tasks',
          't-1',
          'create',
          jsonEncode({'title': 'T1'}),
          now,
          1
        ],
      );
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, 'in_flight', ?, ?)",
        [
          'm-2',
          'tasks',
          't-2',
          'create',
          jsonEncode({'title': 'T2'}),
          now,
          2
        ],
      );
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, 'in_flight', ?, ?)",
        [
          'm-3',
          'tasks',
          't-3',
          'create',
          jsonEncode({'title': 'T3'}),
          now,
          3
        ],
      );

      final pusher = BatchEnvelopePusher(
        storage: (client as dynamic).storage,
        transport: transport,
        profile: SyncProfile.standard,
        backoffPolicy: BackoffPolicy(),
      );

      final pendingRows = await client.query(
          "SELECT * FROM _sync_outbox WHERE mutation_id IN ('m-1', 'm-2', 'm-3')");
      final result = await pusher.pushBatchEnvelope(
        pending: pendingRows,
        mutationIds: ['m-1', 'm-2', 'm-3'],
        placeholders: '?, ?, ?',
        nowMs: now,
      );

      expect(result.status, equals(SyncPushStatus.validationError));

      // m-1 was rolled back and marked validation_error
      final m1 = await client.query(
          "SELECT status, error_details_json FROM _sync_outbox WHERE mutation_id = 'm-1'");
      expect(m1.first['status'], equals('validation_error'));
      expect(m1.first['error_details_json'], contains('Validation failed'));

      // m-2 and m-3 MUST be reset to pending (NOT stuck in in_flight!)
      final m2 = await client
          .query("SELECT status FROM _sync_outbox WHERE mutation_id = 'm-2'");
      final m3 = await client
          .query("SELECT status FROM _sync_outbox WHERE mutation_id = 'm-3'");
      expect(m2.first['status'], equals('pending'));
      expect(m3.first['status'], equals('pending'));
    });

    test('HTTP 409 resets all batch mutations back to pending', () async {
      final mockClient = MockClient((request) async {
        return http.Response('{"error": "Version conflict"}', 409);
      });

      final transport = SyncTransport.http(
        baseUrl: 'https://api.example.com',
        httpClient: mockClient,
      );

      final now = DateTime.now().millisecondsSinceEpoch;
      final db = (client as dynamic).storage.db;
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, 'in_flight', ?, ?)",
        [
          'conf-1',
          'tasks',
          't-c1',
          'create',
          jsonEncode({'title': 'C1'}),
          now,
          1
        ],
      );

      final pusher = BatchEnvelopePusher(
        storage: (client as dynamic).storage,
        transport: transport,
        profile: SyncProfile.standard,
        backoffPolicy: BackoffPolicy(),
      );

      final pendingRows = await client
          .query("SELECT * FROM _sync_outbox WHERE mutation_id = 'conf-1'");
      final result = await pusher.pushBatchEnvelope(
        pending: pendingRows,
        mutationIds: ['conf-1'],
        placeholders: '?',
        nowMs: now,
      );

      expect(result.status, equals(SyncPushStatus.conflict));

      final c1 = await client.query(
          "SELECT status FROM _sync_outbox WHERE mutation_id = 'conf-1'");
      expect(c1.first['status'], equals('pending'));
    });
  });

  group('Priority 6: Boolean Deserialization (int vs bool TypeCast)', () {
    test(
        'Reading from SQLite decodes real bool so models with strict boolean types do not throw',
        () async {
      final tasks = client.collection<TaskItem>(
        name: 'tasks',
        endpoint: '/tasks',
        fromJson: TaskItem.fromJson,
        toJson: (t) => t.toJson(),
      );

      await tasks
          .save(TaskItem(id: 't-bool-1', title: 'Test Booleans', isDone: true));

      // Retrieve via get()
      final retrieved = await tasks.get('t-bool-1');
      expect(retrieved, isNotNull);
      expect(retrieved!.isDone, isTrue);

      // Retrieve via watch()
      final streamed =
          await tasks.watch(where: 'id = ?', whereArgs: ['t-bool-1']).first;
      expect(streamed.first.isDone, isTrue);
    });
  });

  group('Priority 7: Unified OrbitClient Facade', () {
    test('OrbitClient interface exposes dashboard and retry methods directly',
        () async {
      // All these methods must be callable directly on OrbitClient without casting
      final summary = await client.getSummary();
      expect(summary.pending, equals(0));

      final failures = await client.getFailures();
      expect(failures, isEmpty);

      final stale =
          await client.getStaleRecords(maxAge: const Duration(hours: 1));
      expect(stale, isEmpty);

      // Streams can be listened to directly on OrbitClient
      final summaryStream = client.watchSummary();
      expect(summaryStream, isNotNull);

      final failuresStream = client.watchFailures();
      expect(failuresStream, isNotNull);
    });
  });

  group('Priority 8: Auto-Default REST Endpoints', () {
    test(
        'collection<T> with omitted endpoint defaults to collection name for save and delete',
        () async {
      final tasks = client.collection<TaskItem>(
        name: 'tasks',
        // endpoint omitted!
        fromJson: TaskItem.fromJson,
        toJson: (t) => t.toJson(),
      );

      final id = await tasks
          .save(TaskItem(id: 'task-def-1', title: 'Default Endpoint'));
      expect(id, equals('task-def-1'));

      final outbox = await client
          .query("SELECT * FROM _sync_outbox WHERE entity_id = 'task-def-1'");
      expect(outbox.isNotEmpty, isTrue);
      expect(outbox.first['endpoint_url'],
          equals('https://api.example.com/tasks'));
    });
  });

  group('Priority 9: HTTP 422 Draft Preservation', () {
    test(
        'rollbackOptimistic rolls back domain table but watchRecords preserves draft with isRejected',
        () async {
      final tasks = client.collection<TaskItem>(
        name: 'draft_tasks',
        endpoint: '/draft_tasks',
        fromJson: TaskItem.fromJson,
        toJson: (t) => t.toJson(),
      );
      final db = (client as dynamic).storage.db;

      // New record created offline
      await tasks.save(TaskItem(id: 'dt-1', title: 'My Important Note'));
      final outboxRows = await client.query(
          "SELECT mutation_id FROM _sync_outbox WHERE entity_id = 'dt-1'");
      final mutId = outboxRows.first['mutation_id'] as String;

      // Simulate 422 rollback
      await SqliteBaselineManager.rollbackOptimistic(db, mutId,
          status: 'validation_error');
      await db.execute(
        "UPDATE _sync_outbox SET status = 'validation_error', error_details_json = '{\"error\": \"Title already exists\"}' WHERE mutation_id = ?",
        [mutId],
      );

      // Raw active table has rolled back
      final rawRow =
          await client.query("SELECT * FROM draft_tasks WHERE id = 'dt-1'");
      expect(rawRow, isEmpty);

      // BUT watchRecords preserves the draft with OrbitSyncStatus.rejected and the user data!
      final records = await tasks.watchRecords().first;
      expect(records.isNotEmpty, isTrue);
      final record = records.firstWhere((r) => r.data.id == 'dt-1');
      expect(record.isRejected, isTrue);
      expect(record.data.title, equals('My Important Note'));
      expect(record.errorMessage, contains('Title already exists'));
    });
  });

  group('Priority 10: CustomRestPusher in_flight Auto-Unfreeze', () {
    test(
        'unhandled mutations are reset from in_flight to pending on early exit',
        () async {
      await (client as dynamic)
          .storage
          .registerEntityTable('items', {'name': 'TEXT'});
      final db = (client as dynamic).storage.db;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Seed 2 mutations
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, endpoint_url, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, ?, 'in_flight', ?, ?)",
        [
          'item-mut-1',
          'items',
          'i-1',
          'create',
          'https://api.example.com/items',
          jsonEncode({'name': 'Item 1'}),
          now,
          201
        ],
      );
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, endpoint_url, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, ?, 'in_flight', ?, ?)",
        [
          'item-mut-2',
          'items',
          'i-2',
          'create',
          'https://api.example.com/items',
          jsonEncode({'name': 'Item 2'}),
          now,
          202
        ],
      );

      // Transport that returns 429 for the first mutation
      final mockClient = MockClient((request) async {
        return http.Response('{"error": "Rate limited"}', 429,
            headers: {'retry-after': '60'});
      });
      final transport = SyncTransport.http(
          baseUrl: 'https://api.example.com', httpClient: mockClient);

      final pusher = CustomRestPusher(
        storage: (client as dynamic).storage,
        transport: transport,
        profile: SyncProfile.standard,
        backoffPolicy: BackoffPolicy(),
      );

      final pendingRows = await client.query(
          "SELECT * FROM _sync_outbox WHERE mutation_id IN ('item-mut-1', 'item-mut-2')");
      final result = await pusher.pushCustomEndpoints(
        pending: pendingRows,
        mutationIds: ['item-mut-1', 'item-mut-2'],
        placeholders: '?, ?',
        nowMs: now,
      );

      expect(result.status, equals(SyncPushStatus.networkError));

      // item-mut-1 was rate limited -> pending with next_retry_at
      final row1 = await client.query(
          "SELECT status, next_retry_at FROM _sync_outbox WHERE mutation_id = 'item-mut-1'");
      expect(row1.first['status'], equals('pending'));
      expect(row1.first['next_retry_at'], isNotNull);

      // item-mut-2 was NEVER reached -> finally block MUST have reset it to pending
      final row2 = await client.query(
          "SELECT status FROM _sync_outbox WHERE mutation_id = 'item-mut-2'");
      expect(row2.first['status'], equals('pending'));
    });
  });

  group('Priority 11: BatchEnvelopePusher Structured Poison Pill Isolation',
      () {
    test(
        'quarantines specific failing mutation identified in server response without poisoning innocent items',
        () async {
      await (client as dynamic)
          .storage
          .registerEntityTable('batch_tasks', {'title': 'TEXT'});
      final db = (client as dynamic).storage.db;
      final now = DateTime.now().millisecondsSinceEpoch;

      // Seed 3 mutations
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, 'in_flight', ?, ?)",
        [
          'bm-1',
          'batch_tasks',
          'bt-1',
          'create',
          jsonEncode({'title': 'Task 1'}),
          now,
          301
        ],
      );
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, 'in_flight', ?, ?)",
        [
          'bm-2',
          'batch_tasks',
          'bt-2',
          'create',
          jsonEncode({'title': 'Task 2'}),
          now,
          302
        ],
      );
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, 'in_flight', ?, ?)",
        [
          'bm-3',
          'batch_tasks',
          'bt-3',
          'create',
          jsonEncode({'title': 'Task 3'}),
          now,
          303
        ],
      );

      // Server returns 400 with structured JSON pointing specifically to bm-2
      final mockClient = MockClient((request) async {
        return http.Response(
            jsonEncode({
              'error': 'Bad Request',
              'mutation_id': 'bm-2',
              'message': 'bm-2 is invalid'
            }),
            400);
      });
      final transport = SyncTransport.http(
          baseUrl: 'https://api.example.com', httpClient: mockClient);

      final pusher = BatchEnvelopePusher(
        storage: (client as dynamic).storage,
        transport: transport,
        profile: SyncProfile.standard,
        backoffPolicy: BackoffPolicy(),
      );

      final pendingRows = await client.query(
          "SELECT * FROM _sync_outbox WHERE mutation_id IN ('bm-1', 'bm-2', 'bm-3')");
      final result = await pusher.pushBatchEnvelope(
        pending: pendingRows,
        mutationIds: ['bm-1', 'bm-2', 'bm-3'],
        placeholders: '?, ?, ?',
        nowMs: now,
      );

      expect(result.status, equals(SyncPushStatus.poisonPill));

      // bm-2 MUST be in DLQ (since standard profile uses DLQ for poison pill)
      final row2 = await client.query(
          "SELECT status, error_details_json FROM _sync_outbox WHERE mutation_id = 'bm-2'");
      expect(row2.first['status'], equals('dlq'));
      expect(row2.first['error_details_json'], contains('bm-2 is invalid'));

      // bm-1 and bm-3 MUST NOT be in DLQ — they were innocent and reset to pending
      final row1 = await client
          .query("SELECT status FROM _sync_outbox WHERE mutation_id = 'bm-1'");
      final row3 = await client
          .query("SELECT status FROM _sync_outbox WHERE mutation_id = 'bm-3'");
      expect(row1.first['status'], equals('pending'));
      expect(row3.first['status'], equals('pending'));
    });
  });

  group('Priority 12: Zero-Query Dart Predicate Filtering', () {
    test('filters with pure Dart predicates without raw SQL strings', () async {
      // Clean zero-DDL collection (no columns, no indexes, no query strings)
      final tasks = client.collection<TaskItem>(
        name: 'predicate_tasks',
        fromJson: TaskItem.fromJson,
        toJson: (t) => t.toJson(),
      );

      await tasks
          .save(TaskItem(id: 'pt-1', title: 'Regular Task', isDone: false));
      await tasks
          .save(TaskItem(id: 'pt-2', title: 'Urgent Task', isDone: true));
      await tasks
          .save(TaskItem(id: 'pt-3', title: 'Urgent Note', isDone: false));

      // 1. query with Dart predicate
      final completed = await tasks.query(filter: (t) => t.isDone);
      expect(completed.length, equals(1));
      expect(completed.first.id, equals('pt-2'));

      // 2. watch with Dart predicate
      final urgentStream =
          await tasks.watch(filter: (t) => t.title.contains('Urgent')).first;
      expect(urgentStream.length, equals(2));
      expect(urgentStream.map((t) => t.id), containsAll(['pt-2', 'pt-3']));

      // 3. watchRecords with Dart predicate
      final recordsStream =
          await tasks.watchRecords(filter: (r) => r.data.isDone).first;
      expect(recordsStream.length, equals(1));
      expect(recordsStream.first.data.id, equals('pt-2'));
    });
  });
}
