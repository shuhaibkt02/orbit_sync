import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/offline_sync.dart';
import 'storage_test_helpers.dart';

void main() {
  group('Layer 1 Storage: Engine & Concurrency', () {
    late Directory tempDir;
    late SyncStorage storage;

    setUp(() async {
      final res = await createTestStorage();
      tempDir = res.tempDir;
      storage = res.storage;
    });

    tearDown(() async {
      await storage.close();
      tempDir.deleteSync(recursive: true);
    });

    test('Engine Setup & Outbox Schema verification', () async {
      // Assert journal_mode is WAL
      final journalMode = await storage.db.get('PRAGMA journal_mode;');
      expect(journalMode['journal_mode'].toString().toLowerCase(), 'wal');

      // Verify outbox schema columns
      final tableInfo = await storage.db.getAll('PRAGMA table_info(_sync_outbox);');
      final colNames = tableInfo.map((r) => r['name'] as String).toSet();
      expect(colNames, containsAll([
        'sequence_id',
        'mutation_id',
        'entity_name',
        'entity_id',
        'op',
        'payload_json',
        'base_snapshot_json',
        'base_version',
        'status',
        'depends_on_mutation_id',
        'correlation_tag',
        'priority',
        'sla_seconds',
        'schema_version',
        'dispatch_after',
        'revision_history_json',
        'retry_count',
        'next_retry_at',
        'created_at',
        'updated_at',
      ]));

      // Verify _sync_id_map table exists
      final idMapInfo = await storage.db.getAll('PRAGMA table_info(_sync_id_map);');
      final idMapCols = idMapInfo.map((r) => r['name'] as String).toSet();
      expect(idMapCols, containsAll([
        'entity_name',
        'local_temp_id',
        'canonical_server_id',
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
  });
}
