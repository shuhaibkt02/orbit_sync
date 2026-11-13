import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import '../storage/storage_test_helpers.dart';

class _HookableTransport implements SyncTransport {
  final Future<void> Function(List<Map<String, dynamic>> mutations)?
      onPushBatch;

  _HookableTransport({this.onPushBatch});

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
      'Ticket 10: Hybrid EDF Queue Claiming (Priority + SLA Emergency Escalation)',
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

    Future<String> insertOutboxMutation({
      required String id,
      int priority = 0,
      int slaSeconds = 86400,
      required int createdAt,
      int? dispatchAfter,
      int? nextRetryAt,
      String status = 'pending',
    }) async {
      final mutationId = 'mut-$id';
      await storage.db.execute('''
        INSERT INTO _sync_outbox (
          mutation_id, entity_name, entity_id, op, payload_json,
          status, priority, sla_seconds, created_at, updated_at,
          dispatch_after, next_retry_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''', [
        mutationId,
        'tasks',
        id,
        'upsert',
        '{"id":"$id","title":"Task $id"}',
        status,
        priority,
        slaSeconds,
        createdAt,
        createdAt,
        dispatchAfter,
        nextRetryAt,
      ]);
      return mutationId;
    }

    test(
        'Test SLA Emergency Escalation: Low-priority mutation (priority: 0) expiring in 5 mins jumps ahead of high-priority mutation (priority: 3) expiring in 24h',
        () async {
      final simulatedNow = 1700000000000;
      final claimedIds = <String>[];

      final transport = _HookableTransport(
        onPushBatch: (mutations) async {
          claimedIds.addAll(mutations.map((m) => m['id'] as String));
        },
      );

      final worker = SyncWorker(
        storage: storage,
        transport: transport,
        nowMsProvider: () => simulatedNow,
      );

      // Mut A: High business priority (tier 3), safe SLA (24 hours = 86,400s)
      // SLA deadline = simulatedNow + 86,400,000; remaining = 86,400,000ms (> 15 mins -> escalation = 0)
      await insertOutboxMutation(
        id: 'task-high-prio-safe-sla',
        priority: 3,
        slaSeconds: 86400,
        createdAt: simulatedNow,
      );

      // Mut B: Low business priority (tier 0), urgent SLA (5 minutes = 300s)
      // SLA deadline = simulatedNow + 300,000; remaining = 300,000ms (< 900,000ms -> escalation = 1)
      await insertOutboxMutation(
        id: 'task-low-prio-urgent-sla',
        priority: 0,
        slaSeconds: 300,
        createdAt: simulatedNow,
      );

      final result = await worker.pushBatch(batchSize: 10);
      expect(result.status, equals(SyncPushStatus.success));
      expect(result.applied, equals(2));

      // Low priority urgent SLA must jump ahead of high priority safe SLA!
      expect(
          claimedIds,
          equals([
            'task-low-prio-urgent-sla',
            'task-high-prio-safe-sla',
          ]));
    });

    test(
        'Test Business Priority Tier: Non-emergency mutations order by priority DESC (tier 3 before tier 2 before tier 1 before tier 0)',
        () async {
      final simulatedNow = 1700000000000;
      final claimedIds = <String>[];

      final transport = _HookableTransport(
        onPushBatch: (mutations) async {
          claimedIds.addAll(mutations.map((m) => m['id'] as String));
        },
      );

      final worker = SyncWorker(
        storage: storage,
        transport: transport,
        nowMsProvider: () => simulatedNow,
      );

      // Insert mutations with scrambled priority tiers, all with safe SLA (24h)
      await insertOutboxMutation(
        id: 'task-tier-0',
        priority: 0,
        slaSeconds: 86400,
        createdAt: simulatedNow,
      );
      await insertOutboxMutation(
        id: 'task-tier-2',
        priority: 2,
        slaSeconds: 86400,
        createdAt: simulatedNow,
      );
      await insertOutboxMutation(
        id: 'task-tier-1',
        priority: 1,
        slaSeconds: 86400,
        createdAt: simulatedNow,
      );
      await insertOutboxMutation(
        id: 'task-tier-3',
        priority: 3,
        slaSeconds: 86400,
        createdAt: simulatedNow,
      );

      final result = await worker.pushBatch(batchSize: 10);
      expect(result.status, equals(SyncPushStatus.success));
      expect(result.applied, equals(4));

      // Must strictly order by business priority tier: 3 > 2 > 1 > 0
      expect(
          claimedIds,
          equals([
            'task-tier-3',
            'task-tier-2',
            'task-tier-1',
            'task-tier-0',
          ]));
    });

