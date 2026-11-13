import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'storage_test_helpers.dart';

void main() {
  group('Ticket 04: Refined _sync_outbox Schema & 4 Specialized B-Tree Indexes', () {
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

    test('1. Verify all required columns in _sync_outbox schema', () async {
      final tableInfo = await storage.db.getAll('PRAGMA table_info(_sync_outbox);');
      final columnNames = tableInfo.map((row) => row['name'] as String).toSet();

      final expectedColumns = {
        'sequence_id',
        'mutation_id',
        'entity_name',
        'entity_id',
        'op',
        'endpoint_url',
        'http_method',
        'payload_json',
        'base_snapshot_json',
        'base_version',
        'status',
        'author_id',
        'user_id',
        'media_path',
        'depends_on_mutation_id',
        'correlation_tag',
        'priority',
        'sla_seconds',
        'schema_version',
        'error_details_json',
        'dispatch_after',
        'revision_history_json',
        'headers_json',
        'retry_count',
        'next_retry_at',
        'created_at',
        'updated_at',
      };

      expect(columnNames, containsAll(expectedColumns));
      expect(columnNames.length, equals(27));

      // Verify sequence_id is primary key
      final seqCol = tableInfo.firstWhere((row) => row['name'] == 'sequence_id');
      expect(seqCol['pk'], equals(1));
      expect(seqCol['type'], equals('INTEGER'));

      // Verify mutation_id is not null
      final mutCol = tableInfo.firstWhere((row) => row['name'] == 'mutation_id');
      expect(mutCol['notnull'], equals(1));
      expect(mutCol['type'], equals('TEXT'));

      // Verify enterprise audit & media columns exist as TEXT
      for (final col in ['author_id', 'user_id', 'media_path']) {
        final info = tableInfo.firstWhere((row) => row['name'] == col);
        expect(info['type'], equals('TEXT'));
      }
    });

    test('2. Verify the 4 specialized B-Tree indexes exist and are query-plannable', () async {
      final indexes = await storage.db.getAll(
        "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = '_sync_outbox';",
      );
      final indexNames = indexes.map((row) => row['name'] as String).toSet();

      expect(indexNames, contains('idx_sync_outbox_queue'));
      expect(indexNames, contains('idx_sync_outbox_sla'));
      expect(indexNames, contains('idx_sync_outbox_deps'));
      expect(indexNames, contains('idx_sync_outbox_entity'));

      // Verify query plan on idx_sync_outbox_queue
      final qpQueue = await storage.db.getAll(
        "EXPLAIN QUERY PLAN SELECT * FROM _sync_outbox WHERE status = 'pending' AND dispatch_after <= 1000 ORDER BY dispatch_after, next_retry_at, priority DESC, sequence_id ASC;",
      );
      final detailQueue = qpQueue.map((r) => r['detail'].toString()).join(' ');
      expect(detailQueue, contains('idx_sync_outbox_queue'));

      // Verify query plan on idx_sync_outbox_sla (expression index)
      final qpSla = await storage.db.getAll(
        "EXPLAIN QUERY PLAN SELECT * FROM _sync_outbox WHERE status = 'pending' ORDER BY (created_at + sla_seconds * 1000) ASC, priority DESC;",
      );
      final detailSla = qpSla.map((r) => r['detail'].toString()).join(' ');
      expect(detailSla, contains('idx_sync_outbox_sla'));

      // Verify query plan on idx_sync_outbox_deps
      final qpDeps = await storage.db.getAll(
        "EXPLAIN QUERY PLAN SELECT * FROM _sync_outbox WHERE depends_on_mutation_id = 'parent-mut-1';",
      );
      final detailDeps = qpDeps.map((r) => r['detail'].toString()).join(' ');
      expect(detailDeps, contains('idx_sync_outbox_deps'));

      // Verify query plan on idx_sync_outbox_entity
      final qpEntity = await storage.db.getAll(
        "EXPLAIN QUERY PLAN SELECT * FROM _sync_outbox WHERE entity_name = 'tasks' AND entity_id = 't1' AND status = 'pending';",
      );
      final detailEntity = qpEntity.map((r) => r['detail'].toString()).join(' ');
      expect(detailEntity, contains('idx_sync_outbox_entity'));
    });

    test('3. Verify SQLite CHECK constraints on priority (0..3), status, base_version, and SLA', () async {
      final now = DateTime.now().millisecondsSinceEpoch;

      // Priority 0, 1, 2, 3 should all succeed
      for (int pri = 0; pri <= 3; pri++) {
        await storage.db.execute('''
          INSERT INTO _sync_outbox (
            mutation_id, entity_name, entity_id, op, priority, created_at
          ) VALUES (?, 'tasks', 't-$pri', 'create', ?, ?);
        ''', ['mut-pri-$pri', pri, now]);
      }

      // Priority -1 should fail CHECK constraint
      expect(
        () async => await storage.db.execute('''
          INSERT INTO _sync_outbox (
            mutation_id, entity_name, entity_id, op, priority, created_at
          ) VALUES ('mut-pri-neg', 'tasks', 't-neg', 'create', -1, ?);
        ''', [now]),
        throwsA(anything),
      );

      // Priority 4 should fail CHECK constraint
      expect(
        () async => await storage.db.execute('''
          INSERT INTO _sync_outbox (
            mutation_id, entity_name, entity_id, op, priority, created_at
          ) VALUES ('mut-pri-4', 'tasks', 't-4', 'create', 4, ?);
        ''', [now]),
        throwsA(anything),
      );

      // Status check constraint
      expect(
        () async => await storage.db.execute('''
          INSERT INTO _sync_outbox (
            mutation_id, entity_name, entity_id, op, status, created_at
          ) VALUES ('mut-bad-status', 'tasks', 't-stat', 'create', 'bogus_status', ?);
        ''', [now]),
        throwsA(anything),
      );

      // Base version < 1 check constraint
      expect(
        () async => await storage.db.execute('''
          INSERT INTO _sync_outbox (
            mutation_id, entity_name, entity_id, op, base_version, created_at
          ) VALUES ('mut-bad-ver', 'tasks', 't-ver', 'create', 0, ?);
        ''', [now]),
        throwsA(anything),
      );

      // Unique mutation_id constraint
      expect(
        () async => await storage.db.execute('''
          INSERT INTO _sync_outbox (
            mutation_id, entity_name, entity_id, op, created_at
          ) VALUES ('mut-pri-0', 'tasks', 't-dup', 'create', ?);
        ''', [now]),
        throwsA(anything),
      );
    });

    test('4. SyncValidator enforces priority 0..3 and throws on out-of-range', () {
      // 0..3 valid
      for (int i = 0; i <= 3; i++) {
        expect(() => SyncValidator.validatePriority(i), returnsNormally);
      }

      // -1 and 4 invalid
      expect(() => SyncValidator.validatePriority(-1), throwsA(isA<ArgumentError>()));
      expect(() => SyncValidator.validatePriority(4), throwsA(isA<ArgumentError>()));
    });

    test('5. SqliteOutboxWriter records author_id, user_id, media_path, priority, and sla_seconds', () async {
      final mutId = await storage.save(
        entity: 'tasks',
        id: 'task-enterprise-1',
        data: {'title': 'Enterprise Task with Media'},
        authorId: 'auth_usr_99',
        userId: 'usr_enterprise_42',
        mediaPath: '/app/documents/receipt.pdf',
        priority: 3,
        sla: const Duration(minutes: 30),
      );

      // Verify UUIDv7 format (36 chars, 8-4-4-4-12 hex with hyphens)
      expect(mutId, hasLength(36));
      expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(mutId), isTrue);

      final row = await storage.db.get('SELECT * FROM _sync_outbox WHERE mutation_id = ?;', [mutId]);
      expect(row, isNotNull);
      expect(row['mutation_id'], equals(mutId));
      expect(row['author_id'], equals('auth_usr_99'));
      expect(row['user_id'], equals('usr_enterprise_42'));
      expect(row['media_path'], equals('/app/documents/receipt.pdf'));
      expect(row['priority'], equals(3));
      expect(row['sla_seconds'], equals(1800)); // 30 minutes = 1800s
      expect(row['status'], equals('pending'));

      // Verify OutboxMutation domain model mapping
      final mutation = OutboxMutation.fromMap(row);
      expect(mutation.mutationId, equals(mutId));
      expect(mutation.authorId, equals('auth_usr_99'));
      expect(mutation.userId, equals('usr_enterprise_42'));
      expect(mutation.mediaPath, equals('/app/documents/receipt.pdf'));
      expect(mutation.priority, equals(3));
      expect(mutation.slaSeconds, equals(1800));

      final mapped = mutation.toMap();
      expect(mapped['author_id'], equals('auth_usr_99'));
      expect(mapped['user_id'], equals('usr_enterprise_42'));
      expect(mapped['media_path'], equals('/app/documents/receipt.pdf'));
      expect(mapped['priority'], equals(3));
    });

    test('6. SqliteOutboxWriter extracts metadata from data payload if parameters omitted', () async {
      final mutId = await storage.save(
        entity: 'tasks',
        id: 'task-payload-metadata',
        data: {
          'title': 'Task with Embedded Metadata',
          'author_id': 'payload_author',
          'user_id': 'payload_user',
          'media_path': '/media/photo.jpg',
          'priority': 2,
          'sla_seconds': 3600,
        },
      );

      final row = await storage.db.get('SELECT * FROM _sync_outbox WHERE mutation_id = ?;', [mutId]);
      expect(row, isNotNull);
      expect(row['author_id'], equals('payload_author'));
      expect(row['user_id'], equals('payload_user'));
      expect(row['media_path'], equals('/media/photo.jpg'));
      expect(row['priority'], equals(2));
      expect(row['sla_seconds'], equals(3600));
    });

    test('7. Grace window coalescing preserves and updates refined metadata', () async {
      final holdWindow = const Duration(seconds: 10);

      // Initial draft save
      final mutId1 = await storage.save(
        entity: 'tasks',
        id: 'task-coalesce',
        data: {'title': 'Initial Draft'},
        authorId: 'auth_1',
        userId: 'usr_1',
        mediaPath: '/tmp/initial.png',
        priority: 1,
        sla: const Duration(hours: 1),
        holdFor: holdWindow,
      );

      // Revision within holdFor window
      final mutId2 = await storage.save(
        entity: 'tasks',
        id: 'task-coalesce',
        data: {'title': 'Revised Draft'},
        authorId: 'auth_1',
        userId: 'usr_1',
        mediaPath: '/tmp/revised.png',
        priority: 2,
        sla: const Duration(minutes: 45),
        holdFor: holdWindow,
      );

      expect(mutId2, equals(mutId1));

      final row = await storage.db.get('SELECT * FROM _sync_outbox WHERE mutation_id = ?;', [mutId1]);
      expect(row['media_path'], equals('/tmp/revised.png'));
      expect(row['priority'], equals(2));
      expect(row['sla_seconds'], equals(2700)); // 45m = 2700s
      expect(row['revision_history_json'], isNotNull);
    });
  });
}
