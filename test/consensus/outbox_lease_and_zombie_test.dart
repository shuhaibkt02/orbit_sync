import 'dart:io';
import 'package:sqlite_async/sqlite_async.dart';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import '../storage/storage_test_helpers.dart';

class _HookableTransport implements SyncTransport {
  final Future<void> Function(List<Map<String, dynamic>> mutations)?
      onPushBatch;
  final Future<TransportResponse?> Function(String url, String mutationId)?
      onPushCustom;

  _HookableTransport({this.onPushBatch, this.onPushCustom});

  @override
  Future<TransportResponse> pushBatch({
    required List<Map<String, dynamic>> mutations,
    required String idempotencyKey,
    String? chaos,
  }) async {
    if (onPushBatch != null) {
      await onPushBatch!(mutations);
    }
    return TransportResponse(statusCode: 200, body: '{"status":"ok"}');
  }

  @override
  Future<TransportResponse> pushCustom({
    required String url,
    required String method,
    required String mutationId,
    required int createdAtMs,
    Map<String, dynamic>? payload,
    String? entityId,
    Map<String, String>? headers,
  }) async {
    if (onPushCustom != null) {
      final res = await onPushCustom!(url, mutationId);
      if (res != null) return res;
    }
    return TransportResponse(statusCode: 200, body: '{"id":"$mutationId"}');
  }

