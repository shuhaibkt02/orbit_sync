import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'package:orbit_sync/src/client/services/schema_migration_runner.dart';

void main() {
  late Directory tempDir;
  late SyncStorage storage;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('layer5_challenge7_');
    storage = await SyncStorage.open(path: '${tempDir.path}/test.db');
  });

  tearDown(() async {
    await storage.close();
    tempDir.deleteSync(recursive: true);
  });

  group('Layer 5 Facade: Challenge 7 Two-Tier Schema Evolution (Isolated Metadata)', () {
    test('Schema version is stored in _sync_metadata and does NOT touch PRAGMA user_version', () async {
      // Simulate host app setting PRAGMA user_version to 42 (e.g. Drift / sqflite)
      await storage.db.execute('PRAGMA user_version = 42;');

      final runner = SchemaMigrationRunner(storage: storage, targetSchemaVersion: 3);
      await runner.setCurrentVersion(3);

      final pluginVersion = await runner.getCurrentVersion();
      expect(pluginVersion, equals(3));

      // Verify host app user_version was NOT clobbered!
      final hostPragma = await storage.db.getAll('PRAGMA user_version;');
      expect(hostPragma.first['user_version'], equals(42));
    });

    test('SchemaMigrationRunner step-ladders mutation envelopes eagerly', () async {
      // Seed outbox with v1 mutation
      await storage.save(
        entity: 'profiles',
        id: 'prof-1',
        data: {'first_name': 'John', 'last_name': 'Doe'},
        schemaVersion: 1,
      );

      // Migrator upgrading v1 -> v2 (combining name fields)
      final runner = SchemaMigrationRunner(
        storage: storage,
        targetSchemaVersion: 2,
        migrator: (fromV, toV, entity, payload) {
          if (fromV == 1 && toV == 2 && entity == 'profiles') {
            final first = payload['first_name'];
            final last = payload['last_name'];
            return {'full_name': '$first $last'};
          }
          return payload;
        },
      );

      final count = await runner.runEagerMigrations();
      expect(count, equals(1));

      // Verify payload was upgraded in place
      final rows = await storage.db.getAll("SELECT * FROM _sync_outbox WHERE entity_name = 'profiles'");
      expect(rows.first['schema_version'], equals(2));
      final upgraded = jsonDecode(rows.first['payload_json'] as String) as Map<String, dynamic>;
      expect(upgraded['full_name'], equals('John Doe'));
      expect(upgraded.containsKey('first_name'), isFalse);
    });
  });
}
