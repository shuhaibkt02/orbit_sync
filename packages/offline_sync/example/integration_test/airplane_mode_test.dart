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
      onLog: (msg) => debugPrint('[SDK LOG] $msg'),
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
    debugPrint('==> [E2E Test] Current database phase: $phase');

    if (phase == null) {
      debugPrint('==> [E2E Test] Entering Phase 1: Queuing $mutationCount offline mutations');
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

      final initialPending = await client.query(
        "SELECT COUNT(*) AS cnt FROM _sync_outbox WHERE status = 'pending'",
      );
      final initialCount = (initialPending.first['cnt'] as num?)?.toInt() ?? 0;
      debugPrint('==> [E2E Test] Phase 1 verified on-disk: $initialCount mutations queued in outbox');
      expect(initialCount, equals(mutationCount), reason: 'Phase 1 must queue all mutations in pending state');

      debugPrint('==> [E2E Test] Phase 1 complete. Outbox ready. Process awaiting kill.');
      // Return immediately without closing client or DB
      return;
    }

    if (phase == 'ready_for_kill') {
      debugPrint('==> [E2E Test] Entering Phase 2: Verifying uncheckpointed outbox durability & syncing');
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

      // Poll sync with retry to absorb asynchronous OS radio power-up latency
      int remainingCount = mutationCount;
      for (var attempt = 1; attempt <= 10; attempt++) {
        await client.sync(force: true);
        final remainingRows = await client.query(
          "SELECT * FROM _sync_outbox WHERE status != 'synced'",
        );
        remainingCount = remainingRows.length;
        if (remainingCount == 0) {
          debugPrint('==> [E2E Test] Outbox completely drained in attempt $attempt');
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }

      if (remainingCount > 0) {
        final failedRows = await client.query(
          "SELECT * FROM _sync_outbox WHERE status != 'synced'",
        );
        for (final row in failedRows.take(3)) {
          debugPrint('==> [E2E Test] Failed row: id=${row['mutation_id']}, status=${row['status']}, retry=${row['retry_count']}, err=${row['error_details_json']}');
        }
      }

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
