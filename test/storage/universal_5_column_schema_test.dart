import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'package:orbit_sync/src/storage/infrastructure/sqlite/sqlite_baseline_manager.dart';
import 'storage_test_helpers.dart';

void main() {
  group('Ticket 02: Universal 5-Column Storage A Schema & Zero-DDL Cleanup', () {
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

    test('1. Every registered collection table creates strictly 5 columns', () async {
      // Register entity with pseudo columnTypes (should be ignored for physical DDL)
      await storage.registerEntityTable('products', {
        'name': 'TEXT',
        'price': 'REAL',
        'is_available': 'INTEGER',
      });

      final tableInfo = await storage.db.getAll('PRAGMA table_info("products");');
      final columnNames = tableInfo.map((row) => row['name'] as String).toSet();

      // Must have strictly the 5 universal columns
      expect(
        columnNames,
        equals({'id', 'version', 'updated_at', 'expires_at', 'data_json'}),
      );
      expect(columnNames.length, equals(5));

      // Check definitions of the 5 columns
      final idCol = tableInfo.firstWhere((r) => r['name'] == 'id');
      expect(idCol['pk'], equals(1));
      expect(idCol['type'], equals('TEXT'));

      final verCol = tableInfo.firstWhere((r) => r['name'] == 'version');
      expect(verCol['notnull'], equals(1));
      expect(verCol['dflt_value'], equals('1'));
      expect(verCol['type'], equals('INTEGER'));

      final updatedCol = tableInfo.firstWhere((r) => r['name'] == 'updated_at');
      expect(updatedCol['notnull'], equals(1));
      expect(updatedCol['type'], equals('INTEGER'));

      final expiresCol = tableInfo.firstWhere((r) => r['name'] == 'expires_at');
      expect(expiresCol['notnull'], equals(0));
      expect(expiresCol['type'], equals('INTEGER'));

      final dataCol = tableInfo.firstWhere((r) => r['name'] == 'data_json');
      expect(dataCol['notnull'], equals(1));
      expect(dataCol['dflt_value'], equals("'{}'"));
      expect(dataCol['type'], equals('TEXT'));

      // Ensure dynamic columns and _base_snapshot_json do NOT exist
      expect(columnNames.contains('_base_snapshot_json'), isFalse);
      expect(columnNames.contains('name'), isFalse);
      expect(columnNames.contains('price'), isFalse);
      expect(columnNames.contains('is_available'), isFalse);
    });

    test('2. Dynamic table auto-creation via ensureEntityTableExists creates 5 columns', () async {
      // Saving to an unregistered table triggers ensureEntityTableExists
      await storage.save(
        entity: 'categories',
        id: 'cat-1',
        data: {'title': 'Electronics', 'department': 'Retail'},
      );

      final tableInfo = await storage.db.getAll('PRAGMA table_info("categories");');
      final columnNames = tableInfo.map((row) => row['name'] as String).toSet();

      expect(
        columnNames,
        equals({'id', 'version', 'updated_at', 'expires_at', 'data_json'}),
      );
      expect(columnNames.contains('_base_snapshot_json'), isFalse);
      expect(columnNames.contains('title'), isFalse);
    });

    test('3. Verify the 2 system indexes exist and are query-plannable', () async {
      await storage.registerEntityTable('inventory', {});

      final indexes = await storage.db.getAll(
        "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'inventory';",
      );
      final indexNames = indexes.map((row) => row['name'] as String).toSet();

      expect(indexNames, contains('idx_inventory_updated'));
      expect(indexNames, contains('idx_inventory_expires'));

      // Verify query plan on idx_inventory_updated (Reverse Recency Index)
      final qpUpdated = await storage.db.getAll(
        'EXPLAIN QUERY PLAN SELECT * FROM "inventory" ORDER BY updated_at DESC;',
      );
      final detailUpdated = qpUpdated.map((r) => r['detail'].toString()).join(' ');
      expect(detailUpdated, contains('idx_inventory_updated'));

      // Verify query plan on idx_inventory_expires (Partial TTL Eviction Index)
      final qpExpires = await storage.db.getAll(
        'EXPLAIN QUERY PLAN SELECT id FROM "inventory" WHERE expires_at IS NOT NULL AND expires_at < 999999999;',
      );
      final detailExpires = qpExpires.map((r) => r['detail'].toString()).join(' ');
      expect(detailExpires, contains('idx_inventory_expires'));
    });

    test('4. Saving complex nested JSON documents stores them purely into data_json', () async {
      await storage.registerEntityTable('complex_orders', {});

      final nestedPayload = {
        'order_number': 'ORD-2026-X',
        'customer': {
          'id': 'cust-88',
          'profile': {'firstName': 'Jane', 'lastName': 'Doe'},
          'addresses': [
            {'type': 'shipping', 'city': 'Zurich', 'zip': '8001'},
            {'type': 'billing', 'city': 'Geneva', 'zip': '1201'},
          ],
        },
        'line_items': [
          {'sku': 'ITEM-A', 'quantity': 2, 'unit_price': 49.50},
          {'sku': 'ITEM-B', 'quantity': 1, 'unit_price': 199.00},
        ],
        'flags': {'is_gift': true, 'requires_signature': false},
        'tags': ['priority', 'fragile', 'vip'],
      };

      final mutId = await storage.save(
        entity: 'complex_orders',
        id: 'ord-nested-1',
        data: nestedPayload,
        version: 1,
      );
      expect(mutId, isNotEmpty);

      final row = await storage.db.get('SELECT * FROM "complex_orders" WHERE "id" = ?;', ['ord-nested-1']);
      expect(row.keys.toSet(), equals({'id', 'version', 'updated_at', 'expires_at', 'data_json'}));
      expect(row['id'], equals('ord-nested-1'));
      expect(row['version'], equals(1));
      expect(row['expires_at'], isNull);

      final decoded = jsonDecode(row['data_json'] as String) as Map<String, dynamic>;
      expect(decoded['order_number'], equals('ORD-2026-X'));
      expect(decoded['customer']['profile']['firstName'], equals('Jane'));
      expect((decoded['customer']['addresses'] as List).length, equals(2));
      expect((decoded['line_items'] as List).length, equals(2));
      expect(decoded['flags']['is_gift'], isTrue);
      expect(decoded['tags'], equals(['priority', 'fragile', 'vip']));

      // Confirm outbox received the identical clean payload
      final outboxRow = await storage.db.get(
        'SELECT payload_json, base_snapshot_json FROM _sync_outbox WHERE mutation_id = ?;',
        [mutId],
      );
      final outboxPayload = jsonDecode(outboxRow['payload_json'] as String) as Map<String, dynamic>;
      expect(outboxPayload['order_number'], equals('ORD-2026-X'));
      expect(outboxRow['base_snapshot_json'], isNull);
    });

    test('5. Baseline manager and optimistic rollback read from data_json', () async {
      await storage.registerEntityTable('documents', {});

      final initialDoc = {
        'title': 'Original Doc',
        'sections': [
          {'header': 'Intro', 'body': 'Hello world'},
        ],
        'version_tag': 'v1.0',
      };

      await storage.save(
        entity: 'documents',
        id: 'doc-1',
        data: initialDoc,
        version: 1,
      );

      // Verify readExistingBaseline reads directly from data_json
      await storage.db.writeTransaction((tx) async {
        final baseline = await SqliteBaselineManager.readExistingBaseline(tx, 'documents', 'doc-1');
        expect(baseline.version, equals(1));
        final baselineData = jsonDecode(baseline.snapshot!) as Map<String, dynamic>;
        expect(baselineData['title'], equals('Original Doc'));
        expect(baselineData['sections'][0]['header'], equals('Intro'));
      });

      // Mutate document
      final updatedDoc = {
        'title': 'Updated Doc',
        'sections': [
          {'header': 'Intro', 'body': 'Hello modified world'},
          {'header': 'Conclusion', 'body': 'Summary here'},
        ],
        'version_tag': 'v2.0',
      };

      final mut2 = await storage.save(
        entity: 'documents',
        id: 'doc-1',
        data: updatedDoc,
        version: 2,
      );

      // Verify domain row reflects update
      final modifiedRow = await storage.db.get('SELECT * FROM "documents" WHERE "id" = ?;', ['doc-1']);
      expect(modifiedRow['version'], equals(2));
      final modData = jsonDecode(modifiedRow['data_json'] as String) as Map<String, dynamic>;
      expect(modData['title'], equals('Updated Doc'));

      // Rollback optimistic mutation
      await storage.rollbackOptimistic(mut2, status: 'conflict');

      // Verify restored domain row matches original baseline from data_json
      final restoredRow = await storage.db.get('SELECT * FROM "documents" WHERE "id" = ?;', ['doc-1']);
      expect(restoredRow['version'], equals(1));
      final restoredData = jsonDecode(restoredRow['data_json'] as String) as Map<String, dynamic>;
      expect(restoredData['title'], equals('Original Doc'));
      expect(restoredData['sections'][0]['body'], equals('Hello world'));
      expect((restoredData['sections'] as List).length, equals(1));
    });

    test('6. Zero-DDL: saving arbitrary dynamic fields never alters table schema', () async {
      await storage.registerEntityTable('flexible_records', {});

      // Step 1: Save first shape
      await storage.save(
        entity: 'flexible_records',
        id: 'rec-1',
        data: {'alpha': 1, 'beta': 'two'},
      );

      // Step 2: Save completely different shape with 10 new fields
      await storage.save(
        entity: 'flexible_records',
        id: 'rec-2',
        data: {
          'gamma': [1, 2, 3],
          'delta': {'nested': true},
          'epsilon': 'new_field',
          'zeta': 99.9,
        },
      );

      // Table schema must remain strictly 5 columns without schema drift
      final tableInfo = await storage.db.getAll('PRAGMA table_info("flexible_records");');
      expect(tableInfo.length, equals(5));
      final columnNames = tableInfo.map((r) => r['name'] as String).toSet();
      expect(
        columnNames,
        equals({'id', 'version', 'updated_at', 'expires_at', 'data_json'}),
      );
    });
  });
}
