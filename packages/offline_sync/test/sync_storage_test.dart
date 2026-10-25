import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:offline_sync/offline_sync.dart';

void main() {
  late Directory tempDir;
  late SyncStorage storage;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('offline_sync_test_');
    storage = await SyncStorage.open(
      path: '${tempDir.path}/test_sync.db',
      maxReaders: 4,
    );
    await storage.registerEntityTable('tasks', {
      'title': 'TEXT',
      'priority': 'TEXT',
    });
  });

  tearDown(() async {
    await storage.close();
    tempDir.deleteSync(recursive: true);
  });

  group('Issue 02: Storage Engine & Transactional Outbox', () {
    test('Engine Setup & Outbox Schema verification', () async {
      // Assert journal_mode is WAL
      final journalMode = await storage.db.get('PRAGMA journal_mode;');
      expect(journalMode['journal_mode'].toString().toLowerCase(), 'wal');

      // Verify outbox schema columns
      final tableInfo = await storage.db.getAll('PRAGMA table_info(_sync_outbox);');
      final colNames = tableInfo.map((r) => r['name'] as String).toSet();
      expect(colNames, containsAll([
        'sequence_id',
        'mutation_id',
        'entity_name',
        'entity_id',
        'op',
        'payload_json',
        'base_snapshot_json',
        'base_version',
        'status',
        'depends_on_mutation_id',
        'correlation_tag',
        'priority',
        'sla_seconds',
        'schema_version',
        'dispatch_after',
        'revision_history_json',
        'retry_count',
        'next_retry_at',
        'created_at',
        'updated_at',
      ]));

      // Verify _sync_id_map table exists
      final idMapInfo = await storage.db.getAll('PRAGMA table_info(_sync_id_map);');
      final idMapCols = idMapInfo.map((r) => r['name'] as String).toSet();
      expect(idMapCols, containsAll([
        'entity_name',
        'local_temp_id',
        'canonical_server_id',
        'created_at',
      ]));
    });

    test('Test Case 1: Concurrency - Concurrent reads with pooled readers while writing executes with 0 errors', () async {
      final futures = <Future>[];
      int readCount = 0;

      // Launch 50 concurrent reader queries across pooled connections
      for (var i = 0; i < 50; i++) {
        futures.add(Future(() async {
          final res = await storage.db.getAll('SELECT COUNT(*) as count FROM tasks;');
          expect(res, isNotEmpty);
          readCount++;
        }));
      }

      // Concurrently insert 20 outbox records on the writer isolate
      for (var i = 0; i < 20; i++) {
        futures.add(storage.save(
          entity: 'tasks',
          id: 'task-conc-$i',
          data: {'title': 'Concurrent Task $i', 'priority': 'medium'},
        ));
      }

      // Await all concurrent tasks; must finish without SQLITE_BUSY or exceptions
      await Future.wait(futures);
      expect(readCount, 50);

      final totalOutbox = await storage.db.get('SELECT COUNT(*) as count FROM _sync_outbox;');
      expect(totalOutbox['count'], 20);
    });

    test('Test Case 2: Atomic Outbox Commit - Rollback on failure guarantees zero partial writes', () async {
      // Pre-condition: tasks table is empty
      final initialCount = await storage.db.get('SELECT COUNT(*) as count FROM tasks;');
      expect(initialCount['count'], 0);

      // Attempt atomic transaction that fails during outbox step
      expect(
        () async {
          await storage.db.writeTransaction((tx) async {
            // Write to domain table
            await tx.execute("INSERT INTO tasks (id, title, priority, version, updated_at) VALUES ('atomic-1', 'Fail Title', 'low', 1, 1000);");
            // Simulate deliberate failure during outbox envelope append (e.g., duplicate primary key or abort)
            throw Exception('Simulated crash during outbox commit');
          });
        },
        throwsA(isA<Exception>()),
      );

      // Verify domain table write was rolled back completely
      final afterCount = await storage.db.get('SELECT COUNT(*) as count FROM tasks;');
      expect(afterCount['count'], 0);

      final outboxCount = await storage.db.get('SELECT COUNT(*) as count FROM _sync_outbox;');
      expect(outboxCount['count'], 0);
    });

    test('Test Case 3: Shadow-Base Materialization & Optimistic Rollback', () async {
      // 1. Initial save of an entity
      await storage.save(
        entity: 'tasks',
        id: 'task-100',
        data: {'title': 'Original Title', 'priority': 'low'},
        version: 1,
      );

      // Verify domain table has columns materialized directly
      final row1 = await storage.db.get('SELECT * FROM tasks WHERE id = ?', ['task-100']);
      expect(row1['title'], 'Original Title');
      expect(row1['priority'], 'low');
      expect(row1['_base_snapshot_json'], isNull); // newly created record has no prior snapshot

      // 2. Optimistic update
      final mut2 = await storage.save(
        entity: 'tasks',
        id: 'task-100',
        data: {'title': 'Optimistic Title', 'priority': 'high'},
        version: 2,
      );

      // Table columns reflect optimistic edit directly
      final row2 = await storage.db.get('SELECT * FROM tasks WHERE id = ?', ['task-100']);
      expect(row2['title'], 'Optimistic Title');
      expect(row2['priority'], 'high');

      // Outbox stores pre-mutation baseline snapshot
      final outbox2 = await storage.db.get('SELECT * FROM _sync_outbox WHERE mutation_id = ?', [mut2]);
      final baseSnapshot = jsonDecode(outbox2['base_snapshot_json'] as String) as Map<String, dynamic>;
      expect(baseSnapshot['title'], 'Original Title');
      expect(baseSnapshot['priority'], 'low');

      // 3. Rollback optimistic edit (e.g. server rejected with 422 or conflict)
      await storage.rollbackOptimistic(mut2, status: 'conflict');

      // Domain table is restored to Original Title
      final rowRestored = await storage.db.get('SELECT * FROM tasks WHERE id = ?', ['task-100']);
      expect(rowRestored['title'], 'Original Title');
      expect(rowRestored['priority'], 'low');

      final outboxStatus = await storage.db.get('SELECT status FROM _sync_outbox WHERE mutation_id = ?', [mut2]);
      expect(outboxStatus['status'], 'conflict');
    });

    test('Test Case 4: Zero-Codegen Reactivity with db.watch()', () async {
      final emissions = <int>[];
      final completer = Completer<void>();

      // Listen to dynamic query stream without code-generated TableInfo
      final sub = storage.watch('SELECT * FROM tasks ORDER BY id;').listen((rs) {
        emissions.add(rs.length);
        if (emissions.length == 3) {
          completer.complete();
        }
      });

      // Small delay to allow initial emission
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Trigger mutation 1
      await storage.save(
        entity: 'tasks',
        id: 'task-watch-1',
        data: {'title': 'First reactive item', 'priority': 'high'},
      );

      // Trigger mutation 2
      await storage.save(
        entity: 'tasks',
        id: 'task-watch-2',
        data: {'title': 'Second reactive item', 'priority': 'medium'},
      );

      await completer.future.timeout(const Duration(seconds: 3));
      await sub.cancel();

      // Assert that watch streamed: 0 rows (initial), 1 row, 2 rows
      expect(emissions, equals([0, 1, 2]));
    });

    test('Test Case 5: Native SQLite Data Type Affinity on Dynamic Columns', () async {
      await storage.save(
        entity: 'tasks',
        id: 'task-types-1',
        data: {
          'title': 'Typed Task',
          'total_count': 50,
          'unit_price': 19.95,
          'is_completed': true,
        },
      );

      final tableInfo = await storage.db.getAll('PRAGMA table_info(tasks);');
      final typeMap = {for (final r in tableInfo) r['name'] as String: r['type'] as String};

      expect(typeMap['total_count'], 'INTEGER');
      expect(typeMap['unit_price'], 'REAL');
      expect(typeMap['is_completed'], 'INTEGER');

      // Verify numeric comparison works (not lexicographical string comparison)
      final gtResult = await storage.db.getAll('SELECT id FROM tasks WHERE total_count > 40;');
      expect(gtResult.length, 1);
      expect(gtResult.first['id'], 'task-types-1');
    });

    test('Test Case 6: Grace Window (holdFor) Coalescing & Snapshot Revision Trail', () async {
      final mut1 = await storage.save(
        entity: 'tasks',
        id: 'task-grace-1',
        data: {'title': 'Initial Draft', 'priority': 'low'},
        holdFor: const Duration(minutes: 5),
      );

      // Save intermediate edit within the 5-minute hold window
      final mut2 = await storage.save(
        entity: 'tasks',
        id: 'task-grace-1',
        data: {'title': 'Revised Draft', 'priority': 'high'},
        holdFor: const Duration(minutes: 5),
      );

      // Must coalesce to the same mutation row
      expect(mut2, equals(mut1));

      final outboxRows = await storage.db.getAll("SELECT * FROM _sync_outbox WHERE entity_id = 'task-grace-1';");
      expect(outboxRows.length, 1);

      final outbox = outboxRows.first;
      expect(jsonDecode(outbox['payload_json'] as String)['title'], 'Revised Draft');

      // Verify intermediate snapshot was preserved in revision_history_json
      final history = jsonDecode(outbox['revision_history_json'] as String) as List<dynamic>;
      expect(history.length, 1);
      expect(history.first['snapshot']['title'], 'Initial Draft');
      expect(history.first['snapshot']['priority'], 'low');
    });

    test('Test Case 7: Zero-Network Local Annihilation on Grace Delete', () async {
      // Create new draft with hold window
      await storage.save(
        entity: 'tasks',
        id: 'task-grace-delete',
        data: {'title': 'To be deleted instantly'},
        holdFor: const Duration(minutes: 5),
      );

      // Delete while still within the grace window
      final deleteMut = await storage.delete(
        entity: 'tasks',
        id: 'task-grace-delete',
      );

      // Null return indicates zero-network local annihilation
      expect(deleteMut, isNull);

      // Verify domain row is purged
      final domainRows = await storage.db.getAll("SELECT * FROM tasks WHERE id = 'task-grace-delete';");
      expect(domainRows, isEmpty);

      // Verify outbox has zero records for this entity
      final outboxRows = await storage.db.getAll("SELECT * FROM _sync_outbox WHERE entity_id = 'task-grace-delete';");
      expect(outboxRows, isEmpty);
    });

    test('Test Case 8: Undoable Delete and undoDelete()', () async {
      // 1. Save record normally
      await storage.save(
        entity: 'tasks',
        id: 'task-undo-1',
        data: {'title': 'Undoable Task', 'priority': 'urgent'},
      );

      // 2. Delete with 10-second undo window
      final delMut = await storage.delete(
        entity: 'tasks',
        id: 'task-undo-1',
        undoWindow: const Duration(seconds: 10),
      );
      expect(delMut, isNotNull);

      // Record is removed from domain table
      final domainAfterDel = await storage.db.getAll("SELECT * FROM tasks WHERE id = 'task-undo-1';");
      expect(domainAfterDel, isEmpty);

      // 3. User taps Undo before window expires
      final undone = await storage.undoDelete(entity: 'tasks', id: 'task-undo-1');
      expect(undone, isTrue);

      // Domain row is restored
      final domainRestored = await storage.db.getAll("SELECT * FROM tasks WHERE id = 'task-undo-1';");
      expect(domainRestored.length, 1);
      expect(domainRestored.first['title'], 'Undoable Task');

      // Outbox delete mutation is purged, while original create mutation remains pending
      final deleteOutbox = await storage.db.getAll("SELECT * FROM _sync_outbox WHERE entity_id = 'task-undo-1' AND op = 'delete';");
      expect(deleteOutbox, isEmpty);

      final createOutbox = await storage.db.getAll("SELECT * FROM _sync_outbox WHERE entity_id = 'task-undo-1' AND op = 'create';");
      expect(createOutbox.length, 1);
    });

    test('Test Case 9: _sync_id_map & pruneSynced', () async {
      // ID mapping test
      await storage.registerServerId(
        entity: 'tasks',
        localTempId: 'temp-uuid-123',
        canonicalServerId: 'srv-999',
      );

      final resolvedServerId = await storage.getCanonicalServerId(
        entity: 'tasks',
        localTempId: 'temp-uuid-123',
      );
      expect(resolvedServerId, 'srv-999');

      final resolvedTempId = await storage.getLocalTempId(
        entity: 'tasks',
        canonicalServerId: 'srv-999',
      );
      expect(resolvedTempId, 'temp-uuid-123');

      // Prune synced test
      final now = DateTime.now().millisecondsSinceEpoch;
      await storage.db.execute('''
        INSERT INTO _sync_outbox (
          mutation_id, entity_name, entity_id, op, status, created_at, updated_at
        ) VALUES ('synced-old', 'tasks', 't-1', 'create', 'synced', ?, ?)
      ''', [now - 100000000, now - 100000000]);

      final pruned = await storage.pruneSynced(olderThan: const Duration(hours: 1));
      expect(pruned, greaterThanOrEqualTo(1));
    });

    test('Test Case 10: External Host Domain Model (End-to-End Serialization & Query Cycle)', () async {
      // 1. Instantiate external host developer domain models
      final order1 = MockExternalOrder(
        id: 'ord-host-101',
        customerId: 'cust-alpha-99',
        totalAmount: 149.99,
        itemCount: 3,
        isTaxExempt: true,
        metadata: {'priority': 'high', 'notes': 'Leave at door', 'tags': ['fragile', 'expedited']},
        createdAt: DateTime.utc(2026, 10, 25, 12, 0, 0),
      );

      final order2 = MockExternalOrder(
        id: 'ord-host-102',
        customerId: 'cust-beta-44',
        totalAmount: 29.50,
        itemCount: 1,
        isTaxExempt: false,
        metadata: {'notes': 'Standard shipping'},
        createdAt: DateTime.utc(2026, 10, 25, 12, 30, 0),
      );

      // 2. Persist external model instances via toJson()
      await storage.save(
        entity: 'orders',
        id: order1.id,
        data: order1.toJson(),
      );

      await storage.save(
        entity: 'orders',
        id: order2.id,
        data: order2.toJson(),
      );

      // 3. Query local cache using native numeric & boolean operators on custom model fields
      final rows = await storage.db.getAll(
        'SELECT * FROM orders WHERE total_amount > ? AND is_tax_exempt = 1 ORDER BY total_amount DESC;',
        [50.0],
      );

      expect(rows.length, 1);

      // 4. Reconstruct external domain model from database row via fromJson()
      final restored = MockExternalOrder.fromJson(Map<String, dynamic>.from(rows.first));

      expect(restored.id, order1.id);
      expect(restored.customerId, 'cust-alpha-99');
      expect(restored.totalAmount, 149.99);
      expect(restored.itemCount, 3);
      expect(restored.isTaxExempt, isTrue);
      expect(restored.metadata['notes'], 'Leave at door');
      expect(restored.metadata['tags'], equals(['fragile', 'expedited']));
      expect(restored.createdAt, order1.createdAt);

      // 5. Verify outbox payload contains clean external domain format without internal metadata leaks
      final outboxRow = await storage.db.get(
        "SELECT payload_json FROM _sync_outbox WHERE entity_name = 'orders' AND entity_id = ?;",
        [order1.id],
      );
      final outboxPayload = jsonDecode(outboxRow['payload_json'] as String) as Map<String, dynamic>;

      expect(outboxPayload['id'], order1.id);
      expect(outboxPayload['customer_id'], 'cust-alpha-99');
      expect(outboxPayload['total_amount'], 149.99);
      expect(outboxPayload['_base_snapshot_json'], isNull); // zero internal leakage
      expect(outboxPayload['mutation_id'], isNull);

      // 6. Optimistic update of external model captures clean shadow baseline
      final updatedOrder1 = MockExternalOrder(
        id: order1.id,
        customerId: order1.customerId,
        totalAmount: 299.99,
        itemCount: 5,
        isTaxExempt: true,
        metadata: {'notes': 'Upgraded to premium'},
        createdAt: order1.createdAt,
      );

      final updateMutId = await storage.save(
        entity: 'orders',
        id: updatedOrder1.id,
        data: updatedOrder1.toJson(),
        version: 2,
      );

      final updateOutbox = await storage.db.get(
        'SELECT base_snapshot_json, payload_json FROM _sync_outbox WHERE mutation_id = ?;',
        [updateMutId],
      );

      // Pre-mutation baseline captured exactly
      final capturedBase = jsonDecode(updateOutbox['base_snapshot_json'] as String) as Map<String, dynamic>;
      expect(capturedBase['total_amount'], 149.99);
      expect(capturedBase['item_count'], 3);

      // New payload contains updated state
      final newPayload = jsonDecode(updateOutbox['payload_json'] as String) as Map<String, dynamic>;
      expect(newPayload['total_amount'], 299.99);
      expect(newPayload['item_count'], 5);

      // Verify domain cache row preserves data_json container
      final domainRow = await storage.db.get("SELECT data_json FROM orders WHERE id = ?;", [updatedOrder1.id]);
      final storedDataJson = jsonDecode(domainRow['data_json'] as String) as Map<String, dynamic>;
      expect(storedDataJson['total_amount'], 299.99);
      expect(storedDataJson['customer_id'], 'cust-alpha-99');
    });

    test('Test Case 11: Static System Field Validation & Injection Defense', () async {
      // 1. SQL Injection attempt in entity name rejected
      expect(
        () => storage.save(
          entity: 'tasks; DROP TABLE _sync_outbox;',
          id: 'task-inj-1',
          data: {'title': 'Malicious'},
        ),
        throwsA(isA<ArgumentError>()),
      );

      // 2. Empty ID rejected
      expect(
        () => storage.save(
          entity: 'tasks',
          id: '   ',
          data: {'title': 'Empty ID'},
        ),
        throwsA(isA<ArgumentError>()),
      );

      // 3. Negative version rejected
      expect(
        () => storage.save(
          entity: 'tasks',
          id: 'task-neg-ver',
          data: {'title': 'Invalid Version'},
          version: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );

      // 4. Invalid priority rejected
      expect(
        () => storage.save(
          entity: 'tasks',
          id: 'task-bad-pri',
          data: {'title': 'Invalid Priority'},
          priority: 99,
        ),
        throwsA(isA<ArgumentError>()),
      );

      // 5. Negative duration rejected
      expect(
        () => storage.save(
          entity: 'tasks',
          id: 'task-neg-dur',
          data: {'title': 'Negative Duration'},
          holdFor: const Duration(seconds: -5),
        ),
        throwsA(isA<ArgumentError>()),
      );

      // 6. Invalid HTTP method rejected
      expect(
        () => storage.save(
          entity: 'tasks',
          id: 'task-bad-method',
          data: {'title': 'Bad HTTP Method'},
          httpMethod: 'INVALID_VERB',
        ),
        throwsA(isA<ArgumentError>()),
      );

      // 7. Reserved SQL keywords ('order', 'group', 'where') do not cause query syntax errors
      final reservedMutId = await storage.save(
        entity: 'order',
        id: 'ord-reserved-1',
        data: {
          'group': 'vip_customers',
          'where': 'warehouse_north',
          'check': 100,
        },
      );
      expect(reservedMutId, isNotEmpty);
      final reservedRow = await storage.db.get('SELECT * FROM "order" WHERE "id" = ?;', ['ord-reserved-1']);
      expect(reservedRow['group'], 'vip_customers');
      expect(reservedRow['where'], 'warehouse_north');
    });

    test('Test Case 12: TTL Local Cache Expiration & Dirty Record Shielding', () async {
      // 1. Save clean record with short TTL (50ms)
      final cleanMutId = await storage.save(
        entity: 'orders',
        id: 'ord-ttl-clean',
        data: {'item': 'Clean Catalog Item', 'price': 10.0},
        ttl: const Duration(milliseconds: 50),
      );
      // Simulate that this record has already synced to backend (clean cache)
      await storage.db.execute("UPDATE _sync_outbox SET status = 'synced' WHERE mutation_id = ?;", [cleanMutId]);

      // 2. Save dirty offline record with short TTL (50ms)
      await storage.save(
        entity: 'orders',
        id: 'ord-ttl-dirty',
        data: {'item': 'Unsynced Local Draft', 'price': 20.0},
        ttl: const Duration(milliseconds: 50),
      );
      // Status remains 'pending' (dirty offline write)

      // 3. Sleep past TTL expiration
      await Future<void>.delayed(const Duration(milliseconds: 70));

      // 4. Trigger TTL cache pruning
      final prunedCount = await storage.pruneExpiredCache('orders');
      expect(prunedCount, 1);

      // Clean record is evicted from local cache
      final cleanCheck = await storage.db.getAll("SELECT id FROM orders WHERE id = 'ord-ttl-clean';");
      expect(cleanCheck, isEmpty);

      // Dirty record is SHIELDED and remains intact in local cache
      final dirtyCheck = await storage.db.getAll("SELECT id FROM orders WHERE id = 'ord-ttl-dirty';");
      expect(dirtyCheck.length, 1);
      expect(dirtyCheck.first['id'], 'ord-ttl-dirty');
    });

    test('Test Case 13: Foreign Key Cascade Capture on Outbox Deletion', () async {
      // 1. Register parent table 'invoices' and child table 'line_items'
      await storage.registerEntityTable('invoices', {'customer': 'TEXT'});
      await storage.registerEntityTable(
        'line_items',
        {'invoice_id': 'TEXT', 'description': 'TEXT'},
        foreignKeyClause: 'FOREIGN KEY ("invoice_id") REFERENCES "invoices"("id") ON DELETE CASCADE',
      );

      // 2. Save parent invoice and child line items
      await storage.save(
        entity: 'invoices',
        id: 'inv-100',
        data: {'customer': 'Acme Corp'},
      );
      await storage.save(
        entity: 'line_items',
        id: 'item-1',
        data: {'invoice_id': 'inv-100', 'description': 'Widget A'},
      );
      await storage.save(
        entity: 'line_items',
        id: 'item-2',
        data: {'invoice_id': 'inv-100', 'description': 'Widget B'},
      );

      // 3. Delete parent invoice
      final delMut = await storage.delete(entity: 'invoices', id: 'inv-100');
      expect(delMut, isNotNull);

      // 4. Verify parent delete mutation exists in outbox
      final parentOutbox = await storage.db.getAll(
        "SELECT * FROM _sync_outbox WHERE entity_name = 'invoices' AND entity_id = 'inv-100' AND op = 'delete';",
      );
      expect(parentOutbox.length, 1);

      // 5. Verify child cascading delete mutations were automatically captured in outbox
      final childOutbox = await storage.db.getAll(
        "SELECT * FROM _sync_outbox WHERE entity_name = 'line_items' AND op = 'delete' ORDER BY entity_id;",
      );
      expect(childOutbox.length, 2);
      expect(childOutbox[0]['entity_id'], 'item-1');
      expect(childOutbox[1]['entity_id'], 'item-2');
    });

    test('Test Case 14: Database Corruption Quarantine & Auto-Recreation', () async {
      final corruptDbFile = File('${tempDir.path}/corrupt_test.db');
      // Write corrupted garbage bytes into file header
      corruptDbFile.writeAsBytesSync(List.filled(512, 0xFF));

      String? quarantinedPath;
      final recoveredStorage = await SyncStorage.open(
        path: corruptDbFile.path,
        onDatabaseCorrupted: (path) {
          quarantinedPath = path;
        },
      );

      // Quarantine callback invoked
      expect(quarantinedPath, isNotNull);
      expect(File(quarantinedPath!).existsSync(), isTrue);

      // Fresh clean database initialized at original path
      expect(corruptDbFile.existsSync(), isTrue);

      // Operational writes work immediately on fresh database
      final mutId = await recoveredStorage.save(
        entity: 'tasks',
        id: 'task-after-recovery',
        data: {'title': 'Recovered and working'},
      );
      expect(mutId, isNotEmpty);

      await recoveredStorage.close();
    });

    test('Test Case 15: Mocked Cloud Backup Shield & Time-Travel Restore Detection', () async {
      final dbPath = '${tempDir.path}/timetravel_test.db';
      final mockSecureStorage = <String, String>{};
      String? shieldedPath;
      String? detectedMismatchSqlite;
      String? detectedMismatchSecure;

      // 1. Initial boot on Device A: writes matching installation ID
      final storage1 = await SyncStorage.open(
        path: dbPath,
        backupShield: (path) async {
          shieldedPath = path;
          return true;
        },
        secureStorageReader: (k) async => mockSecureStorage[k],
        secureStorageWriter: (k, v) async => mockSecureStorage[k] = v,
      );

      expect(shieldedPath, dbPath);
      expect(mockSecureStorage['orbit_installation_id'], isNotNull);
      final initialId = mockSecureStorage['orbit_installation_id']!;

      // Create an unpushed offline mutation on Device A
      await storage1.save(
        entity: 'tasks',
        id: 'task-time-travel-1',
        data: {'title': 'Old draft from Device A'},
      );

      final outbox1 = await storage1.db.getAll("SELECT status FROM _sync_outbox WHERE entity_id = 'task-time-travel-1';");
      expect(outbox1.first['status'], 'pending');

      await storage1.close();

      // 2. Simulate Cloud Backup Restore to Device B:
      // Device B has a DIFFERENT Keychain/Keystore installation ID (or wiped keychain)
      mockSecureStorage['orbit_installation_id'] = 'device-B-keychain-id-999';

      final storageDeviceB = await SyncStorage.open(
        path: dbPath,
        secureStorageReader: (k) async => mockSecureStorage[k],
        secureStorageWriter: (k, v) async => mockSecureStorage[k] = v,
        onTimeTravelBackupDetected: (sqliteId, secureId) {
          detectedMismatchSqlite = sqliteId;
          detectedMismatchSecure = secureId;
        },
      );

      // Mismatch detected: old SQLite file had initialId, but device B keychain had device-B ID
      expect(detectedMismatchSqlite, initialId);
      expect(detectedMismatchSecure, 'device-B-keychain-id-999');

      // The unpushed pending mutation from the 6-month-old backup was held automatically!
      final outboxDeviceB = await storageDeviceB.db.getAll("SELECT status FROM _sync_outbox WHERE entity_id = 'task-time-travel-1';");
      expect(outboxDeviceB.first['status'], 'held');

      await storageDeviceB.close();
    });

    test('Test Case 16: WAL Checkpointing & Truncate', () async {
      await storage.save(
        entity: 'tasks',
        id: 'task-checkpoint-1',
        data: {'title': 'Checkpoint Task'},
      );

      // Verify passive and truncate checkpoints execute without error
      await storage.checkpoint(truncate: false);
      await storage.checkpoint(truncate: true);
    });

    test('Test Case 17: Chunked Batch Operations (SQLITE_MAX_VARIABLE_NUMBER Defense)', () async {
      final largeIdList = List.generate(1200, (i) => 'id-$i');
      final processedBatches = <int>[];

      await SyncStorage.batchChunked<String>(
        largeIdList,
        chunkSize: 250,
        action: (chunk) async {
          processedBatches.add(chunk.length);
        },
      );

      // 1200 items in chunks of 250: [250, 250, 250, 250, 200] = 5 batches
      expect(processedBatches, equals([250, 250, 250, 250, 200]));
    });

    test('UUIDv7: Generates strictly time-ordered monotonic strings', () {
      final id1 = UuidV7.generate();
      final id2 = UuidV7.generate();
      expect(id1.length, 36);
      expect(id2.length, 36);
      expect(id1.compareTo(id2), lessThanOrEqualTo(0));
      // Version 7 check: 15th character is '7'
      expect(id1[14], '7');
      expect(id2[14], '7');
    });

    test('Test Case 18: Clean Architecture & SOLID Dependency Inversion (Pluggable Repositories)', () async {
      final mockOutbox = _MockOutboxRepo();
      final mockIdMap = _MockIdMapRepo();

      final customStorage = SyncStorage.withRepositories(
        db: storage.db,
        path: ':memory:',
        outboxRepo: mockOutbox,
        idMapRepo: mockIdMap,
      );

      final mutId = await customStorage.save(
        entity: 'tasks',
        id: 'mock-1',
        data: {'name': 'Mock Task'},
      );
      expect(mutId, equals('mock-mutation-id'));
      expect(mockOutbox.saveCalled, isTrue);

      await customStorage.registerServerId(
        entity: 'tasks',
        localTempId: 'temp-1',
        canonicalServerId: 'srv-1',
      );
      expect(mockIdMap.registerCalled, isTrue);
    });
  });
}