  @override
  Future<TransportResponse> pushMultipart({
    required Uri uri,
    String method = 'POST',
    required String fieldName,
    required String filePath,
    String? fileName,
    String? mimeType,
    Map<String, dynamic>? extraFields,
    Map<String, String>? headers,
    Duration? timeout,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    return TransportResponse(statusCode: 200, body: '{"status":"ok"}');
  }

  @override
  Future<TransportResponse> pull({
    required int sinceCursor,
    required int limit,
    Map<String, dynamic>? scopeFilter,
    bool snapshot = false,
    String? chaos,
  }) async {
    return TransportResponse(
        statusCode: 200, body: '{"changes":[],"next_cursor":0}');
  }

  @override
  Stream<void>? get onRemoteChange => null;

  @override
  void dispose() {}
}

void main() {
  group(
      'Ticket 09: Outbox Atomic Lease Locking & 60-Second Zombie Crash Recovery',
      () {
    late Directory tempDir;
    late SyncStorage storage;

    setUp(() async {
      final res = await createTestStorage();
      tempDir = res.tempDir;
      storage = res.storage;
    });

    tearDown(() async {
      await storage.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'Test 1: Atomic candidate claiming marks rows in_flight and updates updated_at',
        () async {
      final simulatedNow = 1700000000000;
      String? inFlightStatus;
      int? inFlightUpdatedAt;

      final transport = _HookableTransport(
        onPushBatch: (mutations) async {
          final row = await storage.db.get(
            'SELECT status, updated_at FROM _sync_outbox WHERE entity_id = ?',
            [mutations.first['id']],
          );
          inFlightStatus = row['status'] as String?;
          inFlightUpdatedAt = row['updated_at'] as int?;
        },
      );

      final worker = SyncWorker(
        storage: storage,
        transport: transport,
        nowMsProvider: () => simulatedNow,
      );

      final mutId = await storage.save(
        entity: 'tasks',
        id: 'task-1',
        data: {'title': 'Atomic Lease Task'},
      );

      final rowBefore = await storage.db.get(
        'SELECT status, updated_at FROM _sync_outbox WHERE mutation_id = ?',
        [mutId],
      );
      expect(rowBefore['status'], 'pending');

      final result = await worker.pushBatch();
      expect(result.status, SyncPushStatus.success);

      // During claiming within writeTransaction, status was set to in_flight with updated_at = simulatedNow
      expect(inFlightStatus, 'in_flight');
      expect(inFlightUpdatedAt, simulatedNow);

      // After dispatch completion, the row is marked synced
      final rowAfter = await storage.db.get(
        'SELECT status FROM _sync_outbox WHERE mutation_id = ?',
        [mutId],
      );
      expect(rowAfter['status'], 'synced');
    });

    test(
        'Test 2: Safe finally release - when transport throws an unhandled exception, in_flight rows return to pending',
        () async {
      final simulatedNow = 1700000000000;
      bool shouldThrow = true;

      final transport = _HookableTransport(
        onPushBatch: (mutations) async {
          if (shouldThrow) {
            throw const SocketException('Network socket crash during push');
          }
        },
      );

      final worker = SyncWorker(
        storage: storage,
        transport: transport,
        nowMsProvider: () => simulatedNow,
      );

      final mutId = await storage.save(
        entity: 'tasks',
        id: 'task-2',
        data: {'title': 'Crash Test Task'},
      );

      // Attempt pushBatch which encounters unhandled SocketException
      await expectLater(
        worker.pushBatch(),
        throwsA(isA<SocketException>()),
      );

      // Finally block must have safely returned claimed in_flight mutations back to pending
      final rowAfterCrash = await storage.db.get(
        'SELECT status, updated_at FROM _sync_outbox WHERE mutation_id = ?',
        [mutId],
      );
      expect(rowAfterCrash['status'], 'pending');
      expect(rowAfterCrash['updated_at'], simulatedNow);

      // When network socket recovers, next pushBatch succeeds
      shouldThrow = false;
      final retryResult = await worker.pushBatch();
      expect(retryResult.status, SyncPushStatus.success);

      final rowFinal = await storage.db.get(
        'SELECT status FROM _sync_outbox WHERE mutation_id = ?',
        [mutId],
      );
      expect(rowFinal['status'], 'synced');
    });

    test(
        'Test 3: 60-second zombie recovery - rows stuck in in_flight for > 60s are reclaimed to pending, while active leases (< 60s) are left untouched',
        () async {
      int simulatedNow = 1700000000000;

      final transport = InMemorySyncTransport();
      final worker = SyncWorker(
        storage: storage,
        transport: transport,
        nowMsProvider: () => simulatedNow,
      );

      // Insert 3 mutations directly into _sync_outbox:
      // 1. Zombie (> 60s): updated_at = simulatedNow - 70000 (70s old)
      // 2. Active lease (< 60s): updated_at = simulatedNow - 15000 (15s old)
      // 3. Uninitialized zombie: updated_at = 0
      await storage.db.writeTransaction((tx) async {
        await tx.execute('''
          INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, status, created_at, updated_at)
          VALUES 
            ('mut-zombie-1', 'tasks', 't-z1', 'save', 'in_flight', ?, ?),
            ('mut-active-2', 'tasks', 't-a2', 'save', 'in_flight', ?, ?),
            ('mut-zero-3', 'tasks', 't-z3', 'save', 'in_flight', ?, 0);
        ''', [
          simulatedNow - 70000,
          simulatedNow - 70000,
          simulatedNow - 15000,
          simulatedNow - 15000,
          simulatedNow - 100000,
        ]);
      });

      // Invoke reclaimZombies()
      final reclaimedCount = await worker.reclaimZombies();
      expect(reclaimedCount, 2,
          reason:
              'Must reclaim mut-zombie-1 and mut-zero-3, but NOT mut-active-2');

      final rowZ1 = await storage.db.get(
        'SELECT status, updated_at FROM _sync_outbox WHERE mutation_id = ?',
        ['mut-zombie-1'],
      );
      expect(rowZ1['status'], 'pending');
      expect(rowZ1['updated_at'], simulatedNow);

      final rowA2 = await storage.db.get(
        'SELECT status, updated_at FROM _sync_outbox WHERE mutation_id = ?',
        ['mut-active-2'],
      );
      expect(rowA2['status'], 'in_flight');
      expect(rowA2['updated_at'], simulatedNow - 15000);

      final rowZ3 = await storage.db.get(
        'SELECT status, updated_at FROM _sync_outbox WHERE mutation_id = ?',
        ['mut-zero-3'],
      );
      expect(rowZ3['status'], 'pending');
      expect(rowZ3['updated_at'], simulatedNow);

      // Pre-sync zombie reclaim: pushBatch automatically reclaims zombies before pushing
      // Advance simulated clock by 50 seconds so mut-active-2 is now 65s old (> 60s)
      simulatedNow += 50000;
      final pushRes = await worker.pushBatch();
      expect(pushRes.status, SyncPushStatus.success);

      // mut-active-2 must have been reclaimed to pending and pushed to synced
      final rowA2After = await storage.db.get(
        'SELECT status FROM _sync_outbox WHERE mutation_id = ?',
        ['mut-active-2'],
      );
      expect(rowA2After['status'], 'synced');
    });

    test(
        'Test 4: Startup crash recovery in SqliteSchema.initSystemSchema resets stranded in_flight mutations older than 60s',
        () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final temp =
          Directory.systemTemp.createTempSync('schema_startup_recovery_');
      try {
        final db = SqliteDatabase(path: '${temp.path}/schema_rec.db');
        await SqliteSchema.initSystemSchema(db);

        // Insert stranded mutations from crashed app session
        await db.execute('''
          INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, status, created_at, updated_at)
          VALUES 
            ('startup-zombie', 'tasks', 't-sz', 'save', 'in_flight', ?, ?),
            ('startup-active', 'tasks', 't-sa', 'save', 'in_flight', ?, ?);
        ''', [
          now - 75000,
          now - 75000,
          now - 10000,
          now - 10000,
        ]);

        // Simulate app restart by running initSystemSchema again
        await SqliteSchema.initSystemSchema(db);

        final zombieRow = await db.get(
            "SELECT status FROM _sync_outbox WHERE mutation_id = 'startup-zombie'");
        expect(zombieRow['status'], 'pending',
            reason: 'Crash recovery on startup must reclaim > 60s zombie');

        final activeRow = await db.get(
            "SELECT status FROM _sync_outbox WHERE mutation_id = 'startup-active'");
        expect(activeRow['status'], 'in_flight',
            reason: 'Active lease (< 60s) must remain intact');

        await db.close();
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    });

    test(
        'Test 5: Concurrent sync runs - simultaneous pushBatch triggers do not double-claim or double-push',
        () async {
      final pushedMutationIds = <String>[];
      final transport = _HookableTransport(
        onPushBatch: (mutations) async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          for (final m in mutations) {
            pushedMutationIds.add(m['id'] as String);
          }
        },
      );

      final worker = SyncWorker(
        storage: storage,
        transport: transport,
      );

      // Seed 5 pending mutations
      for (int i = 1; i <= 5; i++) {
        await storage.save(
          entity: 'tasks',
          id: 'concurrent-task-$i',
          data: {'title': 'Concurrent Task $i'},
        );
      }

      // Trigger 3 simultaneous pushBatch calls concurrently
      final futures = [
        worker.pushBatch(batchSize: 5),
        worker.pushBatch(batchSize: 5),
        worker.pushBatch(batchSize: 5),
      ];

      final results = await Future.wait(futures);

      final totalApplied =
          results.fold<int>(0, (sum, res) => sum + res.applied);
      expect(totalApplied, 5,
          reason:
              'Exactly 5 mutations should have been claimed and applied in total');

      // Verify no double-push or duplication
      expect(pushedMutationIds.length, 5);
      expect(pushedMutationIds.toSet().length, 5,
          reason: 'No mutation should be pushed more than once');

      // All 5 mutations should be synced
      final syncedRows = await storage.db.getAll(
        "SELECT mutation_id FROM _sync_outbox WHERE status = 'synced'",
      );
      expect(syncedRows.length, 5);
    });

    test(
        'Test 6: Safe finally release for custom REST endpoints - undispatched batch items return to pending',
        () async {
      final simulatedNow = 1700000000000;
      final transport = _HookableTransport(
        onPushCustom: (url, mutationId) async {
          // First custom mutation fails with network error
          return TransportResponse(statusCode: 0, error: 'Network socket drop');
        },
      );

      final worker = SyncWorker(
        storage: storage,
        transport: transport,
        nowMsProvider: () => simulatedNow,
      );

      final mutId1 = await storage.save(
        entity: 'tasks',
        id: 'custom-task-1',
        data: {'title': 'Custom Endpoint Task 1'},
        endpointUrl: 'https://api.example.com/tasks',
      );
      final mutId2 = await storage.save(
        entity: 'tasks',
        id: 'custom-task-2',
        data: {'title': 'Custom Endpoint Task 2'},
        endpointUrl: 'https://api.example.com/tasks',
      );

      final res = await worker.pushBatch(batchSize: 2);
      expect(res.status, SyncPushStatus.networkError);

      // mutId1 failed and was recorded with retry backoff
      final row1 = await storage.db.get(
        'SELECT status, retry_count FROM _sync_outbox WHERE mutation_id = ?',
        [mutId1],
      );
      expect(row1['status'], 'pending');
      expect(row1['retry_count'], 1);

      // mutId2 was undispatched and safely released back to pending by finally block
      final row2 = await storage.db.get(
        'SELECT status, updated_at, retry_count FROM _sync_outbox WHERE mutation_id = ?',
        [mutId2],
      );
      expect(row2['status'], 'pending');
      expect(row2['updated_at'], simulatedNow);
      expect(row2['retry_count'], 0,
          reason: 'Undispatched mutation must not consume retry budget');
    });
  });
}
