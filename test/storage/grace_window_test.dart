import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'storage_test_helpers.dart';

void main() {
  group('Layer 1 Storage: Grace Window & Undo Operations', () {
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

    test(
        'Test Case 6: Grace Window (holdFor) Coalescing & Snapshot Revision Trail',
        () async {
      final mut1 = await storage.save(
        entity: 'tasks',
        id: 'task-grace-1',
        data: {'title': 'Initial Draft', 'priority': 'low'},
        holdFor: const Duration(minutes: 5),
      );

      final mut2 = await storage.save(
        entity: 'tasks',
        id: 'task-grace-1',
        data: {'title': 'Revised Draft', 'priority': 'high'},
        holdFor: const Duration(minutes: 5),
      );

      expect(mut2, equals(mut1));

      final outboxRows = await storage.db.getAll(
          "SELECT * FROM _sync_outbox WHERE entity_id = 'task-grace-1';");
      expect(outboxRows.length, 1);

      final outbox = outboxRows.first;
      expect(jsonDecode(outbox['payload_json'] as String)['title'],
          'Revised Draft');

      final history = jsonDecode(outbox['revision_history_json'] as String)
          as List<dynamic>;
      expect(history.length, 1);
      expect(history.first['snapshot']['title'], 'Initial Draft');
      expect(history.first['snapshot']['priority'], 'low');
    });

    test('Test Case 7: Zero-Network Local Annihilation on Grace Delete',
        () async {
      await storage.save(
        entity: 'tasks',
        id: 'task-grace-delete',
        data: {'title': 'To be deleted instantly'},
        holdFor: const Duration(minutes: 5),
      );

      final deleteMut = await storage.delete(
        entity: 'tasks',
        id: 'task-grace-delete',
      );

      expect(deleteMut, isNull);

      final domainRows = await storage.db
          .getAll("SELECT * FROM tasks WHERE id = 'task-grace-delete';");
      expect(domainRows, isEmpty);

      final outboxRows = await storage.db.getAll(
          "SELECT * FROM _sync_outbox WHERE entity_id = 'task-grace-delete';");
      expect(outboxRows, isEmpty);
    });

    test('Test Case 8: Undoable Delete and undoDelete()', () async {
      await storage.save(
        entity: 'tasks',
        id: 'task-undo-1',
        data: {'title': 'Undoable Task', 'priority': 'urgent'},
      );

      final delMut = await storage.delete(
        entity: 'tasks',
        id: 'task-undo-1',
        undoWindow: const Duration(seconds: 10),
      );
      expect(delMut, isNotNull);

      final domainAfterDel = await storage.db
          .getAll("SELECT * FROM tasks WHERE id = 'task-undo-1';");
      expect(domainAfterDel, isEmpty);

      final undone =
          await storage.undoDelete(entity: 'tasks', id: 'task-undo-1');
      expect(undone, isTrue);

      final domainRestored = await storage.db
          .getAll("SELECT * FROM tasks WHERE id = 'task-undo-1';");
      expect(domainRestored.length, 1);
      final restoredData =
          jsonDecode(domainRestored.first['data_json'] as String)
              as Map<String, dynamic>;
      expect(restoredData['title'], 'Undoable Task');

      final deleteOutbox = await storage.db.getAll(
          "SELECT * FROM _sync_outbox WHERE entity_id = 'task-undo-1' AND op = 'delete';");
      expect(deleteOutbox, isEmpty);

      final createOutbox = await storage.db.getAll(
          "SELECT * FROM _sync_outbox WHERE entity_id = 'task-undo-1' AND op = 'create';");
      expect(createOutbox.length, 1);
    });
  });
}
