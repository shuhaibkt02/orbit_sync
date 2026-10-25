import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/offline_sync.dart';
import 'package:orbit_sync/src/client/services/entity_hydrator.dart';

void main() {
  late Directory tempDir;
  late SyncStorage storage;
  late EntityHydrator hydrator;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('layer5_challenge1_');
    storage = await SyncStorage.open(path: '${tempDir.path}/test.db');
    hydrator = EntityHydrator(storage: storage);
    await storage.registerEntityTable('orders', {'total': 'REAL', 'status': 'TEXT'});
  });

  tearDown(() async {
    await storage.close();
    tempDir.deleteSync(recursive: true);
  });

  group('Layer 5 Facade: Challenge 1 Dirty Cache Overwrite & Shadow Baseline Re-basing', () {
    test('Hydration does NOT overwrite pending offline edits in domain table', () async {
      // 1. User creates or updates an order offline
      await storage.save(
        entity: 'orders',
        id: 'ord-101',
        data: {'total': 250.0, 'status': 'draft'},
      );

      // Verify offline state
      final localBefore = await storage.db.getAll('SELECT * FROM orders WHERE id = ?', ['ord-101']);
      expect(localBefore.first['total'], equals(250.0));
      expect(localBefore.first['status'], equals('draft'));

      // 2. Incoming server hydration snapshot with old dosage/total (100.0)
      final count = await hydrator.hydrateBatch(
        entity: 'orders',
        items: [
          {'id': 'ord-101', 'total': 100.0, 'status': 'submitted'},
          {'id': 'ord-102', 'total': 500.0, 'status': 'paid'},
        ],
      );

      expect(count, equals(1)); // Only ord-102 was inserted, ord-101 was shielded

      // 3. Assert local dirty order was NOT clobbered!
      final localAfter = await storage.db.getAll('SELECT * FROM orders WHERE id = ?', ['ord-101']);
      expect(localAfter.first['total'], equals(250.0));
      expect(localAfter.first['status'], equals('draft'));

      // 4. Assert clean order (ord-102) was successfully stored
      final ord102 = await storage.db.getAll('SELECT * FROM orders WHERE id = ?', ['ord-102']);
      expect(ord102.first['total'], equals(500.0));
    });

    test('Shadow Baseline Re-basing updates base_snapshot_json for dirty mutations', () async {
      await storage.save(
        entity: 'orders',
        id: 'ord-200',
        data: {'total': 300.0},
      );

      // Remote server returns updated baseline
      await hydrator.hydrateBatch(
        entity: 'orders',
        items: [
          {'id': 'ord-200', 'total': 150.0, 'server_rev': 4},
        ],
      );

      // Verify outbox base_snapshot_json was updated to newest server revision
      final outbox = await storage.db.getAll(
        "SELECT base_snapshot_json FROM _sync_outbox WHERE entity_id = 'ord-200'",
      );
      expect(outbox.first['base_snapshot_json'], isNotNull);
      final base = jsonDecode(outbox.first['base_snapshot_json'] as String) as Map<String, dynamic>;
      expect(base['server_rev'], equals(4));
    });
  });
}