    test(
        'Test Earliest Deadline First within same tier: Two tier-2 mutations order by tighter SLA deadline first',
        () async {
      final simulatedNow = 1700000000000;
      final claimedIds = <String>[];

      final transport = _HookableTransport(
        onPushBatch: (mutations) async {
          claimedIds.addAll(mutations.map((m) => m['id'] as String));
        },
      );

      final worker = SyncWorker(
        storage: storage,
        transport: transport,
        nowMsProvider: () => simulatedNow,
      );

      // Both tier 2, both safe (>15m remaining), but task-tier-2-tight has 30m deadline vs 2h deadline
      await insertOutboxMutation(
        id: 'task-tier-2-loose',
        priority: 2,
        slaSeconds: 7200, // 2 hours remaining
        createdAt: simulatedNow,
      );
      await insertOutboxMutation(
        id: 'task-tier-2-tight',
        priority: 2,
        slaSeconds: 1800, // 30 mins remaining
        createdAt: simulatedNow,
      );

      final result = await worker.pushBatch(batchSize: 10);
      expect(result.status, equals(SyncPushStatus.success));
      expect(result.applied, equals(2));

      // Within same priority 2, tighter SLA deadline dispatches first
      expect(
          claimedIds,
          equals([
            'task-tier-2-tight',
            'task-tier-2-loose',
          ]));
    });

    test(
        'Test Sequence Fallback: Identical priority and SLA order by sequence_id ASC',
        () async {
      final simulatedNow = 1700000000000;
      final claimedIds = <String>[];

      final transport = _HookableTransport(
        onPushBatch: (mutations) async {
          claimedIds.addAll(mutations.map((m) => m['id'] as String));
        },
      );

      final worker = SyncWorker(
        storage: storage,
        transport: transport,
        nowMsProvider: () => simulatedNow,
      );

      // 3 items with identical priority (1), identical SLA (3600), identical created_at
      await insertOutboxMutation(
        id: 'task-seq-first',
        priority: 1,
        slaSeconds: 3600,
        createdAt: simulatedNow,
      );
      await insertOutboxMutation(
        id: 'task-seq-second',
        priority: 1,
        slaSeconds: 3600,
        createdAt: simulatedNow,
      );
      await insertOutboxMutation(
        id: 'task-seq-third',
        priority: 1,
        slaSeconds: 3600,
        createdAt: simulatedNow,
      );

      final result = await worker.pushBatch(batchSize: 10);
      expect(result.status, equals(SyncPushStatus.success));
      expect(result.applied, equals(3));

      // Strictly follows FIFO sequence_id ASC fallback
      expect(
          claimedIds,
          equals([
            'task-seq-first',
            'task-seq-second',
            'task-seq-third',
          ]));
    });

