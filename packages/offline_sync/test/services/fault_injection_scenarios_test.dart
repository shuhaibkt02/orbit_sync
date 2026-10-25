import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:offline_sync/offline_sync.dart';
import '../harness/transport/fault.dart';
import '../harness/transport/fault_injection_http_client.dart';
import '../harness/server/scripted_batch.dart';

void main() {
  group('Fault Injection Test Harness & Deterministic Scenarios', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('fault_harness_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('Scenario 1: Partial batch success (Items 1 & 3 sync, Item 2 quarantined on 422)', () async {
      final server = await ScriptedBatchServer.start();
      server.scriptAll([
        const Accept('wo-1'),
        const Reject('wo-2', status: HttpStatus.unprocessableEntity, reason: 'Warehouse 49 closed'),
        const Accept('wo-3'),
      ]);

      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/partial_batch.db',
      );
      await client.registerEntity('work_orders', url: server.url);

      // Store 3 work orders offline
      await client.store('work_orders', {'title': 'Fix generator'}, id: 'wo-1');
      await client.store('work_orders', {'title': 'Inspect furnace'}, id: 'wo-2');
      await client.store('work_orders', {'title': 'Replace filters'}, id: 'wo-3');

      // Sync batch
      await client.sync();

      // Assert independent outbox statuses
      final outbox1 = await client.query('SELECT status FROM _sync_outbox WHERE entity_id = ?', ['wo-1']);
      final outbox2 = await client.query('SELECT status, error_details_json FROM _sync_outbox WHERE entity_id = ?', ['wo-2']);
      final outbox3 = await client.query('SELECT status FROM _sync_outbox WHERE entity_id = ?', ['wo-3']);

      expect(outbox1.first['status'], equals('synced'));
      expect(outbox2.first['status'], equals('validation_error'));
      expect(outbox3.first['status'], equals('synced'));

      // Active table: wo-2 must be rolled back, while wo-1 and wo-3 remain active
      final activeWo1 = await client.restoreById('work_orders', 'wo-1');
      final activeWo2 = await client.restoreById('work_orders', 'wo-2');
      final activeWo3 = await client.restoreById('work_orders', 'wo-3');

      expect(activeWo1, isNotNull);
      expect(activeWo2, isNull, reason: 'Rejected item must be rolled back from active domain table');
      expect(activeWo3, isNotNull);

      // Verify typed failure transparency
      final failures = await client.getFailures();
      expect(failures, hasLength(1));
      expect(failures.first.recordId, equals('wo-2'));
      expect(failures.first.statusCode, equals(422));
      expect(failures.first.errorMessage, contains('Warehouse 49 closed'));

      await client.close();
      await server.close();
    });

    test('Scenario 2: 10 MB payload survives outbox write + sync', () async {
      int receivedBodyBytes = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        final bodyBytes = await req.fold<List<int>>([], (prev, element) => prev..addAll(element));
        receivedBodyBytes = bodyBytes.length;
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'status': 'ok'}));
        await req.response.close();
      });

      final targetUrl = 'http://${server.address.address}:${server.port}/api/attachments';
      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/large_payload.db',
      );
      await client.registerEntity('attachments', url: targetUrl);

      // Generate 10 MB payload
      const tenMb = 10 * 1024 * 1024;
      final largeData = 'A' * tenMb;

      // Store in offline database
      final attId = await client.store('attachments', {
        'filename': 'dump.bin',
        'data': largeData,
      });

      // Verify outbox has written and persisted the 10 MB payload to SQLite disk
      final outboxRows = await client.query('SELECT status, payload_json FROM _sync_outbox WHERE entity_id = ?', [attId]);
      expect(outboxRows.first['status'], equals('pending'));
      expect((outboxRows.first['payload_json'] as String).length, greaterThan(tenMb));

      // Sync 10 MB payload over the wire
      await client.sync();

      expect(receivedBodyBytes, greaterThan(tenMb));
      final syncedRows = await client.query('SELECT status FROM _sync_outbox WHERE entity_id = ?', [attId]);
      expect(syncedRows.first['status'], equals('synced'));

      await client.close();
      await server.close();
    });

    test('Scenario 3: Two Generals (Server commits, socket drops before ACK, retry is idempotent)', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverHits = <String, int>{};
      final idempotencyCache = <String, String>{};

      server.listen((HttpRequest req) async {
        final idempotencyKey = req.headers.value('Idempotency-Key') ?? '';
        final bodyStr = await utf8.decoder.bind(req).join();
        final body = bodyStr.isNotEmpty ? (jsonDecode(bodyStr) as Map<String, dynamic>) : <String, dynamic>{};
        final id = (body['id'] as String?) ?? 'unknown';

        if (idempotencyCache.containsKey(idempotencyKey)) {
          // Idempotent duplicate: return cached response without double-counting!
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(idempotencyCache[idempotencyKey]!);
          await req.response.close();
          return;
        }

        serverHits[id] = (serverHits[id] ?? 0) + 1;
        final responseBody = jsonEncode({'status': 'ok', 'id': id});
        idempotencyCache[idempotencyKey] = responseBody;

        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.json;
        req.response.write(responseBody);
        await req.response.close();
      });

      final targetUrl = 'http://${server.address.address}:${server.port}/api/orders';

      // Setup FaultInjectionHttpClient with DropSocketAfterRequestBody
      final faultClient = FaultInjectionHttpClient(
        script: [const DropSocketAfterRequestBody()],
      );

      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/two_generals.db',
        httpClient: faultClient,
      );
      await client.registerEntity('orders', url: targetUrl);

      // Store order offline
      final orderId = await client.store('orders', {'item': 'Server Rack', 'price': 5000});

      // 1. First sync: server receives request & commits, but socket is dropped before client gets response!
      await client.sync();

      // Client sees network drop -> outbox MUST remain pending with incremented retry count
      var outboxRows = await client.query('SELECT status, retry_count FROM _sync_outbox WHERE entity_id = ?', [orderId]);
      expect(outboxRows.first['status'], equals('pending'));
      expect(outboxRows.first['retry_count'], equals(1));
      expect(serverHits[orderId], equals(1), reason: 'Server did receive and commit first attempt');

      // 2. Second sync: network restored, client retries with exact same Idempotency-Key
      await client.sync(force: true);

      outboxRows = await client.query('SELECT status FROM _sync_outbox WHERE entity_id = ?', [orderId]);
      expect(outboxRows.first['status'], equals('synced'));
      expect(serverHits[orderId], equals(1), reason: 'Server deduplicated; zero duplicate records created');

      await client.close();
      faultClient.close();
      await server.close();
    });

    test('Scenario 4: Volume soak test (5,000 records under SQLite WAL indexing)', () async {
      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/soak.db',
        maxReaders: 4,
      );
      await client.registerTable('tasks', {
        'title': 'TEXT',
        'sequence': 'INTEGER',
      });

      const totalRecords = 5000;
      final sw = Stopwatch()..start();

      // Write in chunks to verify bulk ingestion
      for (int i = 0; i < totalRecords; i += 500) {
        final futures = <Future<String>>[];
        for (int j = 0; j < 500; j++) {
          final idx = i + j;
          futures.add(client.store('tasks', {
            'title': 'Task #$idx',
            'sequence': idx,
          }));
        }
        await Future.wait(futures);
      }
      sw.stop();

      // Ingestion must complete quickly under WAL mode
      expect(sw.elapsedMilliseconds, lessThan(30000));

      // Read query latency under 5,000 records must stay <50ms
      final readSw = Stopwatch()..start();
      final page = await client.restore('tasks', orderBy: 'sequence ASC', where: 'sequence < 100');
      readSw.stop();

      expect(page, hasLength(100));
      expect(readSw.elapsedMilliseconds, lessThan(50));

      // Verify total outbox count
      final countRows = await client.query('SELECT COUNT(*) as cnt FROM _sync_outbox');
      expect(countRows.first['cnt'], equals(totalRecords));

      await client.close();
    });

    test('Scenario 5: Storage full / transaction abort guarantees zero orphaned outbox records', () async {
      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/storage_full.db',
      );
      await client.registerTable('items', {'sku': 'TEXT UNIQUE NOT NULL'});

      // First write succeeds
      await client.store('items', {'sku': 'SKU-UNIQUE-1'});

      // Second write attempts to insert duplicate SKU inside transaction (simulates DB error / constraint / disk error)
      try {
        await client.storage.db.writeTransaction((tx) async {
          await tx.execute("INSERT INTO items (id, version, updated_at, sku) VALUES ('i2', 1, 1000, 'SKU-UNIQUE-1')");
          await tx.execute("INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, created_at, status) VALUES ('m2', 'items', 'i2', 'upsert', 1000, 'pending')");
        });
      } catch (_) {
        // Expected transaction rollback
      }

      // Assert invariant: neither active table nor outbox contains partial/orphaned 'i2' / 'm2' records
      final itemRows = await client.query("SELECT * FROM items WHERE sku = 'SKU-UNIQUE-1'");
      expect(itemRows, hasLength(1));

      final outboxRows = await client.query("SELECT * FROM _sync_outbox WHERE entity_id = 'i2'");
      expect(outboxRows, isEmpty, reason: 'Zero orphaned outbox records after aborted transaction');

      await client.close();
    });

    test('Scenario 6: Injected DNS resolution failure (DnsFailure) pauses without crash and recovers', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'status': 'ok'}));
        await req.response.close();
      });

      final targetUrl = 'http://${server.address.address}:${server.port}/api/records';
      final faultClient = FaultInjectionHttpClient(
        script: [const DnsFailure()],
      );

      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/dns_fault.db',
        httpClient: faultClient,
      );
      await client.registerEntity('records', url: targetUrl);

      final recId = await client.store('records', {'name': 'DNS Resilient Record'});

      // Attempt 1: Injected DNS failure (SocketException)
      await client.sync();

      var rows = await client.query('SELECT status, retry_count, next_retry_at FROM _sync_outbox WHERE entity_id = ?', [recId]);
      expect(rows.first['status'], equals('pending'), reason: 'DNS failure leaves outbox pending');
      expect(rows.first['retry_count'], equals(1));
      expect(rows.first['next_retry_at'], isNotNull);

      // Attempt 2: DNS resolves -> sync recovers with force: true
      await client.sync(force: true);

      rows = await client.query('SELECT status, next_retry_at FROM _sync_outbox WHERE entity_id = ?', [recId]);
      expect(rows.first['status'], equals('synced'));
      expect(rows.first['next_retry_at'], isNull);

      await client.close();
      faultClient.close();
      await server.close();
    });

    test('Scenario 7: Injected TLS handshake failure (TlsFailure) pauses without corruption and recovers', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'status': 'ok'}));
        await req.response.close();
      });

      final targetUrl = 'http://${server.address.address}:${server.port}/api/records';
      final faultClient = FaultInjectionHttpClient(
        script: [const TlsFailure()],
      );

      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/tls_fault.db',
        httpClient: faultClient,
      );
      await client.registerEntity('records', url: targetUrl);

      final recId = await client.store('records', {'name': 'TLS Resilient Record'});

      // Attempt 1: Injected TLS handshake failure (HandshakeException)
      await client.sync();

      var rows = await client.query('SELECT status, retry_count, next_retry_at FROM _sync_outbox WHERE entity_id = ?', [recId]);
      expect(rows.first['status'], equals('pending'), reason: 'TLS handshake failure leaves outbox pending');
      expect(rows.first['retry_count'], equals(1));
      expect(rows.first['next_retry_at'], isNotNull);

      // Attempt 2: Handshake succeeds -> sync recovers
      await client.sync(force: true);

      rows = await client.query('SELECT status, next_retry_at FROM _sync_outbox WHERE entity_id = ?', [recId]);
      expect(rows.first['status'], equals('synced'));
      expect(rows.first['next_retry_at'], isNull);

      await client.close();
      faultClient.close();
      await server.close();
    });
  });
}
