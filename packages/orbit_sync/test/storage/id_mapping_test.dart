import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/offline_sync.dart';
import 'storage_test_helpers.dart';

void main() {
  group('Layer 1 Storage: ID Mapping & Pruning', () {
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

    test('Test Case 9: _sync_id_map & pruneSynced', () async {
      await storage.registerServerId(
        entity: 'tasks',
        localTempId: 'temp-uuid-123',
        canonicalServerId: 'srv-999',
      );

      final resolvedServerId = await storage.getCanonicalServerId(
        entity: 'tasks',
        localTempId: 'temp-uuid-123',
      );
      expect(resolvedServerId, 'srv-999');

      final resolvedTempId = await storage.getLocalTempId(
        entity: 'tasks',
        canonicalServerId: 'srv-999',
      );
      expect(resolvedTempId, 'temp-uuid-123');

      final now = DateTime.now().millisecondsSinceEpoch;
      await storage.db.execute('''
        INSERT INTO _sync_outbox (
          mutation_id, entity_name, entity_id, op, status, created_at, updated_at
        ) VALUES ('synced-old', 'tasks', 't-1', 'create', 'synced', ?, ?)
      ''', [now - 100000000, now - 100000000]);

      final pruned = await storage.pruneSynced(olderThan: const Duration(hours: 1));
      expect(pruned, greaterThanOrEqualTo(1));
    });
  });
}
