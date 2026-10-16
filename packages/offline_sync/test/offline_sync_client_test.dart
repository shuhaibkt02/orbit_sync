import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:sync_server/sync_server.dart';

void main() {
  late Directory tempDir;
  late FakeSyncServer server;
  late OfflineSyncClient client;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('client_facade_test_');
    server = await FakeSyncServer.start(port: 0);

    client = await OfflineSyncClient.initialize(
      databasePath: '${tempDir.path}/app.db',
      serverUrl: server.baseUrl,
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

  group('Issue 07: Unified Developer Client Facade (OfflineSyncClient)', () {
    test('Test Case 1: Integrated CRUD & Zero-Codegen Stream Reactivity', () async {
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
      expect(afterDelete.first['title'], 'Wash car');
    });

    test('Test Case 2: Coordinated Bidirectional Sync (push + pull)', () async {
      // 1. Seed server with a remote task
      server.records['tasks:remote-1'] = {'title': 'Server Created Task', 'priority': 'medium'};
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

      // 3. Trigger coordinated sync()
      await client.sync();

      // Assert client pushed localId to server
      expect(server.records.containsKey('tasks:$localId'), isTrue);
      expect(server.records['tasks:$localId']!['title'], 'Client Created Task');

      // Assert client pulled remote-1 into local database
      final localRows = await client.query("SELECT title FROM tasks WHERE id = 'remote-1';");
      expect(localRows, isNotEmpty);
      expect(localRows.first['title'], 'Server Created Task');
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

    test('Test Case 5: attachConnectivity triggers sync and logs are captured', () async {
      final logs = <String>[];
      final loggedClient = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/logged.db',
        serverUrl: server.baseUrl,
        onLog: logs.add,
      );
      await loggedClient.registerTable('tasks', {'title': 'TEXT'});

      final connectivityController = StreamController<bool>.broadcast();
      final sub = loggedClient.attachConnectivity(connectivityController.stream);

      // Save an item locally while offline
      final id = UuidV7.generate();
      await loggedClient.save(entity: 'tasks', id: id, data: {'title': 'Online trigger task'});

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

    test('Test Case 6: Developer provides exact full URL, store and restore work offline, sync sends offline headers', () async {
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

      final fullEndpointUrl = 'http://${restServer.address.host}:${restServer.port}/api/v1/custom-tasks';

      // 2. Initialize client as an outsider: developer supplies exact full URL
      final universalClient = await OfflineSyncClient.initialize(
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

      // 6. Assert standard REST dispatch and offline headers
      expect(receivedMethod, equals('POST'));
      expect(receivedPath, equals('/api/v1/custom-tasks'));
      expect(receivedHeaders['x-offline-sync'], equals('true'));
      expect(receivedHeaders['x-offline-created-at'], isNotNull);
      expect(receivedHeaders['idempotency-key'], isNotNull);
      expect(receivedBody['title'], equals('Universal offline task'));
      expect(receivedBody['_offline_meta'], isNotNull);
      expect(receivedBody['_offline_meta']['is_offline'], equals(true));

      // Assert outbox marked synced
      final failedMutations = await universalClient.getFailedMutations();
      expect(failedMutations, isEmpty);

      await universalClient.close();
      await restServer.close(force: true);
    });
  });
}
