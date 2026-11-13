import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'storage_test_helpers.dart';

void main() {
  group('Ticket 05: Cooling-Off Window Coalescing & Zero-Network Local Undo',
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
      tempDir.deleteSync(recursive: true);
    });

    test('1. Saving with coolingTime or holdFor sets dispatch_after', () async {
      final now = DateTime.now().millisecondsSinceEpoch;

      final mutCool = await storage.save(
        entity: 'tasks',
        id: 'task-cool-1',
        data: {'title': 'Cooling Task'},
        coolingTime: const Duration(minutes: 5),
      );
      expect(mutCool, isNotEmpty);

      final rowCool = await storage.db.get(
        'SELECT dispatch_after, status FROM _sync_outbox WHERE mutation_id = ?;',
        [mutCool],
      );
      final dispatchAfterCool = rowCool['dispatch_after'] as int?;
      expect(dispatchAfterCool, isNotNull);
      expect(dispatchAfterCool!, greaterThanOrEqualTo(now + 299000));
      expect(dispatchAfterCool, lessThanOrEqualTo(now + 305000));
      expect(rowCool['status'], equals('pending'));

      final mutHold = await storage.save(
        entity: 'tasks',
        id: 'task-hold-1',
        data: {'title': 'Held Task'},
        holdFor: const Duration(minutes: 10),
      );
      expect(mutHold, isNotEmpty);

      final rowHold = await storage.db.get(
        'SELECT dispatch_after, status FROM _sync_outbox WHERE mutation_id = ?;',
        [mutHold],
      );
      final dispatchAfterHold = rowHold['dispatch_after'] as int?;
      expect(dispatchAfterHold, isNotNull);
      expect(dispatchAfterHold!, greaterThanOrEqualTo(now + 599000));
      expect(dispatchAfterHold, lessThanOrEqualTo(now + 605000));
    });

    test('2. Subsequent edits within cooling window coalesce in place',
        () async {
      final mut1 = await storage.save(
        entity: 'tasks',
        id: 'task-coalesce-1',
        data: {'title': 'Draft v1', 'content': 'Initial'},
        coolingTime: const Duration(minutes: 5),
      );

      final mut2 = await storage.save(
        entity: 'tasks',
        id: 'task-coalesce-1',
        data: {'title': 'Draft v2', 'content': 'Second edit'},
      );
      expect(mut2, equals(mut1), reason: 'Must preserve same mutation_id');

      final outboxRows = await storage.db.getAll(
        "SELECT * FROM _sync_outbox WHERE entity_name = 'tasks' AND entity_id = 'task-coalesce-1';",
      );
      expect(outboxRows.length, equals(1),
          reason: 'Must coalesce in place into 1 row');

      final outbox1 = outboxRows.first;
      final payload1 =
          jsonDecode(outbox1['payload_json'] as String) as Map<String, dynamic>;
      expect(payload1['title'], equals('Draft v2'));
      expect(payload1['content'], equals('Second edit'));

      final history1 = jsonDecode(outbox1['revision_history_json'] as String)
          as List<dynamic>;
      expect(history1.length, equals(1));
      expect(history1[0]['snapshot']['title'], equals('Draft v1'));
      expect(history1[0]['snapshot']['content'], equals('Initial'));
      expect(history1[0]['timestamp'], isNotNull);

      // Third edit within cooling window
      final mut3 = await storage.save(
        entity: 'tasks',
        id: 'task-coalesce-1',
        data: {'title': 'Draft v3', 'content': 'Final edit'},
      );
      expect(mut3, equals(mut1));

      final outboxRowsAfterThird = await storage.db.getAll(
        "SELECT * FROM _sync_outbox WHERE entity_name = 'tasks' AND entity_id = 'task-coalesce-1';",
      );
      expect(outboxRowsAfterThird.length, equals(1));

      final outbox2 = outboxRowsAfterThird.first;
      final payload2 =
          jsonDecode(outbox2['payload_json'] as String) as Map<String, dynamic>;
      expect(payload2['title'], equals('Draft v3'));

      final history2 = jsonDecode(outbox2['revision_history_json'] as String)
          as List<dynamic>;
      expect(history2.length, equals(2));
      expect(history2[0]['snapshot']['title'], equals('Draft v1'));
      expect(history2[1]['snapshot']['title'], equals('Draft v2'));

      // Check domain table row has 5 universal columns
      final domainRow = await storage.db.get(
        "SELECT id, version, updated_at, expires_at, data_json FROM tasks WHERE id = 'task-coalesce-1';",
      );
      expect(domainRow['id'], equals('task-coalesce-1'));
      final domainData =
          jsonDecode(domainRow['data_json'] as String) as Map<String, dynamic>;
      expect(domainData['title'], equals('Draft v3'));
    });

    test('3. Candidate queue queries ignore rows where now < dispatch_after',
        () async {
      final now = DateTime.now().millisecondsSinceEpoch;

      // Mutation A: Held in cooling-off window (dispatch_after = now + 5 min)
      await storage.save(
        entity: 'tasks',
        id: 'task-cooling-active',
        data: {'title': 'Held in cooling'},
        coolingTime: const Duration(minutes: 5),
      );

      // Mutation B: Ready immediately (dispatch_after is null)
      await storage.save(
        entity: 'tasks',
        id: 'task-ready-now',
        data: {'title': 'Ready immediately'},
      );

      // Candidate query as defined in Architecture Blueprint Section 4:
      const candidateSql = '''
        SELECT entity_id FROM _sync_outbox 
        WHERE status = 'pending' 
          AND (dispatch_after IS NULL OR dispatch_after <= ?)
          AND (next_retry_at IS NULL OR next_retry_at <= ?)
        ORDER BY sequence_id ASC;
      ''';

      final candidatesNow = await storage.db.getAll(candidateSql, [now, now]);
      final candidateIdsNow =
          candidatesNow.map((r) => r['entity_id'] as String).toList();

      expect(candidateIdsNow, contains('task-ready-now'));
      expect(candidateIdsNow, isNot(contains('task-cooling-active')),
          reason: 'Must ignore mutations whose cooling window is still active');

      // After cooling window elapses (simulated by passing now + 6 minutes)
      final futureTime = now + 360000;
      final candidatesLater =
          await storage.db.getAll(candidateSql, [futureTime, futureTime]);
      final candidateIdsLater =
          candidatesLater.map((r) => r['entity_id'] as String).toList();

      expect(candidateIdsLater, contains('task-cooling-active'));
      expect(candidateIdsLater, contains('task-ready-now'));
    });

    test(
        '4. undoDelete restores domain record from base_snapshot_json and cancels pending delete mutation',
        () async {
      await storage.save(
        entity: 'tasks',
        id: 'task-undoable-1',
        data: {'title': 'Critical Task', 'priority': 'high'},
      );

      // Delete with cooling / undo window
      final deleteMutId = await storage.delete(
        entity: 'tasks',
        id: 'task-undoable-1',
        undoWindow: const Duration(minutes: 5),
      );
      expect(deleteMutId, isNotNull);

      // Verify domain table is empty
      final domainAfterDel = await storage.db
          .getAll("SELECT * FROM tasks WHERE id = 'task-undoable-1';");
      expect(domainAfterDel, isEmpty);

      // Verify outbox has delete mutation with base_snapshot_json
      final deleteOutbox = await storage.db.get(
        "SELECT mutation_id, op, status, base_snapshot_json FROM _sync_outbox WHERE entity_id = 'task-undoable-1' AND op = 'delete';",
      );
      expect(deleteOutbox['status'], equals('pending'));
      expect(deleteOutbox['base_snapshot_json'], isNotNull);

      // Undo delete
      final undone =
          await storage.undoDelete(entity: 'tasks', id: 'task-undoable-1');
      expect(undone, isTrue);

      // Verify pending delete mutation was removed from _sync_outbox
      final deleteOutboxAfter = await storage.db.getAll(
        "SELECT * FROM _sync_outbox WHERE entity_id = 'task-undoable-1' AND op = 'delete';",
      );
      expect(deleteOutboxAfter, isEmpty);

      // Verify domain record is restored with universal 5 columns
      final restoredRow = await storage.db.get(
        "SELECT id, version, updated_at, expires_at, data_json FROM tasks WHERE id = 'task-undoable-1';",
      );
      expect(restoredRow['id'], equals('task-undoable-1'));
      final restoredData = jsonDecode(restoredRow['data_json'] as String)
          as Map<String, dynamic>;
      expect(restoredData['title'], equals('Critical Task'));
      expect(restoredData['priority'], equals('high'));

      // Subsequent undoDelete returns false (no pending delete left)
      final secondUndo =
          await storage.undoDelete(entity: 'tasks', id: 'task-undoable-1');
      expect(secondUndo, isFalse);

      // Verify undoDelete can also be called with just (id: ...) without entity
      await storage.delete(
        entity: 'tasks',
        id: 'task-undoable-1',
        coolingTime: const Duration(minutes: 5),
      );
      final undoneWithoutEntity =
          await storage.undoDelete(id: 'task-undoable-1');
      expect(undoneWithoutEntity, isTrue);
    });

    test('5. undoDelete returns false when cooling window has passed',
        () async {
      await storage.save(
        entity: 'tasks',
        id: 'task-expired-undo',
        data: {'title': 'Cannot Undo'},
      );

      // Delete with zero undo window (expired immediately)
      await storage.delete(
        entity: 'tasks',
        id: 'task-expired-undo',
        undoWindow: Duration.zero,
      );

      // Attempt undo when dispatch_after has expired
      final undone =
          await storage.undoDelete(entity: 'tasks', id: 'task-expired-undo');
      expect(undone, isFalse);

      // Delete mutation is retained in outbox for sync dispatch
      final outboxRows = await storage.db.getAll(
        "SELECT * FROM _sync_outbox WHERE entity_id = 'task-expired-undo' AND op = 'delete';",
      );
      expect(outboxRows.length, equals(1));
    });

    test(
        '6. Rapid annihilation: newly created record deleted in cooling window is purged with zero outbox mutations',
        () async {
      await storage.save(
        entity: 'tasks',
        id: 'task-annihilate-1',
        data: {'title': 'Short-lived item'},
        coolingTime: const Duration(minutes: 5),
      );

      // Delete while still in cooling window
      final deleteMut = await storage.delete(
        entity: 'tasks',
        id: 'task-annihilate-1',
      );

      // Returns null - zero outbox mutations created
      expect(deleteMut, isNull);

      // Domain table has 0 rows
      final domainRows = await storage.db
          .getAll("SELECT * FROM tasks WHERE id = 'task-annihilate-1';");
      expect(domainRows, isEmpty);

      // Outbox has 0 mutations
      final outboxRows = await storage.db.getAll(
          "SELECT * FROM _sync_outbox WHERE entity_id = 'task-annihilate-1';");
      expect(outboxRows, isEmpty);
    });

    test(
        '7. Rapid annihilation works after multiple coalesced edits during cooling window',
        () async {
      await storage.save(
        entity: 'tasks',
        id: 'task-coalesce-annihilate',
        data: {'title': 'v1'},
        coolingTime: const Duration(minutes: 5),
      );
      await storage.save(
        entity: 'tasks',
        id: 'task-coalesce-annihilate',
        data: {'title': 'v2'},
      );
      await storage.save(
        entity: 'tasks',
        id: 'task-coalesce-annihilate',
        data: {'title': 'v3'},
      );

      // Verify it coalesced
      final midOutbox = await storage.db.getAll(
        "SELECT * FROM _sync_outbox WHERE entity_id = 'task-coalesce-annihilate';",
      );
      expect(midOutbox.length, equals(1));

      // Now delete within cooling window
      final deleteMut = await storage.delete(
        entity: 'tasks',
        id: 'task-coalesce-annihilate',
      );
      expect(deleteMut, isNull);

      // Zero traces remain anywhere
      final domainRows = await storage.db
          .getAll("SELECT * FROM tasks WHERE id = 'task-coalesce-annihilate';");
      expect(domainRows, isEmpty);

      final outboxRows = await storage.db.getAll(
          "SELECT * FROM _sync_outbox WHERE entity_id = 'task-coalesce-annihilate';");
      expect(outboxRows, isEmpty);
    });

    test(
        '8. pruneSyncedOutbox: purges synced mutations older than retention while preserving active mutations',
        () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final dayMs = const Duration(days: 1).inMilliseconds;

      // Seed outbox with mutations of various states and ages:
      final seedRows = [
        // 1. Synced 8 days ago (older than default 7 days) -> SHOULD BE PRUNED
        ('synced-old', 'synced', now - (8 * dayMs)),
        // 2. Synced 2 days ago (within 7 days) -> RETAINED
        ('synced-recent', 'synced', now - (2 * dayMs)),
        // 3. Pending 10 days ago -> NEVER PRUNED
        ('pending-old', 'pending', now - (10 * dayMs)),
        // 4. In Flight 10 days ago -> NEVER PRUNED
        ('in-flight-old', 'in_flight', now - (10 * dayMs)),
        // 5. Failed 10 days ago -> NEVER PRUNED
        ('failed-old', 'failed', now - (10 * dayMs)),
        // 6. DLQ 10 days ago -> NEVER PRUNED
        ('dlq-old', 'dlq', now - (10 * dayMs)),
        // 7. Held 10 days ago -> NEVER PRUNED
        ('held-old', 'held', now - (10 * dayMs)),
        // 8. Validation Error 10 days ago -> NEVER PRUNED
        ('validation-error-old', 'validation_error', now - (10 * dayMs)),
      ];

      for (final row in seedRows) {
        await storage.db.execute('''
          INSERT INTO _sync_outbox (
            mutation_id, entity_name, entity_id, op, payload_json, status, created_at, updated_at
          ) VALUES (?, 'tasks', ?, 'create', '{"title":"seed"}', ?, ?, ?);
        ''', [row.$1, row.$1, row.$2, row.$3, row.$3]);
      }

      // 1. Default prune (7 days)
      final prunedCount = await storage.pruneSyncedOutbox();
      expect(prunedCount, equals(1),
          reason: 'Only synced-old should be purged');

      final remainingAfterFirstPrune = await storage.db.getAll(
          'SELECT mutation_id, status FROM _sync_outbox ORDER BY mutation_id;');
      final remainingIds = remainingAfterFirstPrune
          .map((r) => r['mutation_id'] as String)
          .toSet();

      expect(remainingIds, isNot(contains('synced-old')));
      expect(remainingIds, contains('synced-recent'));
      expect(remainingIds, contains('pending-old'));
      expect(remainingIds, contains('in-flight-old'));
      expect(remainingIds, contains('failed-old'));
      expect(remainingIds, contains('dlq-old'));
      expect(remainingIds, contains('held-old'));
      expect(remainingIds, contains('validation-error-old'));

      // 2. Custom retention prune (1 day)
      final prunedCustom =
          await storage.pruneSyncedOutbox(retention: const Duration(days: 1));
      expect(prunedCustom, equals(1),
          reason: 'synced-recent (2 days old) should now be purged');

      final remainingAfterSecondPrune = await storage.db.getAll(
          'SELECT mutation_id, status FROM _sync_outbox ORDER BY mutation_id;');
      final remainingIds2 = remainingAfterSecondPrune
          .map((r) => r['mutation_id'] as String)
          .toSet();

      expect(remainingIds2, isNot(contains('synced-recent')));
      // All non-synced mutations are strictly protected:
      expect(remainingIds2, contains('pending-old'));
      expect(remainingIds2, contains('in-flight-old'));
      expect(remainingIds2, contains('failed-old'));
      expect(remainingIds2, contains('dlq-old'));
      expect(remainingIds2, contains('held-old'));
      expect(remainingIds2, contains('validation-error-old'));
    });

    test('9. SyncStorage initializes cleanly', () {
      expect(storage, isA<SyncStorage>());
    });
  });
}
