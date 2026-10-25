import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/offline_sync.dart';

void main() {
  late Directory tempDir;
  late OfflineSyncClient client;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('layer5_challenge8_');
    client = await OfflineSyncClient.initialize(
      databasePath: '${tempDir.path}/test.db',
      transport: SyncTransport.inMemory(),
    );
  });

  tearDown(() async {
    if (!client.isClosed) await client.close();
    tempDir.deleteSync(recursive: true);
  });

  group('Layer 5 Facade: Challenge 8 Teardown Drain Protocol & Timeout Budget', () {
    test('close() is idempotent and safely callable multiple times concurrently', () async {
      await Future.wait([
        client.close(),
        client.close(),
        client.close(),
      ]);

      expect(client.isClosed, isTrue);
    });

    test('Inbound operations are rejected immediately with ClientClosedException once closed', () async {
      await client.close();

      expect(
        () => client.save(entity: 'tasks', data: {'title': 'After close'}),
        throwsA(isA<ClientClosedException>()),
      );

      expect(
        () => client.query('SELECT 1'),
        throwsA(isA<ClientClosedException>()),
      );
    });

    test('Teardown drain safely reverts in_flight mutations back to pending', () async {
      // Simulate an unacknowledged in-flight mutation
      await client.storage.db.execute('''
        INSERT INTO _sync_outbox (
          mutation_id, entity_name, entity_id, op, status, created_at
        ) VALUES ('mut-inflight', 'orders', 'ord-1', 'create', 'in_flight', 1000)
      ''');

      // Close client
      await client.close(drainTimeout: const Duration(milliseconds: 50));

      // Re-open DB to inspect outbox
      final reopenStorage = await SyncStorage.open(path: '${tempDir.path}/test.db');
      final rows = await reopenStorage.db.getAll("SELECT status FROM _sync_outbox WHERE mutation_id = 'mut-inflight'");
      expect(rows.first['status'], equals('pending'));
      await reopenStorage.close();
    });
  });
}
