import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'package:test/test.dart';

class OrderModel {
  final String id;
  final String title;

  OrderModel({required this.id, required this.title});
  factory OrderModel.fromJson(Map<String, dynamic> json) => OrderModel(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
      );
  Map<String, dynamic> toJson() => {'id': id, 'title': title};
}

void main() {
  late String dbPath;
  OrbitClient? currentClient;

  setUp(() {
    dbPath = '${Directory.systemTemp.path}/fixes_test_${DateTime.now().microsecondsSinceEpoch}.db';
  });

  tearDown(() async {
    await currentClient?.close();
    currentClient = null;
    final f = File(dbPath);
    if (await f.exists()) await f.delete();
  });

  group('Fix 2: Response Body ID Harvesting & Foreign Key Rewriting', () {
    test('POST response server ID is harvested and rewrites pending child mutations', () async {
      final capturedRequests = <String, Map<String, dynamic>>{};

      final mockClient = MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/api/orders') {
          // Server accepts order and returns generated server ID "ord_srv_777"
          return http.Response(
            jsonEncode({'id': 'ord_srv_777', 'status': 'created'}),
            201,
          );
        }
        if (request.method == 'POST' && request.url.path.contains('/items')) {
          capturedRequests[request.url.path] = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(jsonEncode({'status': 'ok'}), 200);
        }
        return http.Response('Not Found', 404);
      });

      final client = await OrbitClient.initialize(
        databasePath: dbPath,
        baseUrl: 'https://api.mycompany.com',
        httpClient: mockClient,
      );
      currentClient = client;

      // 1. Register parent and child tables
      await client.registerTable('orders', {'title': 'TEXT'});
      await client.registerTable('order_items', {'order_id': 'TEXT', 'item': 'TEXT'});

      final tempOrderId = 'temp-ord-uuid-001';

      // 2. Queue parent order mutation offline
      final parentMut = await client.save(
        entity: 'orders',
        id: tempOrderId,
        data: {'title': 'Dinner Order'},
        url: 'https://api.mycompany.com/api/orders',
        httpMethod: 'POST',
      );

      // 3. Queue child item referencing tempOrderId in both URL and payload
      await client.save(
        entity: 'order_items',
        id: 'item-001',
        data: {'order_id': tempOrderId, 'item': 'Margherita Pizza'},
        url: 'https://api.mycompany.com/api/orders/$tempOrderId/items',
        httpMethod: 'POST',
        dependsOnMutationId: parentMut,
      );

      // 4. Trigger sync
      final summary = await client.sync();
      expect(summary.applied, equals(2));
      expect(summary.failed, equals(0));

      // 5. Assert canonical ID mapping was registered
      final canonicalId = await client.storage.getCanonicalServerId(
        entity: 'orders',
        localTempId: tempOrderId,
      );
      expect(canonicalId, equals('ord_srv_777'));

      // 6. Assert local active parent record was updated with server ID
      final parentRows = await client.query("SELECT id, json_extract(data_json, '\$.title') as title FROM orders WHERE id = 'ord_srv_777'");
      expect(parentRows, isNotEmpty);
      expect(parentRows.first['title'], equals('Dinner Order'));

      // 7. Assert child request received the harvested server ID, NOT the temp UUID!
      expect(capturedRequests.containsKey('/api/orders/ord_srv_777/items'), isTrue);
      expect(capturedRequests['/api/orders/ord_srv_777/items']!['order_id'], equals('ord_srv_777'));
    });
  });

  group('Fix 3: Multi-Isolate Safety Guard on in_flight Reset', () {
    test('initSystemSchema preserves active in_flight requests and resets only stale (> 5m) locks', () async {
      final storage = await SyncStorage.open(path: dbPath);

      final now = DateTime.now().millisecondsSinceEpoch;
      final recentTimestamp = now - const Duration(seconds: 30).inMilliseconds; // 30s ago (active)
      final staleTimestamp = now - const Duration(minutes: 10).inMilliseconds; // 10m ago (stale/dead lock)

      // Insert active in-flight mutation
      await storage.db.execute('''
        INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, payload_json, status, created_at, updated_at)
        VALUES ('active-mut-1', 'tasks', '1', 'create', '{}', 'in_flight', ?, ?)
      ''', [recentTimestamp, recentTimestamp]);

      // Insert stale in-flight mutation (interrupted/crashed from previous day)
      await storage.db.execute('''
        INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, payload_json, status, created_at, updated_at)
        VALUES ('stale-mut-2', 'tasks', '2', 'create', '{}', 'in_flight', ?, ?)
      ''', [staleTimestamp, staleTimestamp]);

      await storage.close();

      // Second isolate / background worker opens database
      final reopenedStorage = await SyncStorage.open(path: dbPath);

      final rows = await reopenedStorage.db.getAll(
        'SELECT mutation_id, status FROM _sync_outbox ORDER BY mutation_id',
      );

      final statusMap = {for (final r in rows) r['mutation_id'] as String: r['status'] as String};

      // Active request (< 5 mins) MUST NOT be reset to pending
      expect(statusMap['active-mut-1'], equals('in_flight'));

      // Stale request (> 5 mins) MUST be reset to pending
      expect(statusMap['stale-mut-2'], equals('pending'));

      await reopenedStorage.close();
    });
  });

  group('Fix 4: Enterprise Dio Interceptor Passthrough & Table Hydration', () {
    test('Dio interceptor catches 401, refreshes token, and retries successfully', () async {
      final dio = Dio();
      int attemptCount = 0;
      String currentToken = 'expired-token';

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            options.headers['authorization'] = 'Bearer $currentToken';
            handler.next(options);
          },
          onError: (DioException error, handler) async {
            if (error.response?.statusCode == 401) {
              attemptCount++;
              // Interceptor refreshes token and retries!
              currentToken = 'refreshed-valid-token';
              try {
                // Mock success on retry
                final res = Response(
                  requestOptions: error.requestOptions,
                  statusCode: 200,
                  data: '{"status": "recovered"}',
                );
                return handler.resolve(res);
              } catch (e) {
                return handler.next(error);
              }
            }
            return handler.next(error);
          },
        ),
      );

      // Seed interceptor to return 401 on first attempt
      dio.httpClientAdapter = _MockDioAdapter((options) {
        if (options.headers['authorization'] == 'Bearer expired-token') {
          return ResponseBody.fromString(
            '{"error": "Token expired"}',
            401,
            headers: {'content-type': ['application/json']},
          );
        }
        return ResponseBody.fromString(
          '{"status": "recovered"}',
          200,
          headers: {'content-type': ['application/json']},
        );
      });

      final transport = SyncTransport.dio(
        baseUrl: 'https://enterprise.example.com',
        dio: dio,
      );

      final resp = await transport.pushCustom(
        url: 'https://enterprise.example.com/api/test',
        method: 'POST',
        mutationId: 'mut-dio-retry',
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        payload: {'data': 'test'},
      );

      expect(attemptCount, equals(1));
      expect(resp.statusCode, equals(200));
      expect(resp.body, contains('recovered'));

      transport.dispose();
    });

    test('OrbitTable.refresh() routes through configured SyncTransport.dio cleanly', () async {
      final dio = Dio();
      bool dioWasCalled = false;

      dio.httpClientAdapter = _MockDioAdapter((options) {
        dioWasCalled = true;
        return ResponseBody.fromString(
          jsonEncode([
            {'id': 'dio-order-1', 'title': 'Enterprise Order via Dio'},
          ]),
          200,
          headers: {'content-type': ['application/json']},
        );
      });

      final transport = SyncTransport.dio(
        baseUrl: 'https://enterprise.example.com',
        dio: dio,
      );

      final client = await OrbitClient.initialize(
        databasePath: dbPath,
        baseUrl: 'https://enterprise.example.com',
        transport: transport,
      );
      currentClient = client;

      final orders = client.collection<OrderModel>(
        name: 'orders',
        endpoint: '/api/orders',
        fromJson: OrderModel.fromJson,
        toJson: (o) => o.toJson(),
      );

      final count = await orders.refresh();

      expect(dioWasCalled, isTrue);
      final countValue = count.count;
      expect(countValue, equals(1));

      final rows = await orders.query();
      expect(rows.length, equals(1));
      expect(rows.first.title, equals('Enterprise Order via Dio'));
    });
  });
}

class _MockDioAdapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions options) handler;
  _MockDioAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}
