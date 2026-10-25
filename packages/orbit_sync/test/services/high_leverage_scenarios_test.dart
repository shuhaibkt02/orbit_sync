import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/offline_sync.dart';
import 'package:sync_server/sync_server.dart';
import '../shared/harness/transport/fault.dart';
import '../shared/harness/transport/fault_injection_http_client.dart';

void main() {
  group('Tier 1 High-Leverage Scenarios', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('high_leverage_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('Test 1: Concurrent sync() safety & atomic in-flight claiming (Zero double-push)', () async {
      int serverPushes = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        if (req.uri.path == '/api/orders') {
          serverPushes++;
          // Simulate network latency so concurrent callers overlap
          await Future.delayed(const Duration(milliseconds: 50));
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'status': 'ok'}));
          await req.response.close();
        }
      });

      final targetUrl = 'http://${server.address.address}:${server.port}/api/orders';
      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/concurrent_sync.db',
      );
      await client.registerEntity('orders', url: targetUrl);

      await client.store('orders', {'item': 'Laptop', 'price': 1200});

      // Fire 5 concurrent sync calls simultaneously
      await Future.wait([
        client.sync(),
        client.sync(),
        client.sync(),
        client.sync(),
        client.sync(),
      ]);

      // Assert: Exactly ONE push reached the server despite 5 concurrent calls
      expect(serverPushes, equals(1), reason: '_isSyncing guard & atomic in-flight claim prevent double-push');

      final rows = await client.query('SELECT status FROM _sync_outbox');
      expect(rows.first['status'], equals('synced'));

      await client.close();
      await server.close();
    });

    test('Test 2: Idempotency key stability across 5 consecutive retries', () async {
      final faultClient = FaultInjectionHttpClient(
        script: [
          const DropSocketBeforeRequest(),
          const DropSocketBeforeRequest(),
          const ReturnStatus(500, body: 'Server Error 1'),
          const ReturnStatus(502, body: 'Bad Gateway'),
          const DropSocketBeforeRequest(),
          const ReturnStatus(200, body: '{"status":"ok"}'),
        ],
      );

      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/idempotency_stability.db',
        httpClient: faultClient,
      );
      await client.registerEntity('orders', url: 'https://example.com/api/orders');

      final orderId = await client.store('orders', {'item': 'Monitor', 'price': 300});
      final outboxInitial = await client.query('SELECT mutation_id FROM _sync_outbox WHERE entity_id = ?', [orderId]);
      final expectedMutationId = outboxInitial.first['mutation_id'] as String;

      // Retries 1 through 5 fail with injected faults
      for (var attempt = 1; attempt <= 5; attempt++) {
        await client.sync(force: true);
        final rows = await client.query('SELECT status, retry_count FROM _sync_outbox WHERE entity_id = ?', [orderId]);
        expect(rows.first['status'], equals('pending'));
        expect(rows.first['retry_count'], equals(attempt));
      }

      // Attempt 6 succeeds
      await client.sync(force: true);
      final rows = await client.query('SELECT status FROM _sync_outbox WHERE entity_id = ?', [orderId]);
      expect(rows.first['status'], equals('synced'));

      // Assert invariant: All 6 HTTP requests carried the EXACT same idempotency key
      expect(faultClient.captured.length, equals(6));
      final capturedKeys = faultClient.captured.map((req) => req.headers['idempotency-key']).toList();
      final capturedMutationIds = faultClient.captured.map((req) => req.headers['x-client-mutation-id']).toList();

      for (final key in capturedKeys) {
        expect(key, equals(expectedMutationId), reason: 'Idempotency key must remain strictly invariant across retries');
      }
      for (final mutId in capturedMutationIds) {
        expect(mutId, equals(expectedMutationId), reason: 'x-client-mutation-id must match mutation_id exactly');
      }

      await client.close();
      faultClient.close();
    });

    test('Test 3: Deep 3-level DAG cascade (Parent -> Child -> Grandchild)', () async {
      final fakeServer = await FakeSyncServer.start(port: 0);
      final storage = await SyncStorage.open(path: '${tempDir.path}/dag_cascade.db');
      final worker = SyncWorker(
        storage: storage,
        serverUrl: fakeServer.baseUrl,
        profile: SyncProfile.enterprise,
      );

      await storage.registerEntityTable('projects', {'name': 'TEXT'});
      await storage.registerEntityTable('tasks', {'title': 'TEXT', 'project_id': 'TEXT'});
      await storage.registerEntityTable('subtasks', {'desc': 'TEXT', 'task_id': 'TEXT'});

      // Level 1: Parent Project
      final parentId = await storage.save(
        entity: 'projects',
        id: 'p-1',
        data: {'name': 'Project Alpha'},
      );

      // Level 2: Child Task (depends on Parent)
      final childId = await storage.save(
        entity: 'tasks',
        id: 't-1',
        data: {'title': 'Task 1', 'project_id': 'p-1'},
        dependsOnMutationId: parentId,
      );

      // Level 3: Grandchild Subtask (depends on Child)
      final grandChildId = await storage.save(
        entity: 'subtasks',
        id: 'st-1',
        data: {'desc': 'Subtask 1.1', 'task_id': 't-1'},
        dependsOnMutationId: childId,
      );

      // 1. Parent fails with poison pill 400 -> quarantined to DLQ
      final push1 = await worker.pushBatch(batchSize: 1, chaos: 'bad_request');
      expect(push1.status, SyncPushStatus.poisonPill);

      // Verify Parent in DLQ
      final parentRow = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [parentId]);
      expect(parentRow['status'], equals('dlq'));

      // 2. Child evaluation sees Parent is in DLQ -> Child held
      await worker.pushBatch(batchSize: 1);
      final childRow = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [childId]);
      expect(childRow['status'], equals('held'));

      // 3. Grandchild evaluation sees Child is held -> Grandchild held
      await worker.pushBatch(batchSize: 1);
      final grandChildRow = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [grandChildId]);
      expect(grandChildRow['status'], equals('held'));

      // 4. Operator repairs Parent (e.g. un-DLQs it to pending)
      await storage.db.execute("UPDATE _sync_outbox SET status = 'pending' WHERE mutation_id = ?", [parentId]);

      // Push Parent -> syncs!
      final pushParent = await worker.pushBatch(batchSize: 1);
      expect(pushParent.status, SyncPushStatus.success);
      final parentAfter = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [parentId]);
      expect(parentAfter['status'], equals('synced'));

      // Next push: Child is automatically unblocked and syncs!
      final pushChild = await worker.pushBatch(batchSize: 1);
      expect(pushChild.status, SyncPushStatus.success);
      final childAfter = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [childId]);
      expect(childAfter['status'], equals('synced'));

      // Next push: Grandchild is automatically unblocked and syncs!
      final pushGrandChild = await worker.pushBatch(batchSize: 1);
      expect(pushGrandChild.status, SyncPushStatus.success);
      final grandChildAfter = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [grandChildId]);
      expect(grandChildAfter['status'], equals('synced'));

      await storage.close();
      await fakeServer.stop();
    });

    test('Test 4: Delta sync pagination mid-transfer resume without duplicate downloads', () async {
      int pullRequestsCount = 0;
      final requestedSinceCursors = <int>[];

      // Mock server with 3 pages of 50 records (total 150)
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        if (req.uri.path == '/sync/pull') {
          pullRequestsCount++;
          final since = int.tryParse(req.uri.queryParameters['since'] ?? '0') ?? 0;
          requestedSinceCursors.add(since);

          if (since == 0) {
            // Page 1: 50 records, next_cursor = 50
            final changes = List.generate(50, (i) => {
              'cursor': i + 1,
              'entity': 'items',
              'id': 'item-${i + 1}',
              'data': {'title': 'Item ${i + 1}'},
              'version': 1,
            });
            req.response.statusCode = HttpStatus.ok;
            req.response.headers.contentType = ContentType.json;
            req.response.write(jsonEncode({
              'changes': changes,
              'next_cursor': 50,
              'has_more': true,
            }));
            await req.response.close();
          } else if (since == 50 && pullRequestsCount == 2) {
            // Page 2: Simulate network termination mid-request!
            final socket = await req.response.detachSocket();
            socket.destroy();
          } else if (since == 50) {
            // Page 2 recovered: 50 records, next_cursor = 100
            final changes = List.generate(50, (i) => {
              'cursor': 51 + i,
              'entity': 'items',
              'id': 'item-${51 + i}',
              'data': {'title': 'Item ${51 + i}'},
              'version': 1,
            });
            req.response.statusCode = HttpStatus.ok;
            req.response.headers.contentType = ContentType.json;
            req.response.write(jsonEncode({
              'changes': changes,
              'next_cursor': 100,
              'has_more': true,
            }));
            await req.response.close();
          } else if (since == 100) {
            // Page 3: 50 records, next_cursor = 150, has_more = false
            final changes = List.generate(50, (i) => {
              'cursor': 101 + i,
              'entity': 'items',
              'id': 'item-${101 + i}',
              'data': {'title': 'Item ${101 + i}'},
              'version': 1,
            });
            req.response.statusCode = HttpStatus.ok;
            req.response.headers.contentType = ContentType.json;
            req.response.write(jsonEncode({
              'changes': changes,
              'next_cursor': 150,
              'has_more': false,
            }));
            await req.response.close();
          }
        }
      });

      final dbPath = '${tempDir.path}/delta_resume.db';
      var client = await OfflineSyncClient.initialize(
        databasePath: dbPath,
        serverUrl: 'http://${server.address.address}:${server.port}',
      );
      await client.registerTable('items', {'title': 'TEXT'});

      // Pull page 1 succeeds
      final p1Res = await client.worker.pullPage();
      expect(p1Res.status, equals(SyncPullStatus.success));
      var cursor = await client.worker.getLastSyncedCursor();
      expect(cursor, equals(50));

      // Attempt page 2 -> network destroyed!
      final p2Res = await client.worker.pullPage();
      expect(p2Res.status, equals(SyncPullStatus.networkError));

      // Client killed / process restart
      await client.close();

      // Reopen client from same database
      client = await OfflineSyncClient.initialize(
        databasePath: dbPath,
        serverUrl: 'http://${server.address.address}:${server.port}',
      );

      // Verify checkpoint cursor is durably 50
      cursor = await client.worker.getLastSyncedCursor();
      expect(cursor, equals(50));

      // Complete pullAll -> resumes strictly from cursor 50 without redownloading page 1
      await client.worker.pullAll();

      final totalItems = await client.query('SELECT COUNT(*) as cnt FROM items');
      expect(totalItems.first['cnt'], equals(150), reason: 'All 150 items saved with zero duplicate rows');

      final finalCursor = await client.worker.getLastSyncedCursor();
      expect(finalCursor, equals(150));

      // Verify requested cursors: 0, 50 (failed), 50 (resumed), 100
      expect(requestedSinceCursors, equals([0, 50, 50, 100]));

      await client.close();
      await server.close();
    });

    test('Test 5: Mid-batch token expiry (401 on item 2 of 3 refreshes token and resumes without dropping item 1)', () async {
      String currentToken = 'token_expired';
      int refreshCount = 0;
      final serverTokensReceived = <String, String>{};

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        final bodyStr = await utf8.decodeStream(req);
        final bodyJson = jsonDecode(bodyStr) as Map<String, dynamic>;
        final id = bodyJson['id'] as String;
        final authHeader = req.headers.value('authorization');

        if (id == 'item-2' && authHeader == 'Bearer token_expired') {
          // Reject item 2 with 401
          req.response.statusCode = HttpStatus.unauthorized;
          req.response.write('Token expired');
          await req.response.close();
          return;
        }

        serverTokensReceived[id] = authHeader ?? '';
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'status': 'ok', 'id': id}));
        await req.response.close();
      });

      final targetUrl = 'http://${server.address.address}:${server.port}/api/orders';
      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/mid_batch_auth.db',
        getAuthToken: () async => currentToken,
        onAuthExpired: () async {
          refreshCount++;
          currentToken = 'token_refreshed_v2';
        },
      );
      await client.registerEntity('orders', url: targetUrl);

      // Store 3 items
      final id1 = await client.store('orders', {'item': 'Item 1'}, id: 'item-1');
      final id2 = await client.store('orders', {'item': 'Item 2'}, id: 'item-2');
      final id3 = await client.store('orders', {'item': 'Item 3'}, id: 'item-3');

      // Sync 1: Item 1 succeeds (200), Item 2 fails (401), trigger refresh, pause queue
      await client.sync(force: true);

      expect(refreshCount, equals(1));
      expect(currentToken, equals('token_refreshed_v2'));

      // Verify item 1 is synced, items 2 and 3 remain pending
      final rows1 = await client.query('SELECT status FROM _sync_outbox WHERE entity_id = ?', [id1]);
      final rows2 = await client.query('SELECT status FROM _sync_outbox WHERE entity_id = ?', [id2]);
      final rows3 = await client.query('SELECT status FROM _sync_outbox WHERE entity_id = ?', [id3]);

      expect(rows1.first['status'], equals('synced'));
      expect(rows2.first['status'], equals('pending'), reason: 'Item 2 reset to pending after 401');
      expect(rows3.first['status'], equals('pending'), reason: 'Item 3 preserved pending');

      // Sync 2: Items 2 and 3 resume with refreshed token
      await client.sync(force: true);

      final finalRows = await client.query('SELECT status FROM _sync_outbox');
      expect(finalRows.every((r) => r['status'] == 'synced'), isTrue);

      // Verify authorization tokens received by server
      expect(serverTokensReceived['item-1'], equals('Bearer token_expired'));
      expect(serverTokensReceived['item-2'], equals('Bearer token_refreshed_v2'));
      expect(serverTokensReceived['item-3'], equals('Bearer token_refreshed_v2'));

      await client.close();
      await server.close();
    });
  });
}
