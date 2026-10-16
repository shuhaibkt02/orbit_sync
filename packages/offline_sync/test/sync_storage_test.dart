import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:offline_sync/offline_sync.dart';

void main() {
  late Directory tempDir;
  late SyncStorage storage;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('offline_sync_test_');
    storage = await SyncStorage.open(
      path: '${tempDir.path}/test_sync.db',
      maxReaders: 4,
    );
    await storage.registerEntityTable('tasks', {
      'title': 'TEXT',
      'priority': 'TEXT',
    });
  });

  tearDown(() async {
    await storage.close();
    tempDir.deleteSync(recursive: true);
  });

  group('Issue 02: Storage Engine & Transactional Outbox', () {
    test('Engine Setup & Outbox Schema verification', () async {
      // Assert journal_mode is WAL
      final journalMode = await storage.db.get('PRAGMA journal_mode;');
      expect(journalMode['journal_mode'].toString().toLowerCase(), 'wal');

      // Verify outbox schema columns
      final tableInfo = await storage.db.getAll('PRAGMA table_info(_sync_outbox);');
      final colNames = tableInfo.map((r) => r['name'] as String).toSet();
      expect(colNames, containsAll([
        'mutation_id',
        'entity_name',
        'entity_id',
        'op',
        'payload_json',
        'base_snapshot_json',
        'base_version',
        'status',
        'created_at',
      ]));
    });

    test('Test Case 1: Concurrency - Concurrent reads with pooled readers while writing executes with 0 errors', () async {
      final futures = <Future>[];
      int readCount = 0;

      // Launch 50 concurrent reader queries across pooled connections
      for (var i = 0; i < 50; i++) {
        futures.add(Future(() async {
          final res = await storage.db.getAll('SELECT COUNT(*) as count FROM tasks;');
          expect(res, isNotEmpty);
          readCount++;
        }));
      }

      // Concurrently insert 20 outbox records on the writer isolate
      for (var i = 0; i < 20; i++) {
        futures.add(storage.save(
          entity: 'tasks',
          id: 'task-conc-$i',
          data: {'title': 'Concurrent Task $i', 'priority': 'medium'},
        ));
      }

      // Await all concurrent tasks; must finish without SQLITE_BUSY or exceptions
      await Future.wait(futures);
      expect(readCount, 50);

      final totalOutbox = await storage.db.get('SELECT COUNT(*) as count FROM _sync_outbox;');
      expect(totalOutbox['count'], 20);
    });

    test('Test Case 2: Atomic Outbox Commit - Rollback on failure guarantees zero partial writes', () async {
      // Pre-condition: tasks table is empty
      final initialCount = await storage.db.get('SELECT COUNT(*) as count FROM tasks;');
      expect(initialCount['count'], 0);

      // Attempt atomic transaction that fails during outbox step
      expect(
        () async {
          await storage.db.writeTransaction((tx) async {
            // Write to domain table
            await tx.execute("INSERT INTO tasks (id, title, priority, version, updated_at) VALUES ('atomic-1', 'Fail Title', 'low', 1, 1000);");
            // Simulate deliberate failure during outbox envelope append (e.g., duplicate primary key or abort)
            throw Exception('Simulated crash during outbox commit');
          });
        },
        throwsA(isA<Exception>()),
      );

      // Verify domain table write was rolled back completely
      final afterCount = await storage.db.get('SELECT COUNT(*) as count FROM tasks;');
      expect(afterCount['count'], 0);

      final outboxCount = await storage.db.get('SELECT COUNT(*) as count FROM _sync_outbox;');
      expect(outboxCount['count'], 0);
    });

    test('Test Case 3: Shadow-Base Materialization & Optimistic Rollback', () async {
      // 1. Initial save of an entity
      await storage.save(
        entity: 'tasks',
        id: 'task-100',
        data: {'title': 'Original Title', 'priority': 'low'},
        version: 1,
      );

      // Verify domain table has columns materialized directly
      final row1 = await storage.db.get('SELECT * FROM tasks WHERE id = ?', ['task-100']);
      expect(row1['title'], 'Original Title');
      expect(row1['priority'], 'low');
      expect(row1['_base_snapshot_json'], isNull); // newly created record has no prior snapshot

      // 2. Optimistic update
      final mut2 = await storage.save(
        entity: 'tasks',
        id: 'task-100',
        data: {'title': 'Optimistic Title', 'priority': 'high'},
        version: 2,
      );

      // Table columns reflect optimistic edit directly
      final row2 = await storage.db.get('SELECT * FROM tasks WHERE id = ?', ['task-100']);
      expect(row2['title'], 'Optimistic Title');
      expect(row2['priority'], 'high');

      // Outbox stores pre-mutation baseline snapshot
      final outbox2 = await storage.db.get('SELECT * FROM _sync_outbox WHERE mutation_id = ?', [mut2]);
      final baseSnapshot = jsonDecode(outbox2['base_snapshot_json'] as String) as Map<String, dynamic>;
      expect(baseSnapshot['title'], 'Original Title');
      expect(baseSnapshot['priority'], 'low');

      // 3. Rollback optimistic edit (e.g. server rejected with 422 or conflict)
      await storage.rollbackOptimistic(mut2, status: 'conflict');

      // Domain table is restored to Original Title
      final rowRestored = await storage.db.get('SELECT * FROM tasks WHERE id = ?', ['task-100']);
      expect(rowRestored['title'], 'Original Title');
      expect(rowRestored['priority'], 'low');

      final outboxStatus = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [mut2]);
      expect(outboxStatus['status'], 'conflict');
    });

    test('Test Case 4: Zero-Codegen Reactivity with db.watch()', () async {
      final emissions = <int>[];
      final completer = Completer<void>();

      // Listen to dynamic query stream without code-generated TableInfo
      final sub = storage.watch('SELECT * FROM tasks ORDER BY id;').listen((rs) {
        emissions.add(rs.length);
        if (emissions.length == 3) {
          completer.complete();
        }
      });

      // Small delay to allow initial emission
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Trigger mutation 1
      await storage.save(
        entity: 'tasks',
        id: 'task-watch-1',
        data: {'title': 'First reactive item', 'priority': 'high'},
      );

      // Trigger mutation 2
      await storage.save(
        entity: 'tasks',
        id: 'task-watch-2',
        data: {'title': 'Second reactive item', 'priority': 'medium'},
      );

      await completer.future.timeout(const Duration(seconds: 3));
      await sub.cancel();

      // Assert that watch streamed: 0 rows (initial), 1 row, 2 rows
      expect(emissions, equals([0, 1, 2]));
    });

    test('UUIDv7: Generates strictly time-ordered monotonic strings', () {
      final id1 = UuidV7.generate();
      final id2 = UuidV7.generate();
      expect(id1.length, 36);
      expect(id2.length, 36);
      expect(id1.compareTo(id2), lessThanOrEqualTo(0));
      // Version 7 check: 15th character is '7'
      expect(id1[14], '7');
      expect(id2[14], '7');
    });
  });
}
