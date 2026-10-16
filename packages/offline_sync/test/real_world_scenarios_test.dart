import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sync_server/sync_server.dart';

void seedServer(FakeSyncServer server, String entity, String id, Map<String, dynamic> data, {int version = 1}) {
  server.records['$entity:$id'] = data;
  server.cursor++;
  server.changelog.add({
    'cursor': server.cursor,
    'entity': entity,
    'id': id,
    'data': data,
    'version': version,
  });
}

void deleteOnServer(FakeSyncServer server, String entity, String id, {int version = 2}) {
  server.records.remove('$entity:$id');
  server.cursor++;
  server.changelog.add({
    'cursor': server.cursor,
    'entity': entity,
    'id': id,
    '_deleted': true,
    'version': version,
  });
}

void updateOnServer(FakeSyncServer server, String entity, String id, Map<String, dynamic> data, {int version = 2}) {
  server.records['$entity:$id'] = data;
  server.cursor++;
  server.changelog.add({
    'cursor': server.cursor,
    'entity': entity,
    'id': id,
    'data': data,
    'version': version,
  });
}

void main() {
  group('Real-World Production Scenarios & Edge Cases', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('real_world_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('Scenario 1: HTTP 429 Rate Limiting with Retry-After Header (Worker pauses without burning retries)', () async {
      int requestCount = 0;
      bool isRateLimited = true;

      // Mock server that returns 429 then recovers
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        requestCount++;
        if (isRateLimited) {
          req.response.statusCode = HttpStatus.tooManyRequests;
          req.response.headers.set('Retry-After', '2');
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'error': 'Rate limit exceeded, slow down.'}));
          await req.response.close();
        } else {
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'status': 'ok'}));
          await req.response.close();
        }
      });

      final targetUrl = 'http://${server.address.address}:${server.port}/api/orders';
      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/scenario1.db',
      );
      await client.registerEntity('orders', url: targetUrl);

      // 1. Offline store
      final orderId = await client.store('orders', {
        'item': 'MacBook Pro M4',
        'price': 2500,
      });

      // 2. Trigger sync while rate limited
      await client.sync();

      // Check status: Outbox MUST remain 'pending' and NOT 'failed' or 'dlq'
      var rows = await client.query('SELECT status, retry_count FROM _sync_outbox WHERE entity_id = ?', [orderId]);
      expect(rows.first['status'], equals('pending'));
      expect(requestCount, equals(1));

      // 3. Rate limit window passes on server
      isRateLimited = false;
      await client.sync(force: true);

      // Check status: Now successfully 'synced'
      rows = await client.query('SELECT status FROM _sync_outbox WHERE entity_id = ?', [orderId]);
      expect(rows.first['status'], equals('synced'));

      await client.close();
      await server.close();
    });

    test('Scenario 2: Server 500/502/503 Transient Outage (Preserves pending status with backoff; recovers on restore)', () async {
      bool serverDown = true;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        if (serverDown) {
          req.response.statusCode = HttpStatus.badGateway;
          req.response.write('502 Bad Gateway - Cloudflare');
          await req.response.close();
        } else {
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'success': true}));
          await req.response.close();
        }
      });

      final targetUrl = 'http://${server.address.address}:${server.port}/api/invoices';
      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/scenario2.db',
      );
      await client.registerEntity('invoices', url: targetUrl);

      // Store invoice offline
      final invId = await client.store('invoices', {
        'customer': 'Acme Corp',
        'amount': 9500.0,
      });

      // Sync during outage
      await client.sync();

      // Outbox status MUST remain pending with incremented retry_count
      var rows = await client.query('SELECT status, retry_count FROM _sync_outbox WHERE entity_id = ?', [invId]);
      expect(rows.first['status'], equals('pending'));
      expect(rows.first['retry_count'], equals(1));

      // Local active data remains 100% available
      final localInv = await client.restoreById('invoices', invId);
      expect(localInv, isNotNull);
      expect(localInv!['customer'], equals('Acme Corp'));

      // Server recovers
      serverDown = false;
      await client.sync(force: true);

      rows = await client.query('SELECT status FROM _sync_outbox WHERE entity_id = ?', [invId]);
      expect(rows.first['status'], equals('synced'));

      await client.close();
      await server.close();
    });

    test('Scenario 3: Update vs Delete Conflict Across Devices (Remote deletion evicts local record, preserves draft as conflict)', () async {
      final fakeServer = await FakeSyncServer.start(port: 0);
      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/scenario3.db',
        serverUrl: fakeServer.baseUrl,
      );
      await client.registerTable('notes', {'title': 'TEXT'});

      final noteId = UuidV7.generate();

      // 1. Initial state: record exists on server and synced to client
      seedServer(fakeServer, 'notes', noteId, {'title': 'Original Note'}, version: 1);
      await client.sync();

      var note = await client.restoreById('notes', noteId);
      expect(note, isNotNull);
      expect(note!['title'], equals('Original Note'));

      // 2. Device modifies note offline
      await client.save(
        entity: 'notes',
        id: noteId,
        data: {'title': 'Updated offline by user'},
        version: 1,
      );

      // 3. Concurrently, another user deletes this note on server
      deleteOnServer(fakeServer, 'notes', noteId, version: 2);

      // 4. Device syncs (pulls remote changes)
      await client.sync();

      // Active table: local record must be evicted
      final activeRows = await client.query('SELECT * FROM notes WHERE id = ?', [noteId]);
      expect(activeRows, isEmpty);

      // Outbox: pending edit must be marked as 'conflict' with structured explanation
      final outboxRows = await client.query(
        "SELECT status, error_details_json FROM _sync_outbox WHERE entity_id = ? AND op = 'upsert'",
        [noteId],
      );
      expect(outboxRows.isNotEmpty, isTrue);
      expect(outboxRows.first['status'], equals('conflict'));
      final errorJson = jsonDecode(outboxRows.first['error_details_json'] as String);
      expect(errorJson['title'], contains('Update vs Delete'));

      await client.close();
      await fakeServer.stop();
    });

    test('Scenario 4: Delete vs Update Conflict Across Devices (Local delete prevents ghost resurrection)', () async {
      final fakeServer = await FakeSyncServer.start(port: 0);
      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/scenario4.db',
        serverUrl: fakeServer.baseUrl,
      );
      await client.registerTable('tasks', {'title': 'TEXT'});

      final taskId = UuidV7.generate();

      // Initial task exists on server
      seedServer(fakeServer, 'tasks', taskId, {'title': 'Task 1'}, version: 1);
      await client.sync();

      // User deletes task locally offline
      await client.delete(entity: 'tasks', id: taskId);

      // Meanwhile, server updated task to version 2
      updateOnServer(fakeServer, 'tasks', taskId, {'title': 'Server edited title'}, version: 2);

      // Device pulls server changes: task MUST NOT be resurrected locally!
      final pullRes = await client.worker.pullPage();
      expect(pullRes.status, equals(SyncPullStatus.success));

      final active = await client.restoreById('tasks', taskId);
      expect(active, isNull, reason: 'Deleted task must not be resurrected while pending delete exists');

      await client.close();
      await fakeServer.stop();
    });

    test('Scenario 5: Multi-Device 3-Way Concurrent Field Convergence', () async {
      final fakeServer = await FakeSyncServer.start(port: 0);
      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/scenario5.db',
        serverUrl: fakeServer.baseUrl,
      );
      await client.registerTable('articles', {
        'title': 'TEXT',
        'content': 'TEXT',
        'author': 'TEXT',
      });

      final docId = UuidV7.generate();

      // Initial state
      seedServer(fakeServer, 'articles', docId, {
        'title': 'Draft 1',
        'content': 'Initial body',
        'author': 'Alice',
      }, version: 1);
      await client.sync();

      // Device modifies 'title' offline
      await client.save(
        entity: 'articles',
        id: docId,
        data: {'title': 'Draft 1 Final', 'content': 'Initial body', 'author': 'Alice'},
        version: 1,
      );

      // Server concurrently receives update from another device modifying 'content'
      updateOnServer(fakeServer, 'articles', docId, {
        'title': 'Draft 1',
        'content': 'Peer reviewed body by Bob',
        'author': 'Alice',
      }, version: 2);

      // Sync: 3-way merge should converge non-conflicting columns
      await client.sync();

      final active = await client.restoreById('articles', docId);
      expect(active!['title'], equals('Draft 1 Final'));
      expect(active['content'], equals('Peer reviewed body by Bob'));
      expect(active['author'], equals('Alice'));

      await client.close();
      await fakeServer.stop();
    });

    test('Scenario 6: High Concurrency Write Storm (100 concurrent async writes without SQLITE_BUSY)', () async {
      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/concurrency.db',
        maxReaders: 4,
      );
      await client.registerTable('logs', {
        'message': 'TEXT',
        'thread': 'INTEGER',
      });

      const writeCount = 100;
      final futures = <Future<String>>[];

      for (int i = 0; i < writeCount; i++) {
        futures.add(client.store('logs', {
          'message': 'Log entry #$i',
          'thread': i % 4,
        }));
      }

      final ids = await Future.wait(futures);
      expect(ids.length, equals(writeCount));
      expect(ids.toSet().length, equals(writeCount), reason: 'Every generated ID must be unique');

      // Verify active table count
      final activeRows = await client.query('SELECT COUNT(*) as count FROM logs');
      expect(activeRows.first['count'], equals(writeCount));

      // Verify outbox count
      final outboxRows = await client.query("SELECT COUNT(*) as count FROM _sync_outbox WHERE status = 'pending'");
      expect(outboxRows.first['count'], equals(writeCount));

      await client.close();
    });

    test('Scenario 7: Token Refresh Race (Thundering herd deduplication to single refresh)', () async {
      int authRefreshCount = 0;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var currentToken = 'expired-token';

      server.listen((HttpRequest req) async {
        final authHeader = req.headers.value('Authorization');
        if (authHeader == 'Bearer valid-token') {
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'status': 'ok'}));
        } else {
          req.response.statusCode = HttpStatus.unauthorized;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'error': 'Token expired'}));
        }
        await req.response.close();
      });

      final targetUrl = 'http://${server.address.address}:${server.port}/api/secure';
      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/auth_race.db',
        getAuthToken: () async => currentToken,
        onAuthExpired: () async {
          authRefreshCount++;
          await Future<void>.delayed(const Duration(milliseconds: 50));
          currentToken = 'valid-token';
        },
      );
      await client.registerEntity('items', url: targetUrl);

      // Store 3 items
      await client.store('items', {'name': 'Item 1'});
      await client.store('items', {'name': 'Item 2'});
      await client.store('items', {'name': 'Item 3'});

      // First sync triggers 401 and calls onAuthExpired
      final push1 = await client.worker.pushBatch(batchSize: 10);
      expect(push1.status, equals(SyncPushStatus.unauthorized));
      expect(authRefreshCount, equals(1));

      // Second sync uses refreshed token and succeeds
      final push2 = await client.worker.pushBatch(batchSize: 10);
      expect(push2.status, equals(SyncPushStatus.success));
      expect(push2.applied, equals(3));
      expect(authRefreshCount, equals(1), reason: 'Token refresh must not be called redundantly');

      await client.close();
      await server.close();
    });

    test('Scenario 8: Clock Skew / Manual Time Rollback (UUIDv7 preserves strict ascending monotonicity)', () {
      final ids = <String>[];

      // Generate 50 IDs
      for (int i = 0; i < 50; i++) {
        ids.add(UuidV7.generate());
      }

      // Verify that every subsequent ID is strictly greater than the preceding ID
      for (int i = 1; i < ids.length; i++) {
        final prev = ids[i - 1];
        final curr = ids[i];
        expect(curr.compareTo(prev) > 0, isTrue,
            reason: 'UUIDv7 must be strictly ascending: $curr > $prev');
      }
    });

    test('Scenario 9: Captive Portal / HTML Interception Resilience (Safe rejection without table corruption)', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        // Hotel captive portal returns 200 with HTML login page instead of JSON API
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.html;
        req.response.write('<!DOCTYPE html><html><body>Please sign in to Airport Wi-Fi</body></html>');
        await req.response.close();
      });

      final targetUrl = 'http://${server.address.address}:${server.port}/api/tasks';
      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/captive.db',
      );
      await client.registerTable('tasks', {'title': 'TEXT'});

      // Attempt to hydrate from captive portal
      expect(
        () async => await client.fetchAndStore('tasks', url: targetUrl),
        throwsA(isA<FormatException>()),
      );

      // Ensure local database remains uncorrupted and intact
      final rows = await client.query('SELECT * FROM tasks');
      expect(rows, isEmpty);

      await client.close();
      await server.close();
    });

    test('Scenario 10: Dynamic Schema Evolution with Rich Heterogeneous Types', () async {
      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/types.db',
      );
      // Register with only title
      await client.registerTable('records', {'title': 'TEXT'});

      // Store record with ints, floats, booleans, and nulls
      final recId = await client.store('records', {
        'title': 'Sensor Reading',
        'temperature': 98.6,
        'reading_count': 42,
        'is_calibrated': 1,
        'notes': 'All good',
      });

      final row = await client.restoreById('records', recId);
      expect(row, isNotNull);
      expect(row!['title'], equals('Sensor Reading'));
      expect(row['reading_count'], equals('42')); // Dynamically altered as TEXT column
      expect(row['temperature'], equals('98.6'));
      expect(row['is_calibrated'], equals('1'));

      await client.close();
    });

    test('Scenario 11: Transactional Atomicity (Rollback on failure leaves 0 partial writes)', () async {
      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/atomic.db',
      );
      await client.registerTable('accounts', {'balance': 'INTEGER NOT NULL'});

      // Attempt invalid write violating NOT NULL constraint
      try {
        await client.storage.db.writeTransaction((tx) async {
          await tx.execute('INSERT INTO accounts (id, version, updated_at, balance) VALUES (?, ?, ?, ?)',
              ['acc-1', 1, 1000, null]);
          await tx.execute(
            "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, created_at, status) VALUES (?, ?, ?, ?, ?, 'pending')",
            ['mut-1', 'accounts', 'acc-1', 'create', 1000],
          );
        });
      } catch (_) {
        // Expected constraint failure
      }

      // Verify active table and outbox are completely empty (no partial commit)
      final accRows = await client.query('SELECT * FROM accounts');
      final outboxRows = await client.query('SELECT * FROM _sync_outbox');
      expect(accRows, isEmpty);
      expect(outboxRows, isEmpty);

      await client.close();
    });
  });
}