/// Realistic domain model defined by an external Flutter app developer.
class MockExternalOrder {
  final String id;
  final String customerId;
  final double totalAmount;
  final int itemCount;
  final bool isTaxExempt;
  final Map<String, dynamic> metadata;
  final DateTime createdAt;

  MockExternalOrder({
    required this.id,
    required this.customerId,
    required this.totalAmount,
    required this.itemCount,
    required this.isTaxExempt,
    required this.metadata,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'customer_id': customerId,
    'total_amount': totalAmount,
    'item_count': itemCount,
    'is_tax_exempt': isTaxExempt,
    'metadata': metadata,
    'created_at_iso': createdAt.toIso8601String(),
  };

  factory MockExternalOrder.fromJson(Map<String, dynamic> json) => MockExternalOrder(
    id: json['id'] as String,
    customerId: json['customer_id'] as String,
    totalAmount: (json['total_amount'] as num).toDouble(),
    itemCount: json['item_count'] as int,
    isTaxExempt: json['is_tax_exempt'] == 1 || json['is_tax_exempt'] == true,
    metadata: json['metadata'] is String
        ? jsonDecode(json['metadata'] as String) as Map<String, dynamic>
        : json['metadata'] as Map<String, dynamic>,
    createdAt: DateTime.parse(json['created_at_iso'] as String),
  );
}

class _MockOutboxRepo implements IOutboxRepository {
  bool saveCalled = false;