    test(
        'Test Cooling Window Gating: Items where dispatch_after > now are strictly excluded from claiming',
        () async {
      final simulatedNow = 1700000000000;
      final claimedIds = <String>[];

      final transport = _HookableTransport(
        onPushBatch: (mutations) async {
          claimedIds.addAll(mutations.map((m) => m['id'] as String));
        },
      );

      final worker = SyncWorker(
        storage: storage,
        transport: transport,
        nowMsProvider: () => simulatedNow,
      );

      // Item A: Priority 0, eligible (no cooling window)
      await insertOutboxMutation(
        id: 'task-eligible-low-prio',
        priority: 0,
        slaSeconds: 86400,
        createdAt: simulatedNow,
        dispatchAfter: null,
      );

      // Item B: Priority 3, but cooling off (dispatch_after is 30s in future)
      await insertOutboxMutation(
        id: 'task-cooling-high-prio',
        priority: 3,
        slaSeconds: 86400,
        createdAt: simulatedNow,
        dispatchAfter: simulatedNow + 30000,
      );

      final result = await worker.pushBatch(batchSize: 10);
      expect(result.status, equals(SyncPushStatus.success));
      expect(result.applied, equals(1));

      // Only eligible item claimed; cooling item excluded
      expect(claimedIds, equals(['task-eligible-low-prio']));

      // Verify cooling item remains pending in outbox
      final coolingRow = await storage.db.get(
        'SELECT status FROM _sync_outbox WHERE entity_id = ?',
        ['task-cooling-high-prio'],
      );
      expect(coolingRow['status'], equals('pending'));
    });

    test(
        'Test Backoff Retry Gating: Items where next_retry_at > now are strictly excluded from claiming',
        () async {
      final simulatedNow = 1700000000000;
      final claimedIds = <String>[];

      final transport = _HookableTransport(
        onPushBatch: (mutations) async {
          claimedIds.addAll(mutations.map((m) => m['id'] as String));
        },
      );

      final worker = SyncWorker(
        storage: storage,
        transport: transport,
        nowMsProvider: () => simulatedNow,
      );

      // Item A: Ready to push
      await insertOutboxMutation(
        id: 'task-ready',
        priority: 1,
        slaSeconds: 86400,
        createdAt: simulatedNow,
        nextRetryAt: null,
      );

      // Item B: Backed off (next_retry_at is 15s in the future)
      await insertOutboxMutation(
        id: 'task-backed-off',
        priority: 3,
        slaSeconds: 300, // Urgent SLA, but backed off
        createdAt: simulatedNow,
        nextRetryAt: simulatedNow + 15000,
      );

      final result = await worker.pushBatch(batchSize: 10);
      expect(result.status, equals(SyncPushStatus.success));
      expect(result.applied, equals(1));

      // Only ready item claimed; backed off item excluded
      expect(claimedIds, equals(['task-ready']));

      final backedOffRow = await storage.db.get(
        'SELECT status FROM _sync_outbox WHERE entity_id = ?',
        ['task-backed-off'],
      );
      expect(backedOffRow['status'], equals('pending'));
    });

    test(
        'Test Force Claiming: force: true bypasses cooling window and backoff retry while preserving Hybrid EDF ordering',
        () async {
      final simulatedNow = 1700000000000;
      final claimedIds = <String>[];

      final transport = _HookableTransport(
        onPushBatch: (mutations) async {
          claimedIds.addAll(mutations.map((m) => m['id'] as String));
        },
      );

      final worker = SyncWorker(
        storage: storage,
        transport: transport,
        nowMsProvider: () => simulatedNow,
      );

      // Item 1: High priority (3), backed off into future
      await insertOutboxMutation(
        id: 'task-forced-p3-backed-off',
        priority: 3,
        slaSeconds: 86400,
        createdAt: simulatedNow,
        nextRetryAt: simulatedNow + 60000,
      );

      // Item 2: Low priority (0), urgent SLA (< 15 mins), in cooling window
      await insertOutboxMutation(
        id: 'task-forced-urgent-cooling',
        priority: 0,
        slaSeconds: 300, // 5 mins -> emergency escalation
        createdAt: simulatedNow,
        dispatchAfter: simulatedNow + 30000,
      );

      final result = await worker.pushBatch(batchSize: 10, force: true);
      expect(result.status, equals(SyncPushStatus.success));
      expect(result.applied, equals(2));

      // With force: true, both are claimed; urgent SLA still escalates over tier 3!
      expect(
          claimedIds,
          equals([
            'task-forced-urgent-cooling',
            'task-forced-p3-backed-off',
          ]));
    });
  });
}
