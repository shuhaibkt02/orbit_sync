import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/offline_sync.dart';
import 'package:sync_server/sync_server.dart';

void main() {
  late Directory tempDir;
  late FakeSyncServer server;
  late SyncStorage storage;
  late SyncWorker worker;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('schema_evo_test_');
    server = await FakeSyncServer.start(port: 0);

    storage = await SyncStorage.open(
      path: '${tempDir.path}/schema_client.db',
      maxReaders: 2,
    );

    await storage.registerEntityTable('users', {
      'name': 'TEXT',
      'first_name': 'TEXT',
      'last_name': 'TEXT',
    });

    worker = SyncWorker(storage: storage, serverUrl: server.baseUrl);
  });

  tearDown(() async {
    await storage.close();
    await server.stop();
    tempDir.deleteSync(recursive: true);
  });

  group('Issue 06: Schema Evolution & In-Flight Queued Mutation Upgrades (Challenge 8)', () {
    test('Test Case 1: Lazy Mutation Upcasting on Dequeue (v1 -> v2 Migration)', () async {
      // 1. Enqueue mutation while on schema v1 (monolithic name column)
      final mutId = await storage.save(
        entity: 'users',
        id: 'user-001',
        data: {'name': 'Johnathan Doe'},
        schemaVersion: 1,
      );

      final outboxV1 = await storage.db.get('SELECT schema_version, payload_json FROM _sync_outbox WHERE mutation_id = ?', [mutId]);
      expect(outboxV1['schema_version'], 1);
      expect(outboxV1['payload_json'], contains('Johnathan Doe'));

      // 2. Client updates to schema v2: splits 'name' into 'first_name' and 'last_name'
      worker.currentSchemaVersion = 2;
      worker.migrator = (fromVersion, toVersion, entity, payload) {
        if (fromVersion == 1 && toVersion == 2 && entity == 'users') {
          final fullName = payload['name'] as String;
          final split = fullName.split(' ');
          return {
            'first_name': split.first,
            'last_name': split.sublist(1).join(' '),
          };
        }
        return payload;
      };

      // 3. Worker dequeues and pushes
      final pushRes = await worker.pushBatch(batchSize: 1);
      expect(pushRes.status, SyncPushStatus.success);

      // 4. Assert outbox row was upgraded to schema_version 2 in local DB
      final outboxV2 = await storage.db.get('SELECT schema_version, payload_json, status FROM _sync_outbox WHERE mutation_id = ?', [mutId]);
      expect(outboxV2['schema_version'], 2);
      expect(outboxV2['status'], 'synced');
      final upgradedJson = jsonDecode(outboxV2['payload_json'] as String) as Map<String, dynamic>;
      expect(upgradedJson['first_name'], 'Johnathan');
      expect(upgradedJson['last_name'], 'Doe');

      // 5. Assert server received and stored the migrated v2 payload
      final serverRecord = server.records['users:user-001']!;
      expect(serverRecord['first_name'], 'Johnathan');
      expect(serverRecord['last_name'], 'Doe');
    });

    test('Test Case 2: Server Version Floor - HTTP 426 Upgrade Required (client_too_old)', () async {
      // 1. Server enforces minimum schema version floor = 2
      server.minSchemaVersion = 2;

      // 2. Client queue has an un-migrated mutation on schema v1
      final mutId = await storage.save(
        entity: 'users',
        id: 'user-v1-old',
        data: {'name': 'Deprecated Schema User'},
        schemaVersion: 1,
      );

      // Client worker is on v1 with no migrator
      worker.currentSchemaVersion = 1;

      // 3. Push attempt: server rejects with HTTP 426
      final pushRes = await worker.pushBatch(batchSize: 1);
      expect(pushRes.status, SyncPushStatus.needsUpgrade);
      expect(pushRes.errorMessage, contains('client_too_old'));

      // 4. Assert mutation remains 'pending' without burning retry count
      final outbox = await storage.db.get('SELECT status, retry_count FROM _sync_outbox WHERE mutation_id = ?', [mutId]);
      expect(outbox['status'], 'pending');
      expect(outbox['retry_count'], 0);
    });

    test('Test Case 3: Replay Integrity (In-Flight Retries Preserve Exact Bytes)', () async {
      worker.currentSchemaVersion = 2;
      worker.migrator = (from, to, entity, payload) {
        if (from == 1 && to == 2) {
          return {'first_name': 'Alice', 'last_name': 'Smith'};
        }
        return payload;
      };

      final mutId = await storage.save(
        entity: 'users',
        id: 'user-replay',
        data: {'name': 'Alice Smith'},
        schemaVersion: 1,
      );

      // Push with socket drop
      final dropRes = await worker.pushBatch(batchSize: 1, chaos: 'drop_before_response');
      expect(dropRes.status, SyncPushStatus.networkError);

      // Verify mutation is back in pending with schema_version 2 (upcasted once)
      final outboxAfterDrop = await storage.db.get('SELECT schema_version, payload_json FROM _sync_outbox WHERE mutation_id = ?', [mutId]);
      expect(outboxAfterDrop['schema_version'], 2);

      // Retry push: sends exact same upgraded payload without re-running migration
      final retryRes = await worker.pushBatch(batchSize: 1, force: true);
      expect(retryRes.status, SyncPushStatus.success);

      final outboxSynced = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [mutId]);
      expect(outboxSynced['status'], 'synced');
    });
  });
}
