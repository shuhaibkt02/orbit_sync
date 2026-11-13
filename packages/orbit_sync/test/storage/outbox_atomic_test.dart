import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'storage_test_helpers.dart';

void main() {
  group('Layer 1 Storage: Outbox Atomic & Cascading Operations', () {
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

    test('Test Case 2: Atomic Outbox Commit - Rollback on failure guarantees zero partial writes', () async {
      final initialCount = await storage.db.get('SELECT COUNT(*) as count FROM tasks;');
      expect(initialCount['count'], 0);

      expect(
        () async {
          await storage.db.writeTransaction((tx) async {
            await tx.execute("INSERT INTO tasks (id, title, priority, version, updated_at) VALUES ('atomic-1', 'Fail Title', 'low', 1, 1000);");
            throw Exception('Simulated crash during outbox commit');
          });
        },
        throwsA(isA<Exception>()),
      );

      final afterCount = await storage.db.get('SELECT COUNT(*) as count FROM tasks;');
      expect(afterCount['count'], 0);

      final outboxCount = await storage.db.get('SELECT COUNT(*) as count FROM _sync_outbox;');
      expect(outboxCount['count'], 0);
    });

    test('Test Case 3: Shadow-Base Materialization & Optimistic Rollback', () async {
      await storage.save(
        entity: 'tasks',
        id: 'task-100',
        data: {'title': 'Original Title', 'priority': 'low'},
        version: 1,
      );

      final row1 = await storage.db.get('SELECT * FROM tasks WHERE id = ?', ['task-100']);
      final data1 = jsonDecode(row1['data_json'] as String) as Map<String, dynamic>;
      expect(data1['title'], 'Original Title');
      expect(data1['priority'], 'low');
      expect(row1.containsKey('_base_snapshot_json'), isFalse);

      final mut2 = await storage.save(
        entity: 'tasks',
        id: 'task-100',
        data: {'title': 'Optimistic Title', 'priority': 'high'},
        version: 2,
      );

      final row2 = await storage.db.get('SELECT * FROM tasks WHERE id = ?', ['task-100']);
      final data2 = jsonDecode(row2['data_json'] as String) as Map<String, dynamic>;
      expect(data2['title'], 'Optimistic Title');
      expect(data2['priority'], 'high');

      final outbox2 = await storage.db.get('SELECT * FROM _sync_outbox WHERE mutation_id = ?', [mut2]);
      final baseSnapshot = jsonDecode(outbox2['base_snapshot_json'] as String) as Map<String, dynamic>;
      expect(baseSnapshot['title'], 'Original Title');
      expect(baseSnapshot['priority'], 'low');

      await storage.rollbackOptimistic(mut2, status: 'conflict');

      final rowRestored = await storage.db.get('SELECT * FROM tasks WHERE id = ?', ['task-100']);
      final dataRestored = jsonDecode(rowRestored['data_json'] as String) as Map<String, dynamic>;
      expect(dataRestored['title'], 'Original Title');
      expect(dataRestored['priority'], 'low');

      final outboxStatus = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [mut2]);
      expect(outboxStatus['status'], 'conflict');
    });

    test('Test Case 13: Foreign Key Cascade Capture on Outbox Deletion', () async {
      await storage.registerEntityTable('invoices', {'customer': 'TEXT'});
      await storage.db.execute('''
        CREATE TABLE IF NOT EXISTS "line_items" (
          "id" TEXT PRIMARY KEY,
          "version" INTEGER NOT NULL DEFAULT 1 CHECK ("version" >= 1),
          "updated_at" INTEGER NOT NULL,
          "expires_at" INTEGER,
          "data_json" TEXT NOT NULL DEFAULT '{}',
          "invoice_id" TEXT,
          FOREIGN KEY ("invoice_id") REFERENCES "invoices"("id") ON DELETE CASCADE
        );
      ''');

      await storage.save(
        entity: 'invoices',
        id: 'inv-100',
        data: {'customer': 'Acme Corp'},
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      await storage.db.execute(
        'INSERT INTO line_items (id, version, updated_at, expires_at, data_json, invoice_id) VALUES (?, 1, ?, null, ?, ?)',
        ['item-1', now, '{"id":"item-1","description":"Widget A"}', 'inv-100'],
      );
      await storage.db.execute(
        'INSERT INTO line_items (id, version, updated_at, expires_at, data_json, invoice_id) VALUES (?, 1, ?, null, ?, ?)',
        ['item-2', now, '{"id":"item-2","description":"Widget B"}', 'inv-100'],
      );

      final delMut = await storage.delete(entity: 'invoices', id: 'inv-100');
      expect(delMut, isNotNull);

      final parentOutbox = await storage.db.getAll(
        "SELECT * FROM _sync_outbox WHERE entity_name = 'invoices' AND entity_id = 'inv-100' AND op = 'delete';",
      );
      expect(parentOutbox.length, 1);

      final childOutbox = await storage.db.getAll(
        "SELECT * FROM _sync_outbox WHERE entity_name = 'line_items' AND op = 'delete' ORDER BY entity_id;",
      );
      expect(childOutbox.length, 2);
      expect(childOutbox[0]['entity_id'], 'item-1');
      expect(childOutbox[1]['entity_id'], 'item-2');
    });
  });
}
