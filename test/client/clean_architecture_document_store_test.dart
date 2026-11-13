import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

void main() {
  late String dbPath;
  late OrbitClient client;
  late InMemorySyncTransport transport;

  setUp(() async {
    dbPath = '${Directory.systemTemp.path}/clean_arch_test_${DateTime.now().microsecondsSinceEpoch}.db';
    transport = SyncTransport.inMemory() as InMemorySyncTransport;

    client = await OrbitClient.initialize(
      databasePath: dbPath,
      baseUrl: 'https://api.corp.example',
      transport: transport,
    );
  });

  tearDown(() async {
    await client.close();
    final f = File(dbPath);
    if (await f.exists()) await f.delete();
  });

  group('Clean Architecture Document Store & Zero Metadata Wire', () {
    test('1. Pure Payload & Auto-generated Tracking ID: zero ID in payload_json', () async {
      // Host app registers table once at startup with URL
      final orders = client.collection<Map<String, dynamic>>(
        name: 'orders',
        endpoint: '/api/v1/orders',
        fromJson: (j) => j,
        toJson: (j) => j,
      );

      // Host app saves pure JSON with NO ID and NO URL
      final internalId = await orders.save({
        'items': [{'title': 'MacBook Pro', 'price': 2499.00}],
        'total': 2499.00,
      });

      expect(internalId, isNotEmpty);

      // Verify _sync_outbox row
      final rows = await client.query('SELECT * FROM _sync_outbox WHERE entity_name = ?', ['orders']);
      expect(rows.length, equals(1));
      final outboxRow = rows.first;

      expect(outboxRow['entity_id'], equals(internalId));
      expect(outboxRow['endpoint_url'], endsWith('/api/v1/orders')); // URL auto-inherited!
      expect(outboxRow['status'], equals('pending'));

      // Crucial: payload_json must be 100% pure host-app data with ZERO injected 'id' or 'temp_id'!
      final payload = jsonDecode(outboxRow['payload_json'] as String) as Map<String, dynamic>;
      expect(payload.containsKey('id'), isFalse);
      expect(payload.containsKey('temp_id'), isFalse);
      expect(payload.containsKey('_offline_meta'), isFalse);
      expect(payload['total'], equals(2499.00));
    });

    test('2. Zero Relational Columns: table stores pure JSON in data_json without ALTER TABLE bloat', () async {
      client.collection<Map<String, dynamic>>(
        name: 'invoices',
        endpoint: '/api/v1/invoices',
        fromJson: (j) => j,
        toJson: (j) => j,
      );

      // Save an invoice with multiple nested fields
      await client.store('invoices', {
        'client_name': 'Acme Corp',
        'due_date': '2026-11-15',
        'amount': 2499.00,
        'currency': 'USD',
        'details': {'tax_rate': 0.05, 'terms': 'Net-30'},
      });

      // Inspect SQLite table pragma
      final pragmaRows = await client.query('PRAGMA table_info("invoices")');
      final columnNames = pragmaRows.map((r) => r['name'] as String).toSet();

      // Table must strictly contain only system columns:
      expect(columnNames.contains('id'), isTrue);
      expect(columnNames.contains('data_json'), isTrue);
      expect(columnNames.contains('version'), isTrue);

      // Must NOT contain relational columns dynamically added for each field!
      expect(columnNames.contains('client_name'), isFalse);
      expect(columnNames.contains('due_date'), isFalse);
      expect(columnNames.contains('amount'), isFalse);
      expect(columnNames.contains('details'), isFalse);
    });

    test('3. In-place Outbox Mutation Coalescing & Revision History', () async {
      final orders = client.collection<Map<String, dynamic>>(
        name: 'orders',
        endpoint: '/api/v1/orders',
        fromJson: (j) => j,
        toJson: (j) => j,
      );

      // 1. Initial creation with grace window (coalescing enabled)
      final orderId = await orders.save({
        'items': [{'title': 'MacBook Pro', 'price': 2499.00}],
        'total': 2499.00,
      }, holdFor: const Duration(minutes: 5));

      // 2. Edit 2 minutes later while still offline
      await orders.save({
        'items': [
          {'title': 'MacBook Pro', 'price': 2499.00},
          {'title': 'Magic Mouse', 'price': 99.00},
        ],
        'total': 2598.00,
      }, id: orderId);

      // Verify outbox STILL has only 1 row (coalesced!)
      final rows = await client.query('SELECT * FROM _sync_outbox WHERE entity_name = ?', ['orders']);
      expect(rows.length, equals(1));

      final outboxRow = rows.first;
      final payload = jsonDecode(outboxRow['payload_json'] as String) as Map<String, dynamic>;
      expect(payload['total'], equals(2598.00)); // Latest state

      // Verify revision_history_json holds original snapshot
      expect(outboxRow['revision_history_json'], isNotNull);
      final history = jsonDecode(outboxRow['revision_history_json'] as String) as List<dynamic>;
      expect(history.length, equals(1));
      final previousSnapshot = history.first['snapshot'] as Map<String, dynamic>;
      expect(previousSnapshot['total'], equals(2499.00)); // Original snapshot
    });

    test('4. Transparent WHERE Rewriting on data_json and Pagination', () async {
      final orders = client.collection<Map<String, dynamic>>(
        name: 'orders',
        endpoint: '/api/v1/orders',
        fromJson: (j) => j,
        toJson: (j) => j,
      );

      // Insert 3 orders
      await orders.save({'title': 'Order A', 'total': 50.00, 'status': 'completed'});
      await orders.save({'title': 'Order B', 'total': 500.00, 'status': 'pending'});
      await orders.save({'title': 'Order C', 'total': 1200.00, 'status': 'pending'});

      // Query using simple Dart where syntax (auto-rewritten to json_extract)
      final pendingOrders = await orders.query(
        where: 'status = ?',
        whereArgs: ['pending'],
        orderBy: 'total DESC',
      );

      expect(pendingOrders.length, equals(2));
      expect(pendingOrders[0]['title'], equals('Order C'));
      expect(pendingOrders[1]['title'], equals('Order B'));

      // Pagination with limit
      final paginated = await orders.query(
        where: 'total > ?',
        whereArgs: [100.00],
        limit: 1,
      );
      expect(paginated.length, equals(1));
    });

    test('5. Zero Guessing Server ID Swap: custom idExtractor harvests canonical ID', () async {
      // Configure with custom backend ID key: 'invoice_number'
      final invoices = client.collection<Map<String, dynamic>>(
        name: 'invoices',
        endpoint: '/api/v1/invoices',
        fromJson: (j) => j,
        toJson: (j) => j,
        idExtractor: (json) => (json as Map)['invoice_number'] as String?,
      );

      final tempId = await invoices.save({
        'client': 'Acme',
        'amount': 500.00,
      });
      expect(tempId, isNotEmpty);

      // Prepare canned server response with non-standard ID key
      transport.pushStatusCode = 201;
      transport.pushResponseBody = jsonEncode({
        'invoice_number': 'INV-2026-9999',
        'status': 'created',
      });

      // Sync
      await client.sync();

      // Verify local domain table ID was swapped from tempId -> INV-2026-9999!
      final invoiceInDb = await invoices.get('INV-2026-9999');
      expect(invoiceInDb, isNotNull);
      expect(invoiceInDb!['client'], equals('Acme'));

      // Outbox marked synced
      final outboxRows = await client.query('SELECT status, entity_id FROM _sync_outbox WHERE entity_name = ?', ['invoices']);
      expect(outboxRows.first['status'], equals('synced'));
      expect(outboxRows.first['entity_id'], equals('INV-2026-9999'));
    });
  });
}
