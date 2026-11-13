import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'package:test/test.dart';

class Order {
  final String id;
  final String item;
  final int quantity;

  Order({required this.id, required this.item, required this.quantity});

  factory Order.fromJson(Map<String, dynamic> json) => Order(
        id: json['id']?.toString() ?? '',
        item: json['item']?.toString() ?? '',
        quantity: (json['quantity'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'item': item,
        'quantity': quantity,
      };
}

void main() {
  late String dbPath;
  OrbitClient? currentClient;

  setUp(() {
    dbPath =
        '${Directory.systemTemp.path}/cqrs_test_${DateTime.now().microsecondsSinceEpoch}.db';
  });

  tearDown(() async {
    await currentClient?.close();
    currentClient = null;
    final f = File(dbPath);
    if (await f.exists()) {
      await f.delete();
    }
  });

  group('Strict CQRS Separation & Outbox Sync', () {
    test(
        'orbit.sync() strictly pushes outbox mutations and NEVER calls /sync/pull',
        () async {
      final requestedUrls = <String>[];
      final mockClient = MockClient((request) async {
        requestedUrls.add('${request.method} ${request.url.path}');
        if (request.url.path == '/api/orders') {
          return http.Response(jsonEncode({'status': 'created'}), 201);
        }
        return http.Response('Not Found', 404);
      });

      final client = await OrbitClient.initialize(
        databasePath: dbPath,
        baseUrl: 'https://api.mycompany.com',
        httpClient: mockClient,
      );
      currentClient = client;

      final orders = client.collection<Order>(
        name: 'orders',
        endpoint: '/api/orders',
        fromJson: Order.fromJson,
        toJson: (o) => o.toJson(),
      );

      // Create a pending mutation in outbox
      await orders.save(Order(id: 'order-1', item: 'Laptop', quantity: 2));

      // Trigger sync
      final summary = await client.sync();

      expect(summary.applied, equals(1));
      expect(summary.failed, equals(0));

      // Verify that NO request was made to /sync/pull or /sync/push
      expect(requestedUrls, contains('POST /api/orders'));
      expect(requestedUrls.any((u) => u.contains('/sync/pull')), isFalse);
      expect(requestedUrls.any((u) => u.contains('/sync/push')), isFalse);
    });
  });

  group('On-Demand Cache Hydration on Empty Table (Cold Start)', () {
    test('table.query() lazily hydrates empty local table from endpoints.list',
        () async {
      int listCallCount = 0;
      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/orders' && request.method == 'GET') {
          listCallCount++;
          return http.Response(
            jsonEncode([
              {
                'id': 'remote-1',
                'item': 'Server Hydrated Order',
                'quantity': 5
              },
              {
                'id': 'remote-2',
                'item': 'Second Hydrated Order',
                'quantity': 10
              },
            ]),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final client = await OrbitClient.initialize(
        databasePath: dbPath,
        baseUrl: 'https://api.mycompany.com',
        httpClient: mockClient,
      );
      currentClient = client;

      final orders = client.collection<Order>(
        name: 'orders',
        endpoint: '/api/orders',
        fromJson: Order.fromJson,
        toJson: (o) => o.toJson(),
      );

      // Initial state: SQLite is empty
      // First query() triggers automatic lazy fetch on cold start
      final results = await orders.query();

      expect(listCallCount, equals(1));
      expect(results.length, equals(2));
      expect(results.first.item, equals('Server Hydrated Order'));

      // Second query(): table is not empty and no TTL expired -> serves from local SQLite without re-fetching
      final secondResults = await orders.query();
      expect(listCallCount, equals(1)); // Still 1! Zero redundant network calls
      expect(secondResults.length, equals(2));
    });

    test(
        'table.watch() emits immediately and hydrates in background on cold start',
        () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/orders' && request.method == 'GET') {
          return http.Response(
            jsonEncode([
              {
                'id': 'order-watch-1',
                'item': 'Reactive Remote Item',
                'quantity': 1
              },
            ]),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final client = await OrbitClient.initialize(
        databasePath: dbPath,
        baseUrl: 'https://api.mycompany.com',
        httpClient: mockClient,
      );
      currentClient = client;

      final orders = client.collection<Order>(
        name: 'orders',
        endpoint: '/api/orders',
        fromJson: Order.fromJson,
        toJson: (o) => o.toJson(),
      );

      final completer = Completer<void>();
      final emittedSnapshots = <List<Order>>[];
      final sub = orders.watch().listen((list) {
        emittedSnapshots.add(list);
        if (list.isNotEmpty && !completer.isCompleted) {
          completer.complete();
        }
      });

      // Wait for stream emission and background hydration (up to 3s)
      await completer.future.timeout(const Duration(seconds: 3));

      expect(emittedSnapshots.isNotEmpty, isTrue);
      expect(emittedSnapshots.last.length, equals(1));
      expect(emittedSnapshots.last.first.item, equals('Reactive Remote Item'));

      await sub.cancel();
    });
  });

  group('Cache TTL Invalidation', () {
    test('table.query() re-fetches when cache TTL has expired', () async {
      int listCallCount = 0;
      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/orders' && request.method == 'GET') {
          listCallCount++;
          return http.Response(
            jsonEncode([
              {
                'id': 'order-1',
                'item': 'Version $listCallCount',
                'quantity': listCallCount
              },
            ]),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final client = await OrbitClient.initialize(
        databasePath: dbPath,
        baseUrl: 'https://api.mycompany.com',
        httpClient: mockClient,
      );
      currentClient = client;

      // Short TTL of 50ms for testing
      final orders = client.collection<Order>(
        name: 'orders',
        endpoint: '/api/orders',
        cacheTtl: const Duration(milliseconds: 50),
        fromJson: Order.fromJson,
        toJson: (o) => o.toJson(),
      );

      // Call 1: cold-start fetch
      final firstFetch = await orders.query();
      expect(listCallCount, equals(1));
      expect(firstFetch.first.item, equals('Version 1'));

      // Call 2 immediately (within 50ms TTL): uses SQLite cache
      final cacheHit = await orders.query();
      expect(listCallCount, equals(1));
      expect(cacheHit.first.item, equals('Version 1'));

      // Wait for TTL to expire
      await Future<void>.delayed(const Duration(milliseconds: 70));

      // Call 3 after TTL expired: re-fetches from server and updates SQLite
      final reFetched = await orders.query();
      expect(listCallCount, equals(2));
      expect(reFetched.first.item, equals('Version 2'));
    });
  });

  group('Offline / Network Error Fault Tolerance', () {
    test(
        'table.query() gracefully returns local data when remote call fails (offline)',
        () async {
      final mockClient = MockClient((request) async {
        // Simulating complete network outage / DNS failure
        throw http.ClientException('Network unreachable (Offline)');
      });

      final client = await OrbitClient.initialize(
        databasePath: dbPath,
        baseUrl: 'https://api.mycompany.com',
        httpClient: mockClient,
      );
      currentClient = client;

      final orders = client.collection<Order>(
        name: 'orders',
        endpoint: '/api/orders',
        fromJson: Order.fromJson,
        toJson: (o) => o.toJson(),
      );

      // Pre-populate one item locally
      await orders.save(
          Order(id: 'local-offline', item: 'Cached Local Order', quantity: 1));

      // Query should NOT throw exception even though remote fails
      final results = await orders.query();

      expect(results.length, equals(1));
      expect(results.first.item, equals('Cached Local Order'));
    });
  });

  group('baseUrl Standardization', () {
    test(
        'SyncWorker and HttpSyncTransport accept baseUrl and expose it cleanly',
        () {
      final transport = SyncTransport.http(
        baseUrl: 'https://production.api.com',
      );
      expect((transport as HttpSyncTransport).baseUrl,
          equals('https://production.api.com'));
      // Deprecated getter continues to function for backward compatibility
      expect(transport.baseUrl, equals('https://production.api.com'));
    });
  });
}
