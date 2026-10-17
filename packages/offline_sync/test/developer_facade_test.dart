import 'dart:io';
import 'package:test/test.dart';
import 'package:offline_sync/offline_sync.dart';

void main() {
  group('Developer Facade (Zero-SQL Outbox & Dashboard APIs)', () {
    late String dbPath;
    late OfflineSyncClient client;

    setUp(() async {
      dbPath = '${Directory.systemTemp.path}/facade_test_${DateTime.now().microsecondsSinceEpoch}.db';
      client = await OfflineSyncClient.initialize(
        databasePath: dbPath,
      );
      await client.registerTable('orders', {
        'amount': 'REAL',
        'customer': 'TEXT',
      });
    });

    tearDown(() async {
      await client.close();
      final file = File(dbPath);
      if (await file.exists()) await file.delete();
      final wal = File('$dbPath-wal');
      if (await wal.exists()) await wal.delete();
      final shm = File('$dbPath-shm');
      if (await shm.exists()) await shm.delete();
    });

    test('getSummary and watchSummary provide instant zero-SQL dashboard metrics', () async {
      // Initially clean
      var summary = await client.getSummary();
      expect(summary.total, equals(0));
      expect(summary.isClean, isTrue);
      expect(summary.hasFailures, isFalse);

      // Save 3 orders
      final m1 = await client.save(entity: 'orders', id: 'ord-1', data: {'amount': 100.0, 'customer': 'Alice'});
      final m2 = await client.save(entity: 'orders', id: 'ord-2', data: {'amount': 250.0, 'customer': 'Bob'});
      await client.save(entity: 'orders', id: 'ord-3', data: {'amount': 50.0, 'customer': 'Charlie'});

      summary = await client.getSummary();
      expect(summary.total, equals(3));
      expect(summary.pending, equals(3));
      expect(summary.synced, equals(0));
      expect(summary.failed, equals(0));
      expect(summary.isClean, isFalse);
      expect(summary.oldestPendingAt, isNotNull);

      // Mark one synced, fail one
      await client.markSynced(m1);
      await client.storage.db.execute(
        "UPDATE _sync_outbox SET status = 'failed', error_details_json = '{\"error\":\"server down\"}' WHERE mutation_id = ?",
        [m2],
      );

      summary = await client.getSummary();
      expect(summary.total, equals(3));
      expect(summary.pending, equals(1)); // ord-3
      expect(summary.synced, equals(1));  // ord-1
      expect(summary.failed, equals(1));  // ord-2
      expect(summary.hasFailures, isTrue);
    });

    test('getRecords and watchRecords return typed OutboxRecord without raw SQL', () async {
      await client.save(entity: 'orders', id: 'ord-10', data: {'amount': 300.0});
      await client.save(entity: 'orders', id: 'ord-20', data: {'amount': 450.0});

      final allRecords = await client.getRecords();
      expect(allRecords.length, equals(2));
      expect(allRecords.first.entity, equals('orders'));
      expect(allRecords.first.status, equals('pending'));
      expect(allRecords.first.payload, isNotNull);
      expect(allRecords.first.payload!['amount'], isNotNull);

      final pendingOnly = await client.getRecords(status: 'pending');
      expect(pendingOnly.length, equals(2));
    });

    test('getStaleRecords identifies mutations breaching business SLA interval', () async {
      // Save an order with a created_at simulated 2 hours ago
      final twoHoursAgo = DateTime.now().subtract(const Duration(hours: 2)).millisecondsSinceEpoch;
      final mutId = await client.save(entity: 'orders', id: 'ord-stale', data: {'amount': 99.0});
      await client.storage.db.execute(
        "UPDATE _sync_outbox SET created_at = ? WHERE mutation_id = ?",
        [twoHoursAgo, mutId],
      );

      // Save a fresh order (created right now)
      await client.save(entity: 'orders', id: 'ord-fresh', data: {'amount': 10.0});

      // Developer queries: "Give me records older than 60 minutes"
      final stale60Min = await client.getStaleRecords(maxAge: const Duration(minutes: 60));
      expect(stale60Min.length, equals(1));
      expect(stale60Min.first.recordId, equals('ord-stale'));
      expect(stale60Min.first.isStale(const Duration(minutes: 60)), isTrue);

      // Developer queries: "Give me records older than 3 hours"
      final stale3Hours = await client.getStaleRecords(maxAge: const Duration(hours: 3));
      expect(stale3Hours, isEmpty);
    });

    test('retryMutation, retryAllFailed, and cancelMutation provide zero-SQL manual intervention', () async {
      final mut1 = await client.save(entity: 'orders', id: 'ord-f1', data: {'amount': 1.0});
      final mut2 = await client.save(entity: 'orders', id: 'ord-f2', data: {'amount': 2.0});

      // Quarantine both into dlq
      await client.storage.db.execute(
        "UPDATE _sync_outbox SET status = 'dlq', retry_count = 5 WHERE mutation_id IN (?, ?)",
        [mut1, mut2],
      );

      var summary = await client.getSummary();
      expect(summary.failed, equals(2));
      expect(summary.pending, equals(0));

      // Retry single mutation
      await client.retryMutation(mut1);
      summary = await client.getSummary();
      expect(summary.pending, equals(1));
      expect(summary.failed, equals(1));

      // Retry all failed
      await client.retryAllFailed();
      summary = await client.getSummary();
      expect(summary.pending, equals(2));
      expect(summary.failed, equals(0));

      // Cancel a mutation
      await client.cancelMutation(mut1);
      summary = await client.getSummary();
      expect(summary.total, equals(1));
      expect(summary.pending, equals(1));
    });
  });
}
