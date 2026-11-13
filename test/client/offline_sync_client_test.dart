import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import '../sync_server/lib/sync_server.dart';

void main() {
  late Directory tempDir;
  late FakeSyncServer server;
  late OrbitClient client;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('client_facade_test_');
    server = await FakeSyncServer.start(port: 0);

    client = await OrbitClient.initialize(
      databasePath: '${tempDir.path}/app.db',
      baseUrl: server.baseUrl,
      maxReaders: 2,
    );

    await client.registerTable('tasks', {
      'title': 'TEXT',
      'priority': 'TEXT',
    });
  });

  tearDown(() async {
    await client.close();
    await server.stop();
    tempDir.deleteSync(recursive: true);
  });

  group('Issue 07: Unified Developer Client Facade (OrbitClient)', () {
    test('Test Case 1: Integrated CRUD & Zero-Codegen Stream Reactivity',
        () async {
      final emissions = <int>[];
      final completer = Completer<void>();

      // Listen to reactive stream
      final sub = client.watch('SELECT * FROM tasks ORDER BY id;').listen((rs) {
        emissions.add(rs.length);
        if (emissions.length == 3) {
          completer.complete();
        }
      });

      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Save record 1
      final id1 = UuidV7.generate();
      await client.save(
        entity: 'tasks',
        id: id1,
        data: {'title': 'Buy groceries', 'priority': 'high'},
      );

      // Save record 2
      final id2 = UuidV7.generate();
      await client.save(
        entity: 'tasks',
        id: id2,
        data: {'title': 'Wash car', 'priority': 'low'},
      );

      await completer.future.timeout(const Duration(seconds: 3));
      await sub.cancel();

      // Assert reactivity: 0 -> 1 -> 2
      expect(emissions, equals([0, 1, 2]));

      // Verify query returns 2 records
      final rows = await client.query('SELECT * FROM tasks;');
      expect(rows.length, 2);

      // Delete record 1
      await client.delete(entity: 'tasks', id: id1);
      final afterDelete = await client.query('SELECT * FROM tasks;');
      expect(afterDelete.length, 1);
      final decodedAfter = jsonDecode(afterDelete.first['data_json'] as String);
      expect(decodedAfter['title'], 'Wash car');
    });

    test('Test Case 2: Coordinated Bidirectional Sync (push + pull)', () async {
      // 1. Seed server with a remote task
      server.records['tasks:remote-1'] = {
        'title': 'Server Created Task',
        'priority': 'medium'
      };
      server.cursor++;
      server.changelog.add({
        'cursor': server.cursor,
        'entity': 'tasks',
        'id': 'remote-1',
        'op': 'upsert',
        '_deleted': false,
        'data': {'title': 'Server Created Task', 'priority': 'medium'},
        'version': 1,
      });

      // 2. Create local offline task
      final localId = UuidV7.generate();
      await client.save(
        entity: 'tasks',
        id: localId,
        data: {'title': 'Client Created Task', 'priority': 'high'},
      );

      // 3. Trigger coordinated sync() with pull to fetch remote changelog
      await client.sync(pull: true);

      // Assert client pushed localId to server
      expect(server.records.containsKey('tasks:$localId'), isTrue);
      expect(server.records['tasks:$localId']!['title'], 'Client Created Task');

      // Assert client pulled remote-1 into local database
      final localRows = await client
          .query("SELECT data_json FROM tasks WHERE id = 'remote-1';");
      expect(localRows, isNotEmpty);
      final decodedRemote = jsonDecode(localRows.first['data_json'] as String);
      expect(decodedRemote['title'], 'Server Created Task');
    });

    test('Test Case 3: Periodic Sync & Lifecycle Pause/Resume', () async {
      // Configure fast periodic sync for testing
      client.startPeriodicSync(interval: const Duration(milliseconds: 100));

      // 1. Save local item
      final id = UuidV7.generate();
      await client.save(
        entity: 'tasks',
        id: id,
        data: {'title': 'Periodic item'},
      );

      // Wait for periodic sync to trigger
      await Future<void>.delayed(const Duration(milliseconds: 250));

      // Assert synced to server
      expect(server.records.containsKey('tasks:$id'), isTrue);

      // 2. Pause sync (app background)
      client.pauseSync();
      expect(client.isPaused, isTrue);

      // Save another item while paused
      final pausedId = UuidV7.generate();
      await client.save(
        entity: 'tasks',
        id: pausedId,
        data: {'title': 'Item while paused'},
      );

      await Future<void>.delayed(const Duration(milliseconds: 250));

      // Assert item was NOT pushed while paused
      expect(server.records.containsKey('tasks:$pausedId'), isFalse);

      // 3. Resume sync (app foreground)
      client.resumeSync();
      expect(client.isPaused, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 150));

      // Assert item is now synced
      expect(server.records.containsKey('tasks:$pausedId'), isTrue);
    });

    test('Test Case 4: Clean Shutdown', () async {
      client.startPeriodicSync(interval: const Duration(milliseconds: 50));
      await client.close();

      // Assert calling close again is safe and idempotent
      await client.close();
    });

    test('Test Case 5: attachConnectivity triggers sync and logs are captured',
        () async {
      final logs = <String>[];
      final loggedClient = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/logged.db',
        baseUrl: server.baseUrl,
        onLog: logs.add,
      );
      await loggedClient.registerTable('tasks', {'title': 'TEXT'});

      final connectivityController = StreamController<bool>.broadcast();
      final sub =
          loggedClient.attachConnectivity(connectivityController.stream);

      // Save an item locally while offline
      final id = UuidV7.generate();
      await loggedClient.save(
          entity: 'tasks', id: id, data: {'title': 'Online trigger task'});

      expect(server.records.containsKey('tasks:$id'), isFalse);

      // Emit connectivity restored
      connectivityController.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // Assert synced automatically upon connectivity event
      expect(server.records.containsKey('tasks:$id'), isTrue);
      expect(logs.any((l) => l.contains('Successfully pushed')), isTrue);

      await sub.cancel();
      await connectivityController.close();
      await loggedClient.close();
    });

    test(
        'Test Case 6: Developer provides exact full URL, store and restore work offline, sync sends offline headers',
        () async {
      // 1. Spin up a standard REST endpoint simulator
      late String receivedMethod;
      late String receivedPath;
      final receivedHeaders = <String, String>{};
      late Map<String, dynamic> receivedBody;

      final restServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      restServer.listen((request) async {
        receivedMethod = request.method;
        receivedPath = request.uri.path;
        request.headers.forEach((name, values) {
          receivedHeaders[name] = values.join(',');
        });
        final bodyStr = await utf8.decoder.bind(request).join();
        receivedBody = jsonDecode(bodyStr) as Map<String, dynamic>;
        request.response.statusCode = HttpStatus.created;
        request.response.write(jsonEncode({'status': 'created'}));
        await request.response.close();
      });

      final fullEndpointUrl =
          'http://${restServer.address.host}:${restServer.port}/api/v1/custom-tasks';

      // 2. Initialize client as an outsider: developer supplies exact full URL
      final universalClient = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/universal.db',
      );
      await universalClient.registerEntity(
        'tasks',
        url: fullEndpointUrl,
        columnTypes: {'title': 'TEXT'},
      );

      // 3. STORE (Local backup: works 100% offline)
      final recordId = await universalClient.store('tasks', {
        'title': 'Universal offline task',
      });

      // 4. RESTORE (Read from local backup while offline)
      final offlineRecords = await universalClient.restore('tasks');
      expect(offlineRecords.length, equals(1));
      expect(offlineRecords.first['title'], equals('Universal offline task'));

      final singleRecord = await universalClient.restoreById('tasks', recordId);
      expect(singleRecord, isNotNull);
      expect(singleRecord!['title'], equals('Universal offline task'));

      // 5. SYNC: Drains queue directly to the developer's exact URL
      await universalClient.sync();

      // 6. Assert standard REST dispatch and zero metadata pollution (body and headers)
      expect(receivedMethod, equals('POST'));
      expect(receivedPath, equals('/api/v1/custom-tasks'));
      expect(receivedHeaders.containsKey('x-offline-sync'), isFalse);
      expect(receivedHeaders.containsKey('x-offline-created-at'), isFalse);
      expect(receivedHeaders.containsKey('idempotency-key'), isTrue);
      expect(receivedHeaders.containsKey('x-client-mutation-id'), isFalse);
      expect(receivedBody['title'], equals('Universal offline task'));
      // Zero Metadata Pollution: body and headers remain 100% clean domain data
      expect(receivedBody.containsKey('_offline_meta'), isFalse);

      // Assert outbox marked synced
      final failedMutations = await universalClient.getFailedMutations();
      expect(failedMutations, isEmpty);

      await universalClient.close();
      await restServer.close(force: true);
    });

    test('Test Case 7: Real-world Dead-Zone Entry and Auto-Drain on Reconnect',
        () async {
      final monitor = ConnectivityMonitor(
        timeout: const Duration(milliseconds: 100),
        heartbeatInterval: const Duration(milliseconds: 100),
        defaultProbeUrl:
            'http://127.0.0.1:59999', // Non-existent dead zone port
      );

      // Probe dead zone
      final reachable = await monitor.checkReachability();
      expect(reachable, isFalse);
      expect(monitor.isOnline, isFalse);

      // Start live server
      final liveServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final syncedItems = <String>[];
      liveServer.listen((request) async {
        final bodyStr = await utf8.decoder.bind(request).join();
        if (bodyStr.isNotEmpty) {
          final json = jsonDecode(bodyStr) as Map<String, dynamic>;
          if (json.containsKey('title')) {
            syncedItems.add(json['title'] as String);
          }
        }
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      });

      final client = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/deadzone.db',
        baseUrl: 'http://${liveServer.address.host}:${liveServer.port}',
        connectivityTimeout: const Duration(milliseconds: 100),
      );
      await client.registerEntity('tasks',
          url: 'http://${liveServer.address.host}:${liveServer.port}/tasks');

      // User creates item while in dead zone
      await client.store('tasks', {'title': 'Basement task'});

      // Assert saved locally in backup
      final offline = await client.restore('tasks');
      expect(offline.length, equals(1));
      expect(offline.first['title'], equals('Basement task'));
      expect(syncedItems, isEmpty);

      // Now reconnect: update probe URL to live server
      client.connectivity.defaultProbeUrl =
          'http://${liveServer.address.host}:${liveServer.port}';
      final reconnected = await client.connectivity.checkReachability();
      expect(reconnected, isTrue);

      // Trigger sync upon reconnect
      await client.sync();
      expect(syncedItems, contains('Basement task'));

      monitor.dispose();
      await client.close();
      await liveServer.close(force: true);
    });

    test(
        'Test Case 8: Strict Status Invariant and Rich Failure Details on HTTP 422 Rejection',
        () async {
      final errorServer =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      errorServer.listen((request) async {
        request.response.statusCode = HttpStatus.unprocessableEntity;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'statusCode': 422,
          'error': 'Warehouse ID 49 is closed',
        }));
        await request.response.close();
      });

      final client = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/failures.db',
      );
      await client.registerEntity(
        'orders',
        url:
            'http://${errorServer.address.host}:${errorServer.port}/api/orders',
      );

      // Store record locally
      final orderId = await client.store('orders', {
        'item': 'Pallet of goods',
        'warehouse_id': 49,
      });

      // Attempt sync
      await client.sync();

      // Assert status is NOT synced
      final rows = await client.query(
          "SELECT status FROM _sync_outbox WHERE entity_id = ?", [orderId]);
      expect(rows.first['status'], equals('validation_error'));

      // Assert typed SyncFailure returns structured reason
      final failures = await client.getFailures();
      expect(failures.length, equals(1));
      expect(failures.first.statusCode, equals(422));
      expect(
          failures.first.errorMessage, contains('Warehouse ID 49 is closed'));
      expect(failures.first.endpointUrl, contains('/api/orders'));

      await client.close();
      await errorServer.close(force: true);
    });

    test(
        'Test Case 9: Remote Data Hydration from Standard REST API (fetchAndStore)',
        () async {
      final restServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      restServer.listen((request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode([
          {'id': 'remote-1', 'title': 'First server note', 'version': 1},
          {'id': 'remote-2', 'title': 'Second server note', 'version': 1},
        ]));
        await request.response.close();
      });

      final client = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/hydrate.db',
      );
      await client.registerEntity('notes',
          url: 'http://${restServer.address.host}:${restServer.port}/notes');

      // Hydrate from server
      final count = await client.fetchAndStore(
        'notes',
        url: 'http://${restServer.address.host}:${restServer.port}/notes',
      );
      expect(count, equals(2));

      // Assert 100% available offline via restore()
      final offlineNotes = await client.restore('notes');
      expect(offlineNotes.length, equals(2));
      expect(
          offlineNotes.any((n) => n['title'] == 'First server note'), isTrue);
      expect(
          offlineNotes.any((n) => n['title'] == 'Second server note'), isTrue);

      // Assert zero outbox push mutations were created (since data originated from server)
      final outboxRows =
          await client.query("SELECT COUNT(*) as count FROM _sync_outbox");
      expect(outboxRows.first['count'], equals(0));

      await client.close();
      await restServer.close(force: true);
    });

    test(
        'Test Case 10: Headless Worker Background Sync (Alarm/WorkManager simulation)',
        () async {
      final dbPath = '${tempDir.path}/headless.db';

      // 1. Simulate UI storing a task before app is closed
      final mainClient = await OrbitClient.initialize(databasePath: dbPath);
      await mainClient.registerEntity('tasks', url: server.baseUrl);
      await mainClient.store('tasks', {'title': 'Pre-kill task'});
      await mainClient.close(); // App is killed!

      // 2. Simulate OS Alarm/WorkManager waking up in headless isolate
      await OrbitClient.headlessSync(
        databasePath: dbPath,
      );

      // Verify that headless sync safely drained the queue without UI running
      final checkClient = await OrbitClient.initialize(databasePath: dbPath);
      final outboxPending = await checkClient.query(
          "SELECT COUNT(*) as count FROM _sync_outbox WHERE status = 'pending'");
      expect(outboxPending.first['count'], equals(0));
      await checkClient.close();
    });

    test(
        'Test Case 11: client.storage.db.execute works for _sync_metadata and phase management',
        () async {
      await client.storage.db.execute(
        "INSERT OR REPLACE INTO _sync_metadata (key, value) VALUES ('test_key', 'test_val')",
      );
      final rows = await client.query(
        "SELECT value FROM _sync_metadata WHERE key = 'test_key'",
      );
      expect(rows.first['value'], equals('test_val'));

      await client.storage.db.execute(
        "DELETE FROM _sync_metadata WHERE key = 'test_key'",
      );
      final rowsAfter = await client.query(
        "SELECT value FROM _sync_metadata WHERE key = 'test_key'",
      );
      expect(rowsAfter, isEmpty);
    });
  });
}
