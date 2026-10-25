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

    final schema = {
      'title': 'TEXT',
      'priority': 'TEXT',
      'start_time': 'TEXT',
      'end_time': 'TEXT',
      'stock': 'INTEGER',
    };

    storageA = await SyncStorage.open(path: '${tempDir.path}/client_a.db', maxReaders: 2);
    await storageA.registerEntityTable('tasks', schema);
    workerA = SyncWorker(storage: storageA, serverUrl: server.baseUrl);

    storageB = await SyncStorage.open(path: '${tempDir.path}/client_b.db', maxReaders: 2);
    await storageB.registerEntityTable('tasks', schema);
    workerB = SyncWorker(storage: storageB, serverUrl: server.baseUrl);
  });

  tearDown(() async {
    await storageA.close();
    await storageB.close();
    await server.stop();
    tempDir.deleteSync(recursive: true);
  });

  group('Layer 2 Consensus: Conflict & Convergence', () {
    test('Test Case 1: Non-Conflicting Field Merge & Convergence across Two Clients', () async {
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

      await workerA.pullAll();
      await workerB.pullAll();

      await storageA.save(entity: 'tasks', id: 't-1', data: {'title': 'Updated by A', 'priority': 'low'});
      await storageB.save(entity: 'tasks', id: 't-1', data: {'title': 'Initial Title', 'priority': 'high'});

      await workerA.pushBatch();
      await workerB.pullAll();

      final bMerged = await storageB.db.get("SELECT title, priority FROM tasks WHERE id = 't-1';");
      expect(bMerged['title'], 'Updated by A');
      expect(bMerged['priority'], 'high');

      await workerB.pushBatch();
      await workerA.pullAll();

      final aFinal = await storageA.db.get("SELECT title, priority FROM tasks WHERE id = 't-1';");
      final bFinal = await storageB.db.get("SELECT title, priority FROM tasks WHERE id = 't-1';");
      expect(aFinal['title'], 'Updated by A');
      expect(aFinal['priority'], 'high');
      expect(bFinal['title'], 'Updated by A');
      expect(bFinal['priority'], 'high');
      expect(aFinal, equals(bFinal));
    });

    test('Test Case 2: Co-Dependent Invariant Violation Rejects Auto-Merge', () async {
      workerB.validateInvariants = (entity, record) {
        if (entity == 'tasks') {
          final start = record['start_time'] as String?;
          final end = record['end_time'] as String?;
          if (start != null && end != null && start.compareTo(end) >= 0) {
            return 'start_time ($start) must be strictly before end_time ($end)';
          }
        }
        return null;
      };

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

      await storageA.save(
        entity: 'tasks',
        id: 'event-1',
        data: {'title': 'Meeting', 'start_time': '18:00', 'end_time': '17:00'},
      );
      final mutB = await storageB.save(
        entity: 'tasks',
        id: 'event-1',
        data: {'title': 'Meeting', 'start_time': '09:00', 'end_time': '12:00'},
      );

      await workerA.pushBatch();
      await workerB.pullAll();

      final conflictOutbox = await storageB.db.get(
        'SELECT status, error_details_json FROM _sync_outbox WHERE mutation_id = ?;',
        [mutB],
      );
      expect(conflictOutbox['status'], 'conflict');
      expect(conflictOutbox['error_details_json'], contains('must be strictly before'));

      final localRow = await storageB.db.get("SELECT start_time, end_time FROM tasks WHERE id = 'event-1';");
      expect(localRow['start_time'], '09:00');
      expect(localRow['end_time'], '12:00');
    });

    test('Test Case 3: Pluggable EntityConflictResolver converges non-scalar counters', () async {
      // Register semilattice counter resolver for tasks stock: base + deltaA + deltaB
      workerB.registerConflictResolver('tasks', ({required baseSnapshot, required localRecord, required remoteRecord}) {
        final baseStock = (baseSnapshot?['stock'] as int?) ?? 10;
        final localStock = (localRecord['stock'] as int?) ?? baseStock;
        final remoteStock = (remoteRecord['stock'] as int?) ?? baseStock;

        final deltaLocal = localStock - baseStock;
        final deltaRemote = remoteStock - baseStock;
        final resolvedStock = baseStock + deltaLocal + deltaRemote;

        final merged = Map<String, dynamic>.from(remoteRecord);
        merged['stock'] = resolvedStock;
        return merged;
      });

      // 1. Initial shared record on server: Task(id: 'inv-1', title: 'Widget', stock: 10)
      server.records['tasks:inv-1'] = {'title': 'Widget', 'stock': 10};
      server.cursor++;
      server.changelog.add({
        'cursor': server.cursor,
        'entity': 'tasks',
        'id': 'inv-1',
        'op': 'upsert',
        '_deleted': false,
        'data': {'title': 'Widget', 'stock': 10},
        'version': 1,
      });

      await workerA.pullAll();
      await workerB.pullAll();

      // Device A sells 2 units (stock: 8)
      await storageA.save(entity: 'tasks', id: 'inv-1', data: {'title': 'Widget', 'stock': 8});
      // Device B sells 3 units (stock: 7)
      await storageB.save(entity: 'tasks', id: 'inv-1', data: {'title': 'Widget', 'stock': 7});

      // Device A pushes stock 8 to server
      await workerA.pushBatch();

      // Device B pulls: resolver merges deltaLocal (-3) + deltaRemote (-2) = final stock 5!
      await workerB.pullAll();

      final bResolved = await storageB.db.get("SELECT stock FROM tasks WHERE id = 'inv-1';");
      expect(bResolved['stock'], 5);
    });
  });
}
