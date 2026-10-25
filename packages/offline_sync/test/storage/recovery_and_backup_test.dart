import 'dart:io';
import 'package:test/test.dart';
import 'package:offline_sync/offline_sync.dart';
import 'storage_test_helpers.dart';

void main() {
  group('Layer 1 Storage: Corruption Recovery & Cloud Backup Shield', () {
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

    test('Test Case 14: Database Corruption Quarantine & Auto-Recreation', () async {
      final corruptDbFile = File('${tempDir.path}/corrupt_test.db');
      corruptDbFile.writeAsBytesSync(List.filled(512, 0xFF));

      String? quarantinedPath;
      final recoveredStorage = await SyncStorage.open(
        path: corruptDbFile.path,
        onDatabaseCorrupted: (path) {
          quarantinedPath = path;
        },
      );

      expect(quarantinedPath, isNotNull);
      expect(File(quarantinedPath!).existsSync(), isTrue);

      expect(corruptDbFile.existsSync(), isTrue);

      final mutId = await recoveredStorage.save(
        entity: 'tasks',
        id: 'task-after-recovery',
        data: {'title': 'Recovered and working'},
      );
      expect(mutId, isNotEmpty);

      await recoveredStorage.close();
    });

    test('Test Case 15: Mocked Cloud Backup Shield & Time-Travel Restore Detection', () async {
      final dbPath = '${tempDir.path}/timetravel_test.db';
      final mockSecureStorage = <String, String>{};
      String? shieldedPath;
      String? detectedMismatchSqlite;
      String? detectedMismatchSecure;

      final storage1 = await SyncStorage.open(
        path: dbPath,
        backupShield: (path) async {
          shieldedPath = path;
          return true;
        },
        secureStorageReader: (k) async => mockSecureStorage[k],
        secureStorageWriter: (k, v) async => mockSecureStorage[k] = v,
      );

      expect(shieldedPath, dbPath);
      expect(mockSecureStorage['orbit_installation_id'], isNotNull);
      final initialId = mockSecureStorage['orbit_installation_id']!;

      await storage1.save(
        entity: 'tasks',
        id: 'task-time-travel-1',
        data: {'title': 'Old draft from Device A'},
      );

      final outbox1 = await storage1.db.getAll("SELECT status FROM _sync_outbox WHERE entity_id = 'task-time-travel-1';");
      expect(outbox1.first['status'], 'pending');

      await storage1.close();

      mockSecureStorage['orbit_installation_id'] = 'device-B-keychain-id-999';

      final storageDeviceB = await SyncStorage.open(
        path: dbPath,
        secureStorageReader: (k) async => mockSecureStorage[k],
        secureStorageWriter: (k, v) async => mockSecureStorage[k] = v,
        onTimeTravelBackupDetected: (sqliteId, secureId) {
          detectedMismatchSqlite = sqliteId;
          detectedMismatchSecure = secureId;
        },
      );

      expect(detectedMismatchSqlite, initialId);
      expect(detectedMismatchSecure, 'device-B-keychain-id-999');

      final outboxDeviceB = await storageDeviceB.db.getAll("SELECT status FROM _sync_outbox WHERE entity_id = 'task-time-travel-1';");
      expect(outboxDeviceB.first['status'], 'held');

      await storageDeviceB.close();
    });
  });
}
