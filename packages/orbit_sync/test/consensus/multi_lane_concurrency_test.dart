import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'package:orbit_sync/src/consensus/services/batch_push_orchestrator.dart';
import 'package:orbit_sync/src/consensus/services/custom_rest_pusher.dart';

class _CustomTestTransport implements SyncTransport {
  final Future<TransportResponse> Function({
    required String url,
    required String method,
    required String mutationId,
    required int createdAtMs,
    Map<String, dynamic>? payload,
    String? entityId,
    Map<String, String>? headers,
  }) onPushCustom;

  _CustomTestTransport({required this.onPushCustom});

  @override
  Future<TransportResponse> pushCustom({
    required String url,
    required String method,
    required String mutationId,
    required int createdAtMs,
    Map<String, dynamic>? payload,
    String? entityId,
    Map<String, String>? headers,
  }) {
    return onPushCustom(
      url: url,
      method: method,
      mutationId: mutationId,
      createdAtMs: createdAtMs,
      payload: payload,
      entityId: entityId,
      headers: headers,
    );
  }

  @override
  Future<TransportResponse> pushBatch({
    required List<Map<String, dynamic>> mutations,
    required String idempotencyKey,
    String? chaos,
  }) async {
    return const TransportResponse(statusCode: 200, body: '{"status":"ok"}');
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
    return const TransportResponse(statusCode: 200, body: '{"status":"ok"}');
  }

  @override
  Future<TransportResponse> pull({
    required int sinceCursor,
    required int limit,
    Map<String, dynamic>? scopeFilter,
    bool snapshot = false,
    String? chaos,
  }) async {
    return const TransportResponse(statusCode: 200, body: '{"changes":[],"next_cursor":0}');
  }

  @override
  Stream<void>? get onRemoteChange => null;

  @override
  void dispose() {}
}

