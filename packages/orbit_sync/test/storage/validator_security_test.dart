import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/offline_sync.dart';
import 'storage_test_helpers.dart';

void main() {
  group('Layer 1 Storage: Validation & Injection Defense', () {
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

    test('Test Case 11: Static System Field Validation & Injection Defense', () async {
      // 1. SQL Injection attempt in entity name rejected
      expect(
        () => storage.save(
          entity: 'tasks; DROP TABLE _sync_outbox;',
          id: 'task-inj-1',
          data: {'title': 'Malicious'},
        ),
        throwsA(isA<ArgumentError>()),
      );

      // 2. Empty ID rejected
      expect(
        () => storage.save(
          entity: 'tasks',
          id: '   ',
          data: {'title': 'Empty ID'},
        ),
        throwsA(isA<ArgumentError>()),
      );

      // 3. Negative version rejected
      expect(
        () => storage.save(
          entity: 'tasks',
          id: 'task-neg-ver',
          data: {'title': 'Invalid Version'},
          version: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );

      // 4. Invalid priority rejected
      expect(
        () => storage.save(
          entity: 'tasks',
          id: 'task-bad-pri',
          data: {'title': 'Invalid Priority'},
          priority: 99,
        ),
        throwsA(isA<ArgumentError>()),
      );

      // 5. Negative duration rejected
      expect(
        () => storage.save(
          entity: 'tasks',
          id: 'task-neg-dur',
          data: {'title': 'Negative Duration'},
          holdFor: const Duration(seconds: -5),
        ),
        throwsA(isA<ArgumentError>()),
      );

      // 6. Invalid HTTP method rejected
      expect(
        () => storage.save(
          entity: 'tasks',
          id: 'task-bad-method',
          data: {'title': 'Bad HTTP Method'},
          httpMethod: 'INVALID_VERB',
        ),
        throwsA(isA<ArgumentError>()),
      );

      // 7. Reserved SQL keywords ('order', 'group', 'where') do not cause query syntax errors
      final reservedMutId = await storage.save(
        entity: 'order',
        id: 'ord-reserved-1',
        data: {
          'group': 'vip_customers',
          'where': 'warehouse_north',
          'check': 100,
        },
      );
      expect(reservedMutId, isNotEmpty);
      final reservedRow = await storage.db.get('SELECT * FROM "order" WHERE "id" = ?;', ['ord-reserved-1']);
      expect(reservedRow['group'], 'vip_customers');
      expect(reservedRow['where'], 'warehouse_north');
    });
  });
}
