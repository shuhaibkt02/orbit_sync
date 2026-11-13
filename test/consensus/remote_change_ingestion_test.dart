import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'package:orbit_sync/src/consensus/services/pull_change_applier.dart';
import 'package:orbit_sync/src/consensus/services/generation_swap_manager.dart';
import 'package:orbit_sync/src/consensus/services/conflict_reconciler.dart';
import 'package:sync_server/sync_server.dart';

void main() {
  group('Ticket 14: Universal 5-Column Remote Change Ingestion & Generation Swap', () {
    late Directory tempDir;
    late SyncStorage storage;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('remote_ingest_test_');
      storage = await SyncStorage.open(path: '${tempDir.path}/test.db', maxReaders: 2);
    });

    tearDown(() async {
      await storage.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('1. Remote Pull Change Ingestion writes clean nested JSON to data_json without dynamic DDL', () async {
      await storage.registerEntityTable('orders', {});

      // Verify clean 5-column table exists initially
      final initialCols = await storage.db.getAll('PRAGMA table_info("orders");');
      expect(
        initialCols.map((c) => c['name'] as String).toSet(),
        equals({'id', 'version', 'updated_at', 'expires_at', 'data_json'}),
      );

      final reconciler = ConflictReconciler();
      final applier = PullChangeApplier(
        profile: SyncProfile.enterprise,
        reconciler: reconciler,
      );

      // Deeply nested enterprise order record
      final nestedOrder = {
        'order_number': 'ORD-2026-99',
        'customer': {
          'name': 'Jane Doe',
          'address': {
            'city': 'San Francisco',
            'state': 'CA',
            'zip': '94107',
          },
        },
        'items': [
          {'sku': 'WIDGET-1', 'qty': 2, 'price': 19.99},
          {'sku': 'GADGET-2', 'qty': 1, 'price': 99.50},
        ],
        'metadata': {
          'channel': 'mobile_app',
          'tags': ['vip', 'rush'],
        },
      };

      final expiresAt = DateTime.now().millisecondsSinceEpoch + 3600000;

      await storage.db.writeTransaction((tx) async {
        await applier.processChange(tx, {
          'entity': 'orders',
          'id': 'ord-101',
          'version': 3,
          'expires_at': expiresAt,
          '_deleted': false,
          'data': nestedOrder,
        });
      });

      // 1. Verify PRAGMA table_info strictly maintains the 5 universal columns (ZERO dynamic DDL)
      final tableInfo = await storage.db.getAll('PRAGMA table_info("orders");');
      final colNames = tableInfo.map((c) => c['name'] as String).toSet();
      expect(
        colNames,
        equals({'id', 'version', 'updated_at', 'expires_at', 'data_json'}),
      );
      expect(colNames.contains('_base_snapshot_json'), isFalse);
      expect(colNames.contains('order_number'), isFalse);
      expect(colNames.contains('customer'), isFalse);
      expect(colNames.contains('items'), isFalse);
      expect(colNames.contains('metadata'), isFalse);

      // 2. Verify row content in universal 5-column table
      final row = await storage.db.get('SELECT * FROM orders WHERE id = ?;', ['ord-101']);
      expect(row['id'], equals('ord-101'));
      expect(row['version'], equals(3));
      expect(row['expires_at'], equals(expiresAt));
      expect(row['updated_at'], isNotNull);

      // 3. Verify nested JSON content parsed from data_json
      final dataMap = jsonDecode(row['data_json'] as String) as Map<String, dynamic>;
      expect(dataMap['order_number'], equals('ORD-2026-99'));
      expect(dataMap['customer']['name'], equals('Jane Doe'));
      expect(dataMap['customer']['address']['city'], equals('San Francisco'));
      expect(dataMap['items'], hasLength(2));
      expect(dataMap['items'][0]['sku'], equals('WIDGET-1'));
      expect(dataMap['metadata']['tags'], equals(['vip', 'rush']));

      // 4. Update the same record with higher version via upsert
      (nestedOrder['customer'] as Map<String, dynamic>)['name'] = 'Jane Smith';
      await storage.db.writeTransaction((tx) async {
        await applier.processChange(tx, {
          'entity': 'orders',
          'id': 'ord-101',
          'version': 4,
          '_deleted': false,
          'data': nestedOrder,
        });
      });

      final updatedRow = await storage.db.get('SELECT * FROM orders WHERE id = ?;', ['ord-101']);
      expect(updatedRow['version'], equals(4));
      final updatedData = jsonDecode(updatedRow['data_json'] as String) as Map<String, dynamic>;
      expect(updatedData['customer']['name'], equals('Jane Smith'));

      // 5. Delete tombstone removes row
      await storage.db.writeTransaction((tx) async {
        await applier.processChange(tx, {
          'entity': 'orders',
          'id': 'ord-101',
          '_deleted': true,
        });
      });

      final deletedRow = await storage.db.getOptional('SELECT * FROM orders WHERE id = ?;', ['ord-101']);
      expect(deletedRow, isNull);
    });

    test('2. Generation Swap (HTTP 410) creates 5-column staging table, swaps atomically, and reapplies unpushed outbox mutations', () async {
      final server = await FakeSyncServer.start(port: 0);
      try {
        await storage.registerEntityTable('products', {});

        // Pre-populate old generation table with stale records that were previously synced
        for (var i = 1; i <= 3; i++) {
          await storage.save(
            entity: 'products',
            id: 'prod-$i',
            data: {'name': 'Old Product $i', 'price': i * 10},
          );
        }
        await storage.db.execute("UPDATE _sync_outbox SET status = 'synced' WHERE entity_name = 'products';");

        // Add a local unpushed mutation (dirty draft)
        final unpushedMutId = await storage.save(
          entity: 'products',
          id: 'prod-offline-draft',
          data: {
            'name': 'Offline Created Product',
            'price': 999,
            'details': {'specs': 'Waterproof', 'warranty_years': 5},
          },
        );

        // Configure server with fresh generation snapshot (e.g. prod-1 updated, prod-2 deleted, prod-fresh added)
        server.records['products:prod-1'] = {'name': 'Server Product 1 (Gen 2)', 'price': 15};
        server.records['products:prod-fresh'] = {
          'name': 'New Remote Product',
          'price': 250,
          'category': {'dept': 'Hardware', 'tier': 'Pro'},
        };
        server.cursor = 200;

        final transport = SyncTransport.http(baseUrl: server.baseUrl);
        final swapManager = GenerationSwapManager(storage: storage, transport: transport);

        // Execute generation swap
        final swapOk = await swapManager.resyncGeneration(['products']);
        expect(swapOk, isTrue);

        // 1. Verify PRAGMA table_info on swapped active table has strictly 5 columns
        final tableInfo = await storage.db.getAll('PRAGMA table_info("products");');
        expect(
          tableInfo.map((c) => c['name'] as String).toSet(),
          equals({'id', 'version', 'updated_at', 'expires_at', 'data_json'}),
        );

        // 2. Verify staging table _staging_products was dropped/renamed and no longer exists
        final stagingCheck = await storage.db.getAll(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '_staging_products';",
        );
        expect(stagingCheck, isEmpty);

        // 3. Verify system indexes exist after table swap
        final indexes = await storage.db.getAll(
          "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'products';",
        );
        final indexNames = indexes.map((r) => r['name'] as String).toSet();
        expect(indexNames, contains('idx_products_updated'));
        expect(indexNames, contains('idx_products_expires'));

        // 4. Verify remote fresh records are present
        final freshRow = await storage.db.getOptional("SELECT * FROM products WHERE id = 'prod-fresh';");
        expect(freshRow, isNotNull);
        final freshData = jsonDecode(freshRow!['data_json'] as String) as Map<String, dynamic>;
        expect(freshData['name'], equals('New Remote Product'));
        expect(freshData['category']['dept'], equals('Hardware'));

        // Stale record prod-2 should be gone
        final staleRow = await storage.db.getOptional("SELECT * FROM products WHERE id = 'prod-2';");
        expect(staleRow, isNull);

        // 5. Verify unpushed local dirty mutation prod-offline-draft was cleanly reapplied on top of swapped table
        final offlineRow = await storage.db.getOptional("SELECT * FROM products WHERE id = 'prod-offline-draft';");
        expect(offlineRow, isNotNull);
        final offlineData = jsonDecode(offlineRow!['data_json'] as String) as Map<String, dynamic>;
        expect(offlineData['name'], equals('Offline Created Product'));
        expect(offlineData['price'], equals(999));
        expect(offlineData['details']['specs'], equals('Waterproof'));

        // Verify outbox mutation is still pending
        final outboxEntry = await storage.db.get(
          'SELECT status FROM _sync_outbox WHERE mutation_id = ?;',
          [unpushedMutId],
        );
        expect(outboxEntry['status'], equals('pending'));

        // 6. Verify cursor checkpoint was updated to 200
        final metaCursor = await storage.db.get(
          "SELECT value FROM _sync_metadata WHERE key = 'last_synced_cursor';",
        );
        expect(metaCursor['value'], equals('200'));

        transport.dispose();
      } finally {
        await server.stop();
      }
    });

    test('3. 3-Way Merge Conflict Resolution on 5-Column Nested Records using DeepCollectionEquality', () async {
      await storage.registerEntityTable('documents', {});

      final reconciler = ConflictReconciler();
      final applier = PullChangeApplier(
        profile: SyncProfile.enterprise,
        reconciler: reconciler,
      );

      // Base snapshot
      final baseData = {
        'title': 'Original Architecture Doc',
        'content': 'Section 1 content',
        'metadata': {
          'tags': ['offline', 'sync'],
          'author': {'name': 'Alice', 'role': 'Lead'},
        },
      };

      // 1. Setup base state in SQLite
      await storage.db.writeTransaction((tx) async {
        await PullChangeApplier.upsertRow(
          tx,
          'documents',
          'doc-1',
          baseData,
          1,
          DateTime.now().millisecondsSinceEpoch,
        );
      });

      // 2. User locally modifies tags and adds notes (local change)
      final localData = {
        'title': 'Original Architecture Doc', // unchanged locally
        'content': 'Section 1 content',      // unchanged locally
        'metadata': {
          'tags': ['offline', 'sync', 'crdt'], // modified locally
          'author': {'name': 'Alice', 'role': 'Lead'},
        },
        'local_notes': 'Verified on iPad',   // added locally
      };

      final mutId = await storage.save(
        entity: 'documents',
        id: 'doc-1',
        data: localData,
        version: 1,
      );

      // 3. Concurrently, remote server modified title and content (remote change), but left metadata unchanged
      final remoteData = {
        'title': 'Universal Architecture Specification', // changed remotely
        'content': 'Updated Section 1 with diagrams',   // changed remotely
        'metadata': {
          'tags': ['offline', 'sync'],                 // unchanged on server
          'author': {'name': 'Alice', 'role': 'Lead'},
        },
      };

      // 4. Process remote change through PullChangeApplier
      await storage.db.writeTransaction((tx) async {
        await applier.processChange(tx, {
          'entity': 'documents',
          'id': 'doc-1',
          'version': 2,
          '_deleted': false,
          'data': remoteData,
        });
      });

      // 5. Verify 3-way merge result in domain table data_json
      final mergedRow = await storage.db.get('SELECT * FROM documents WHERE id = ?;', ['doc-1']);
      expect(mergedRow['version'], equals(2));
      final mergedJson = jsonDecode(mergedRow['data_json'] as String) as Map<String, dynamic>;

      // Remote changes accepted:
      expect(mergedJson['title'], equals('Universal Architecture Specification'));
      expect(mergedJson['content'], equals('Updated Section 1 with diagrams'));

      // Local changes preserved via DeepCollectionEquality:
      expect(mergedJson['metadata']['tags'], equals(['offline', 'sync', 'crdt']));
      expect(mergedJson['local_notes'], equals('Verified on iPad'));

      // 6. Verify _sync_outbox was updated with merged payload ready to re-push
      final updatedOutbox = await storage.db.get(
        'SELECT status, payload_json, base_snapshot_json, base_version FROM _sync_outbox WHERE mutation_id = ?;',
        [mutId],
      );
      expect(updatedOutbox['status'], equals('pending'));
      expect(updatedOutbox['base_version'], equals(2));

      final outboxPayload = jsonDecode(updatedOutbox['payload_json'] as String) as Map<String, dynamic>;
      expect(outboxPayload['title'], equals('Universal Architecture Specification'));
      expect(outboxPayload['metadata']['tags'], equals(['offline', 'sync', 'crdt']));
      expect(outboxPayload['local_notes'], equals('Verified on iPad'));

      final outboxBase = jsonDecode(updatedOutbox['base_snapshot_json'] as String) as Map<String, dynamic>;
      expect(outboxBase['title'], equals('Universal Architecture Specification'));
    });
  });
}