void main() {
  late Directory tempDir;
  late SyncStorage storage;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('multi_lane_concurrency_test_');
    storage = await SyncStorage.open(path: '${tempDir.path}/test.db');
  });

  tearDown(() async {
    await storage.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('Ticket 11: Multi-Lane Dispatch Concurrency (Intra-Entity FIFO & Cross-Entity Parallelism)', () {
    test('Test Intra-Entity FIFO: Multiple mutations for orders dispatch strictly sequentially', () async {
      final dispatchLog = <Map<String, dynamic>>[];

      final transport = _CustomTestTransport(
        onPushCustom: ({
          required String url,
          required String method,
          required String mutationId,
          required int createdAtMs,
          Map<String, dynamic>? payload,
          String? entityId,
          Map<String, String>? headers,
        }) async {
          final start = DateTime.now().millisecondsSinceEpoch;
          await Future.delayed(const Duration(milliseconds: 30));
          final end = DateTime.now().millisecondsSinceEpoch;

          dispatchLog.add({
            'mutationId': mutationId,
            'start': start,
            'end': end,
          });

          return const TransportResponse(statusCode: 200, body: '{"success":true}');
        },
      );

      final orchestrator = BatchPushOrchestrator(
        storage: storage,
        transport: transport,
        profile: SyncProfile.enterprise,
        backoffPolicy: BackoffPolicy(base: const Duration(milliseconds: 500)),
        maxConcurrentLanes: 4,
      );

      final now = DateTime.now().millisecondsSinceEpoch;
      final db = storage.db;

      // Seed 3 mutations for 'orders' with increasing sequence_id
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, endpoint_url, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)",
        ['ord-mut-1', 'orders', 'ord-1', 'create', 'https://api.example.com/orders', jsonEncode({'total': 100}), now, 10],
      );
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, endpoint_url, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)",
        ['ord-mut-2', 'orders', 'ord-2', 'create', 'https://api.example.com/orders', jsonEncode({'total': 200}), now, 20],
      );
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, endpoint_url, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)",
        ['ord-mut-3', 'orders', 'ord-3', 'create', 'https://api.example.com/orders', jsonEncode({'total': 300}), now, 30],
      );

      final result = await orchestrator.pushBatch(batchSize: 10);
      expect(result.status, equals(SyncPushStatus.success));
      expect(result.applied, equals(3));

      // Verify dispatch order: ord-mut-1, ord-mut-2, ord-mut-3
      expect(dispatchLog.length, equals(3));
      expect(dispatchLog[0]['mutationId'], equals('ord-mut-1'));
      expect(dispatchLog[1]['mutationId'], equals('ord-mut-2'));
      expect(dispatchLog[2]['mutationId'], equals('ord-mut-3'));

      // Verify strict sequential execution: each request started only after previous request finished
      expect(dispatchLog[1]['start'] as int, greaterThanOrEqualTo(dispatchLog[0]['end'] as int));
      expect(dispatchLog[2]['start'] as int, greaterThanOrEqualTo(dispatchLog[1]['end'] as int));

      // Verify all 3 mutations are marked synced in SQLite
      final rows = await db.getAll("SELECT mutation_id, status FROM _sync_outbox ORDER BY sequence_id ASC");
      expect(rows.length, equals(3));
      for (final r in rows) {
        expect(r['status'], equals('synced'));
      }
    });

    test('Test Cross-Entity Parallelism: Mutations for orders and payments dispatch concurrently in overlapping windows', () async {
      final dispatchLog = <Map<String, dynamic>>[];

      final transport = _CustomTestTransport(
        onPushCustom: ({
          required String url,
          required String method,
          required String mutationId,
          required int createdAtMs,
          Map<String, dynamic>? payload,
          String? entityId,
          Map<String, String>? headers,
        }) async {
          final start = DateTime.now().millisecondsSinceEpoch;
          // 60ms delay per request
          await Future.delayed(const Duration(milliseconds: 60));
          final end = DateTime.now().millisecondsSinceEpoch;

          dispatchLog.add({
            'mutationId': mutationId,
            'start': start,
            'end': end,
          });

          return const TransportResponse(statusCode: 200, body: '{"success":true}');
        },
      );

      final orchestrator = BatchPushOrchestrator(
        storage: storage,
        transport: transport,
        profile: SyncProfile.enterprise,
        backoffPolicy: BackoffPolicy(base: const Duration(milliseconds: 500)),
        maxConcurrentLanes: 4,
      );

      final now = DateTime.now().millisecondsSinceEpoch;
      final db = storage.db;

      // Seed 1 order mutation and 1 payment mutation
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, endpoint_url, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)",
        ['ord-mut-1', 'orders', 'ord-1', 'create', 'https://api.example.com/orders', jsonEncode({'total': 150}), now, 1],
      );
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, endpoint_url, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)",
        ['pay-mut-1', 'payments', 'pay-1', 'create', 'https://api.example.com/payments', jsonEncode({'amount': 150}), now, 2],
      );

      final totalStart = DateTime.now().millisecondsSinceEpoch;
      final result = await orchestrator.pushBatch(batchSize: 10);
      final totalElapsed = DateTime.now().millisecondsSinceEpoch - totalStart;

      expect(result.status, equals(SyncPushStatus.success));
      expect(result.applied, equals(2));

      expect(dispatchLog.length, equals(2));
      final ordEntry = dispatchLog.firstWhere((e) => e['mutationId'] == 'ord-mut-1');
      final payEntry = dispatchLog.firstWhere((e) => e['mutationId'] == 'pay-mut-1');

      // Verify overlapping windows (concurrency):
      // Pay started before Order ended, AND Order started before Pay ended
      final ordStart = ordEntry['start'] as int;
      final ordEnd = ordEntry['end'] as int;
      final payStart = payEntry['start'] as int;
      final payEnd = payEntry['end'] as int;

      final overlaps = (payStart < ordEnd) && (ordStart < payEnd);
      expect(overlaps, isTrue, reason: 'Lanes must execute concurrently with overlapping windows');

      // Total elapsed should be well below 110ms (if serial, it would be >= 120ms)
      expect(totalElapsed, lessThan(115), reason: 'Parallel execution must take less time than serial sum of delays');

      // Verify both synced
      final rows = await db.getAll("SELECT mutation_id, status FROM _sync_outbox");
      expect(rows.length, equals(2));
      for (final r in rows) {
        expect(r['status'], equals('synced'));
      }
    });

    test('Test Lane Isolation: A failure in orders lane does not block payments lane from dispatching and completing', () async {
      final dispatchedIds = <String>[];

      final transport = _CustomTestTransport(
        onPushCustom: ({
          required String url,
          required String method,
          required String mutationId,
          required int createdAtMs,
          Map<String, dynamic>? payload,
          String? entityId,
          Map<String, String>? headers,
        }) async {
          dispatchedIds.add(mutationId);

          if (mutationId == 'ord-mut-1') {
            // Fail order 1 with server 500
            return const TransportResponse(statusCode: 500, body: '{"error":"Internal Server Error"}');
          }
          if (mutationId == 'pay-mut-1') {
            // Payments succeeds
            return const TransportResponse(statusCode: 200, body: '{"success":true}');
          }
          return const TransportResponse(statusCode: 200, body: '{"success":true}');
        },
      );

      final orchestrator = BatchPushOrchestrator(
        storage: storage,
        transport: transport,
        profile: SyncProfile.enterprise,
        backoffPolicy: BackoffPolicy(base: const Duration(milliseconds: 500)),
        maxConcurrentLanes: 4,
      );

      final now = DateTime.now().millisecondsSinceEpoch;
      final db = storage.db;

      // Seed 2 mutations in orders lane and 1 in payments lane
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, endpoint_url, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)",
        ['ord-mut-1', 'orders', 'ord-1', 'create', 'https://api.example.com/orders', jsonEncode({'total': 100}), now, 1],
      );
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, endpoint_url, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)",
        ['ord-mut-2', 'orders', 'ord-2', 'create', 'https://api.example.com/orders', jsonEncode({'total': 200}), now, 2],
      );
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, endpoint_url, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)",
        ['pay-mut-1', 'payments', 'pay-1', 'create', 'https://api.example.com/payments', jsonEncode({'amount': 100}), now, 3],
      );

      final result = await orchestrator.pushBatch(batchSize: 10);

      // Payment succeeded!
      expect(result.applied, equals(1));

      // ord-mut-1 was dispatched (and failed)
      expect(dispatchedIds.contains('ord-mut-1'), isTrue);
      // pay-mut-1 was dispatched and succeeded despite ord-mut-1 failure
      expect(dispatchedIds.contains('pay-mut-1'), isTrue);
      // ord-mut-2 was NEVER dispatched because ord-mut-1 failed (intra-entity FIFO protection)
      expect(dispatchedIds.contains('ord-mut-2'), isFalse);

      // Verify SQLite state:
      // pay-mut-1 is 'synced'
      final payRow = (await db.getAll("SELECT status FROM _sync_outbox WHERE mutation_id = 'pay-mut-1'")).first;
      expect(payRow['status'], equals('synced'));

      // ord-mut-1 recorded failure (status is pending with next_retry_at or dlq)
      final ord1Row = (await db.getAll("SELECT status, retry_count, next_retry_at FROM _sync_outbox WHERE mutation_id = 'ord-mut-1'")).first;
      expect(ord1Row['status'], equals('pending'));
      expect(ord1Row['retry_count'], equals(1));
      expect(ord1Row['next_retry_at'], isNotNull);

      // ord-mut-2 was reset to 'pending' safely for retry in future cycles
      final ord2Row = (await db.getAll("SELECT status FROM _sync_outbox WHERE mutation_id = 'ord-mut-2'")).first;
      expect(ord2Row['status'], equals('pending'));
    });

    test('Test Lane Isolation with Delay: Slow orders lane does not block fast payments lane', () async {
      final completionOrder = <String>[];

      final transport = _CustomTestTransport(
        onPushCustom: ({
          required String url,
          required String method,
          required String mutationId,
          required int createdAtMs,
          Map<String, dynamic>? payload,
          String? entityId,
          Map<String, String>? headers,
        }) async {
          if (mutationId == 'ord-mut-slow') {
            await Future.delayed(const Duration(milliseconds: 70));
          } else if (mutationId == 'pay-mut-fast') {
            await Future.delayed(const Duration(milliseconds: 10));
          }
          completionOrder.add(mutationId);
          return const TransportResponse(statusCode: 200, body: '{"success":true}');
        },
      );

      final orchestrator = BatchPushOrchestrator(
        storage: storage,
        transport: transport,
        profile: SyncProfile.enterprise,
        backoffPolicy: BackoffPolicy(),
        maxConcurrentLanes: 4,
      );

      final now = DateTime.now().millisecondsSinceEpoch;
      final db = storage.db;

      // Seed slow order and fast payment
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, endpoint_url, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)",
        ['ord-mut-slow', 'orders', 'ord-1', 'create', 'https://api.example.com/orders', jsonEncode({'total': 100}), now, 1],
      );
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, endpoint_url, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)",
        ['pay-mut-fast', 'payments', 'pay-1', 'create', 'https://api.example.com/payments', jsonEncode({'amount': 50}), now, 2],
      );

      final result = await orchestrator.pushBatch(batchSize: 10);
      expect(result.status, equals(SyncPushStatus.success));
      expect(result.applied, equals(2));

      // Fast payment completed BEFORE slow order, proving lane non-blocking!
      expect(completionOrder, equals(['pay-mut-fast', 'ord-mut-slow']));
    });

    test('Test Pool Concurrency Limiting: Respects maxConcurrentLanes across multiple entity lanes', () async {
      int activeConcurrentLanes = 0;
      int maxObservedConcurrentLanes = 0;

      final transport = _CustomTestTransport(
        onPushCustom: ({
          required String url,
          required String method,
          required String mutationId,
          required int createdAtMs,
          Map<String, dynamic>? payload,
          String? entityId,
          Map<String, String>? headers,
        }) async {
          activeConcurrentLanes++;
          if (activeConcurrentLanes > maxObservedConcurrentLanes) {
            maxObservedConcurrentLanes = activeConcurrentLanes;
          }

          await Future.delayed(const Duration(milliseconds: 40));

          activeConcurrentLanes--;
          return const TransportResponse(statusCode: 200, body: '{"success":true}');
        },
      );

      const maxPoolSize = 3;
      final orchestrator = BatchPushOrchestrator(
        storage: storage,
        transport: transport,
        profile: SyncProfile.enterprise,
        backoffPolicy: BackoffPolicy(),
        maxConcurrentLanes: maxPoolSize,
      );

      final now = DateTime.now().millisecondsSinceEpoch;
      final db = storage.db;

      // Seed 6 distinct entities
      final entities = ['orders', 'payments', 'notes', 'attachments', 'customers', 'invoices'];
      for (int i = 0; i < entities.length; i++) {
        final ent = entities[i];
        await db.execute(
          "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, endpoint_url, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)",
          ['mut-$ent', ent, 'id-$i', 'create', 'https://api.example.com/$ent', jsonEncode({'val': i}), now, i + 1],
        );
      }

      final result = await orchestrator.pushBatch(batchSize: 10);
      expect(result.status, equals(SyncPushStatus.success));
      expect(result.applied, equals(6));

      // Concurrency was capped at maxPoolSize (3)
      expect(maxObservedConcurrentLanes, lessThanOrEqualTo(maxPoolSize));
      expect(maxObservedConcurrentLanes, greaterThanOrEqualTo(2));
    });

    test('Test Dependent Child Unlocking: Enterprise mutation success unlocks held dependents', () async {
      final transport = _CustomTestTransport(
        onPushCustom: ({
          required String url,
          required String method,
          required String mutationId,
          required int createdAtMs,
          Map<String, dynamic>? payload,
          String? entityId,
          Map<String, String>? headers,
        }) async {
          return const TransportResponse(statusCode: 200, body: '{"success":true}');
        },
      );

      final pusher = CustomRestPusher(
        storage: storage,
        transport: transport,
        profile: SyncProfile.enterprise,
        backoffPolicy: BackoffPolicy(),
        maxConcurrentLanes: 4,
      );

      final now = DateTime.now().millisecondsSinceEpoch;
      final db = storage.db;

      // Seed parent order (in_flight) and dependent item (held)
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, endpoint_url, payload_json, status, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, ?, 'in_flight', ?, ?)",
        ['parent-mut', 'orders', 'ord-100', 'create', 'https://api.example.com/orders', jsonEncode({'total': 100}), now, 1],
      );
      await db.execute(
        "INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, endpoint_url, payload_json, status, depends_on_mutation_id, created_at, sequence_id) VALUES (?, ?, ?, ?, ?, ?, 'held', ?, ?, ?)",
        ['child-mut', 'order_items', 'item-1', 'create', 'https://api.example.com/items', jsonEncode({'name': 'Widget'}), 'parent-mut', now, 2],
      );

      final parentRow = (await db.getAll("SELECT * FROM _sync_outbox WHERE mutation_id = 'parent-mut'")).first;

      final result = await pusher.pushCustomEndpoints(
        pending: [parentRow],
        mutationIds: ['parent-mut'],
        placeholders: '?',
        nowMs: now,
      );

      expect(result.status, equals(SyncPushStatus.success));
      expect(result.applied, equals(1));

      // Parent is synced
      final parentStatus = (await db.getAll("SELECT status FROM _sync_outbox WHERE mutation_id = 'parent-mut'")).first['status'];
      expect(parentStatus, equals('synced'));

      // Child is unlocked from held to pending
      final childStatus = (await db.getAll("SELECT status FROM _sync_outbox WHERE mutation_id = 'child-mut'")).first['status'];
      expect(childStatus, equals('pending'));
    });
  });
}
