import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'storage_test_helpers.dart';

void main() {
  group('Layer 1 Storage: Clean Architecture & SOLID Dependency Inversion', () {
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

    test('Test Case 18: Clean Architecture & SOLID Dependency Inversion (Pluggable Repositories)', () async {
      final mockOutbox = MockOutboxRepo();
      final mockIdMap = MockIdMapRepo();

      final customStorage = SyncStorage.withRepositories(
        db: storage.db,
        path: ':memory:',
        outboxRepo: mockOutbox,
        idMapRepo: mockIdMap,
      );

      final mutId = await customStorage.save(
        entity: 'tasks',
        id: 'mock-1',
        data: {'name': 'Mock Task'},
      );
      expect(mutId, equals('mock-mutation-id'));
      expect(mockOutbox.saveCalled, isTrue);

      await customStorage.registerServerId(
        entity: 'tasks',
        localTempId: 'temp-1',
        canonicalServerId: 'srv-1',
      );
      expect(mockIdMap.registerCalled, isTrue);
    });
  });
}
