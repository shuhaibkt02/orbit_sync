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
    tempDir = Directory.systemTemp.createTempSync('sync_pull_test_');
    server = await FakeSyncServer.start(port: 0);

    storage = await SyncStorage.open(path: '${tempDir.path}/client.db', maxReaders: 4);
    await storage.registerEntityTable('tasks', {'title': 'TEXT', 'dept': 'TEXT'});
    worker = SyncWorker(storage: storage, serverUrl: server.baseUrl, pullPageLimit: 50);
  });

  tearDown(() async {
    await storage.close();
    await server.stop();
    tempDir.deleteSync(recursive: true);
  });

  group('Layer 2 Consensus: SyncWorker Pull Operations', () {
    test('Test Case 1: Checkpointed Pull & Mid-Sync Termination (Challenge 4)', () async {
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

      final p1 = await worker.pullPage();
      expect(p1.changeCount, 50);
      expect(p1.nextCursor, 50);

      final p2 = await worker.pullPage();
      expect(p2.changeCount, 50);
      expect(p2.nextCursor, 100);

      final checkpointCursor = await worker.getLastSyncedCursor();
      expect(checkpointCursor, 100);

      final countMidway = await storage.db.get('SELECT COUNT(*) as count FROM tasks;');
      expect(countMidway['count'], 100);

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

      final recoveredCursor = await newWorker.getLastSyncedCursor();
      expect(recoveredCursor, 100);

      await newWorker.pullAll();

      final finalCount = await reopenedStorage.db.get('SELECT COUNT(*) as count FROM tasks;');
      expect(finalCount['count'], 250);

      await reopenedStorage.close();
    });

    test('Test Case 2: Scope Eviction vs Tombstone (Challenge 5)', () async {
      server.records['tasks:t-del'] = {'title': 'Will Delete'};
      server.cursor++;
      server.changelog.add({
        'cursor': server.cursor,
        'entity': 'tasks',
        'id': 't-del',
        'op': 'delete',
        '_deleted': true,
        'data': null,
        'version': 2,
      });

      server.records['tasks:t-scoped'] = {'title': 'Dept Eng', 'dept': 'eng'};
      server.cursor++;
      server.changelog.add({
        'cursor': server.cursor,
        'entity': 'tasks',
        'id': 't-scoped',
        'op': 'upsert',
        '_deleted': false,
        'data': {'title': 'Dept Eng', 'dept': 'eng'},
        'version': 1,
      });

      await worker.pullAll();

      final scopedRow = await storage.db.get("SELECT title FROM tasks WHERE id = 't-scoped';");
      expect(scopedRow['title'], 'Dept Eng');

      server.cursor++;
      server.changelog.add({
        'cursor': server.cursor,
        'entity': 'tasks',
        'id': 't-scoped',
        'op': 'evict',
        'left_scope': true,
        'data': null,
        'version': 2,
      });

      await worker.pullAll();

      final evictedRow = await storage.db.getOptional("SELECT title FROM tasks WHERE id = 't-scoped';");
      expect(evictedRow, isNull);
    });
  });
}
