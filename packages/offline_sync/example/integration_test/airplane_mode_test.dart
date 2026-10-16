import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:offline_sync/offline_sync.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const entity = 'orders';
  const mutationCount = 50;
  const serverUrl = String.fromEnvironment(
    'SYNC_TEST_SERVER',
    defaultValue: 'http://10.0.2.2:8080',
  );

  testWidgets('E2E: $mutationCount mutations survive airplane mode and OS kill', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Offline Sync E2E Running'))),
    );

    final supportDir = await getApplicationSupportDirectory();
    final dbPath = p.join(supportDir.path, 'e2e_offline.db');

    final client = await OfflineSyncClient.initialize(
      databasePath: dbPath,
      serverUrl: serverUrl,
    );

    await client.registerEntity(
      entity,
      url: '$serverUrl/orders',
      columnTypes: {
        'item': 'TEXT',
        'price': 'INTEGER',
      },
    );

    // Track phase in _sync_metadata to survive app kills, restarts, and re-invocations
    final phaseRows = await client.query(
      "SELECT value FROM _sync_metadata WHERE key = 'e2e_phase'",
    );
    final phase = phaseRows.isEmpty ? null : phaseRows.first['value'] as String?;

    if (phase == null) {
      // ---- PHASE 1: Queue mutations offline ----
      // DO NOT call client.close()! We intentionally leave the SQLite connection open
      // so 'adb shell am force-stop' kills a live, uncheckpointed DB process.
      for (var i = 0; i < mutationCount; i++) {
        await client.store(
          entity,
          {'item': 'SKU-$i', 'price': i * 10},
          id: 'order-$i',
        );
      }

      await client.storage.db.execute(
        "INSERT OR REPLACE INTO _sync_metadata (key, value) VALUES ('e2e_phase', 'ready_for_kill')",
      );

      // Return immediately without closing client or DB
      return;
    }

    if (phase == 'ready_for_kill') {
      // ---- PHASE 2: Verify outbox durability, sync, verify drained ----
      final pendingRows = await client.query(
        "SELECT COUNT(*) AS cnt FROM _sync_outbox WHERE status = 'pending'",
      );
      final pendingCount = (pendingRows.first['cnt'] as num?)?.toInt() ?? 0;
      expect(
        pendingCount,
        equals(mutationCount),
        reason: 'All mutations must survive OS process kill in pending state',
      );

      // Verify next_retry_at column is queried cleanly on-device
      final backoffRows = await client.query(
        "SELECT next_retry_at FROM _sync_outbox WHERE status = 'pending' LIMIT 1",
      );
      expect(backoffRows, isNotEmpty);

      await client.sync(force: true);

      final remainingRows = await client.query(
        "SELECT COUNT(*) AS cnt FROM _sync_outbox WHERE status != 'synced'",
      );
      final remainingCount = (remainingRows.first['cnt'] as num?)?.toInt() ?? -1;
      expect(
        remainingCount,
        equals(0),
        reason: 'All mutations must reach synced state upon reconnection',
      );

      // Clean up phase marker for next clean test run
      await client.storage.db.execute(
        "DELETE FROM _sync_metadata WHERE key = 'e2e_phase'",
      );

      await client.close();
    }
  });
}
