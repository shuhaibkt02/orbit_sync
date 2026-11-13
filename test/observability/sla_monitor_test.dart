import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

void main() {
  group('Layer 6 Observability: SLA Monitor & Heartbeat Evaluation', () {
    late Directory tempDir;
    late SyncStorage storage;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('sla_monitor_test_');
      storage = await SyncStorage.open(path: '${tempDir.path}/app.db');
      await storage.registerEntityTable('orders', {'amount': 'REAL'});
    });

    tearDown(() async {
      await storage.close();
      tempDir.deleteSync(recursive: true);
    });

    test('emits SlaWarningEvent at 80% and SlaBreachedEvent at 100% of SLA deadline', () async {
      int simulatedNow = 1000000;
      final monitor = SlaMonitor(
        storage: storage,
        nowMsProvider: () => simulatedNow,
      );

      // Save order with SLA of 100 seconds (100,000ms)
      final mutId = await storage.save(
        entity: 'orders',
        id: 'ord-100',
        data: {'amount': 250.0},
        sla: const Duration(seconds: 100),
      );

      // Backdate created_at to t=0
      await storage.db.execute(
        'UPDATE _sync_outbox SET created_at = ? WHERE mutation_id = ?',
        [simulatedNow, mutId],
      );

      // 1. Advance to 50% SLA (50s) -> No alert
      simulatedNow += 50000;
      var events = await monitor.evaluate();
      expect(events, isEmpty);

      // 2. Advance to 80% SLA (80s) -> Emits SlaWarningEvent
      simulatedNow += 30000;
      events = await monitor.evaluate();
      expect(events.length, equals(1));
      expect(events.first, isA<SlaWarningEvent>());
      final warn = events.first as SlaWarningEvent;
      expect(warn.mutationId, equals(mutId));
      expect(warn.entity, equals('orders'));
      expect(warn.entityId, equals('ord-100'));

      // 3. Repeat evaluate at 85% -> Deduplicated! (No duplicate warning)
      simulatedNow += 5000;
      events = await monitor.evaluate();
      expect(events, isEmpty);

      // 4. Advance to 100% SLA (100s) -> Emits SlaBreachedEvent
      simulatedNow += 15000;
      events = await monitor.evaluate();
      expect(events.length, equals(1));
      expect(events.first, isA<SlaBreachedEvent>());
      final breach = events.first as SlaBreachedEvent;
      expect(breach.mutationId, equals(mutId));

      // 5. Repeat evaluate at 110% -> Deduplicated!
      simulatedNow += 10000;
      events = await monitor.evaluate();
      expect(events, isEmpty);

      await monitor.dispose();
    });

    test('evicts resolved records from tracking cache upon sync completion', () async {
      int simulatedNow = 1000000;
      final monitor = SlaMonitor(
        storage: storage,
        nowMsProvider: () => simulatedNow,
      );

      final mutId = await storage.save(
        entity: 'orders',
        id: 'ord-200',
        data: {'amount': 150.0},
        sla: const Duration(seconds: 10),
      );
      await storage.db.execute(
        'UPDATE _sync_outbox SET created_at = ? WHERE mutation_id = ?',
        [simulatedNow, mutId],
      );

      // Breach SLA
      simulatedNow += 15000;
      var events = await monitor.evaluate();
      expect(events.length, equals(1));

      // Now mutation is synced
      await storage.db.execute(
        "UPDATE _sync_outbox SET status = 'synced' WHERE mutation_id = ?",
        [mutId],
      );

      // Evaluate again -> Active IDs no longer include mutId, internal sets evict it
      events = await monitor.evaluate();
      expect(events, isEmpty);

      await monitor.dispose();
    });
  });
}
