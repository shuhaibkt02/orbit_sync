import 'package:test/test.dart';
import 'package:orbit_sync/offline_sync.dart';
import 'consensus_test_helpers.dart';

void main() {
  late TestConsensusEnv env;

  setUp(() async {
    env = await TestConsensusEnv.create();
  });

  tearDown(() async {
    await env.dispose();
  });

  group('Layer 2 Consensus: SyncWorker Push Operations', () {
    test('Test Case 1: In-Flight Drop & Deduplication (Two Generals Problem)', () async {
      final mutId = await env.storage.save(
        entity: 'tasks',
        id: 't-drop-1',
        data: {'title': 'Two Generals Task'},
      );

      final outboxBefore = await env.storage.db.get(
        'SELECT status FROM _sync_outbox WHERE mutation_id = ?',
        [mutId],
      );
      expect(outboxBefore['status'], 'pending');

      final pushDrop = await env.worker.pushBatch(chaos: 'drop_before_response');
      expect(pushDrop.status, SyncPushStatus.networkError);

      final outboxAfterDrop = await env.storage.db.get(
        'SELECT status FROM _sync_outbox WHERE mutation_id = ?',
        [mutId],
      );
      expect(outboxAfterDrop['status'], 'pending');

      final pushRetry = await env.worker.pushBatch(force: true);
      expect(pushRetry.status, SyncPushStatus.success);

      final outboxFinal = await env.storage.db.get(
        'SELECT status FROM _sync_outbox WHERE mutation_id = ?',
        [mutId],
      );
      expect(outboxFinal['status'], 'synced');

      final serverCount = env.server.records.keys.where((k) => k == 'tasks:t-drop-1').length;
      expect(serverCount, 1);
    });

    test('Test Case 2: Poison Pill DLQ & HoL Prevention (Challenge 8 & 9)', () async {
      final poisonId = await env.storage.save(
        entity: 'tasks',
        id: 'poison-pill',
        data: {'title': 'Malformed Item'},
      );

      final validIds = <String>[];
      for (var i = 1; i <= 3; i++) {
        final id = await env.storage.save(
          entity: 'tasks',
          id: 'valid-$i',
          data: {'title': 'Valid Item $i'},
        );
        validIds.add(id);
      }

      final push1 = await env.worker.pushBatch(batchSize: 1);
      expect(push1.status, SyncPushStatus.poisonPill);

      final poisonRow = await env.storage.db.get(
        'SELECT status, error_details_json FROM _sync_outbox WHERE mutation_id = ?',
        [poisonId],
      );
      expect(poisonRow['status'], 'dlq');
      expect(poisonRow['error_details_json'], contains('Poison pill rejected'));

      final push2 = await env.worker.pushBatch(batchSize: 10);
      expect(push2.status, SyncPushStatus.success);
      expect(push2.applied, 3);

      for (final id in validIds) {
        final r = await env.storage.db.get(
          'SELECT status FROM _sync_outbox WHERE mutation_id = ?',
          [id],
        );
        expect(r['status'], 'synced');
      }
    });

    test('Test Case 3: Auth Refresh Pausing without Burning Retry Budget (Challenge 9)', () async {
      await env.storage.save(entity: 'tasks', id: 'auth-task', data: {'title': 'Auth Task'});

      bool authExpiredCalled = false;
      String currentToken = 'expired';

      env.worker.getAuthToken = () async => currentToken;
      env.worker.onAuthExpired = () async {
        authExpiredCalled = true;
        currentToken = 'valid-refreshed-token';
      };

      final pushAuth = await env.worker.pushBatch(batchSize: 1);
      expect(pushAuth.status, SyncPushStatus.unauthorized);
      expect(authExpiredCalled, isTrue);

      final outboxRow = await env.storage.db.get(
        "SELECT status, retry_count FROM _sync_outbox WHERE entity_id = 'auth-task';",
      );
      expect(outboxRow['status'], 'pending');
      expect(outboxRow['retry_count'], 0);

      final pushValid = await env.worker.pushBatch(batchSize: 1);
      expect(pushValid.status, SyncPushStatus.success);

      final syncedRow = await env.storage.db.get(
        "SELECT status FROM _sync_outbox WHERE entity_id = 'auth-task';",
      );
      expect(syncedRow['status'], 'synced');
    });

    test('Test Case 4: Grace Window (holdFor / dispatch_after) suppresses push until window elapses', () async {
      final baseNow = DateTime.now().millisecondsSinceEpoch;
      int simulatedNow = baseNow;
      final timeGatedWorker = SyncWorker(
        storage: env.storage,
        serverUrl: env.server.baseUrl,
        nowMsProvider: () => simulatedNow,
      );

      // Save record with 5-minute hold window
      final mutId = await env.storage.save(
        entity: 'tasks',
        id: 'hold-task-1',
        data: {'title': 'Held Task'},
        holdFor: const Duration(minutes: 5),
      );

      // Push while within hold window (simulatedNow < dispatch_after)
      final pushEarly = await timeGatedWorker.pushBatch();
      expect(pushEarly.status, SyncPushStatus.success);
      expect(pushEarly.applied, 0, reason: 'Must skip mutations whose dispatch_after is in future');

      final rowEarly = await env.storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?;', [mutId]);
      expect(rowEarly['status'], 'pending');

      // Advance simulated clock past 5 minutes
      simulatedNow += const Duration(minutes: 6).inMilliseconds;

      final pushDue = await timeGatedWorker.pushBatch();
      expect(pushDue.status, SyncPushStatus.success);
      expect(pushDue.applied, 1);

      final rowSynced = await env.storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?;', [mutId]);
      expect(rowSynced['status'], 'synced');

      timeGatedWorker.dispose();
    });
  });
}