  @override
  Future<String> save({
    required String entity,
    required String id,
    required Map<String, dynamic> data,
    int version = 1,
    String? dependsOnMutationId,
    int schemaVersion = 1,
    String? endpointUrl,
    String? httpMethod,
    Duration? holdFor,
    Duration? sla,
    Duration? ttl,
    int priority = 0,
    String? correlationTag,
  }) async {
    saveCalled = true;
    return 'mock-mutation-id';
  }

  @override
  Future<String?> delete({
    required String entity,
    required String id,
    String? endpointUrl,
    String? httpMethod,
    Duration? undoWindow,
  }) async => null;

  @override
  Future<bool> undoDelete({required String entity, required String id}) async => true;

  @override
  Future<void> rollbackOptimistic(String mutationId, {String status = 'conflict'}) async {}

  @override
  Future<int> pruneSynced({Duration olderThan = const Duration(days: 7)}) async => 0;

  @override
  Future<int> pruneExpiredCache(String entity) async => 0;

  @override
  Future<void> registerEntityTable(
    String entityName,
    Map<String, String> columnTypes, {
    String? foreignKeyClause,
  }) async {}

  @override
  Future<ResultSet> query(String query, [List<dynamic> parameters = const []]) async =>
      throw UnimplementedError();

  @override
  Stream<ResultSet> watch(String query, {List<dynamic> parameters = const []}) =>
      const Stream.empty();

  @override
  Future<void> checkpoint({bool truncate = false}) async {}

  @override
  Future<void> close() async {}
}

class _MockIdMapRepo implements IIdMapRepository {
  bool registerCalled = false;

  @override
  Future<void> registerServerId({
    required String entity,
    required String localTempId,
    required String canonicalServerId,
  }) async {
    registerCalled = true;
  }

  @override
  Future<String?> getCanonicalServerId({
    required String entity,
    required String localTempId,
  }) async => 'mock-canonical-id';

  @override
  Future<String?> getLocalTempId({
    required String entity,
    required String canonicalServerId,
  }) async => 'mock-temp-id';
}
