import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/offline_sync.dart';
import 'storage_test_helpers.dart';

void main() {
  group('Layer 1 Storage: Cache Pruning & WAL Management', () {
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

    test('Test Case 12: TTL Local Cache Expiration & Dirty Record Shielding', () async {
      final cleanMutId = await storage.save(
        entity: 'orders',
        id: 'ord-ttl-clean',
        data: {'item': 'Clean Catalog Item', 'price': 10.0},
        ttl: const Duration(milliseconds: 50),
      );
      await storage.db.execute("UPDATE _sync_outbox SET status = 'synced' WHERE mutation_id = ?;", [cleanMutId]);

      await storage.save(
        entity: 'orders',
        id: 'ord-ttl-dirty',
        data: {'item': 'Unsynced Local Draft', 'price': 20.0},
        ttl: const Duration(milliseconds: 50),
      );

      await Future<void>.delayed(const Duration(milliseconds: 70));

      final prunedCount = await storage.pruneExpiredCache('orders');
      expect(prunedCount, 1);

      final cleanCheck = await storage.db.getAll("SELECT id FROM orders WHERE id = 'ord-ttl-clean';");
      expect(cleanCheck, isEmpty);

      final dirtyCheck = await storage.db.getAll("SELECT id FROM orders WHERE id = 'ord-ttl-dirty';");
      expect(dirtyCheck.length, 1);
      expect(dirtyCheck.first['id'], 'ord-ttl-dirty');
    });

    test('Test Case 16: WAL Checkpointing & Truncate', () async {
      await storage.save(
        entity: 'tasks',
        id: 'task-checkpoint-1',
        data: {'title': 'Checkpoint Task'},
      );

      await storage.checkpoint(truncate: false);
      await storage.checkpoint(truncate: true);
    });

    test('Test Case 17: Chunked Batch Operations (SQLITE_MAX_VARIABLE_NUMBER Defense)', () async {
      final largeIdList = List.generate(1200, (i) => 'id-$i');
      final processedBatches = <int>[];

      await SyncStorage.batchChunked<String>(
        largeIdList,
        chunkSize: 250,
        action: (chunk) async {
          processedBatches.add(chunk.length);
        },
      );

      expect(processedBatches, equals([250, 250, 250, 250, 200]));
    });
  });
}
