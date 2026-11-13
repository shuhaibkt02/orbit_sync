import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

class TestOrder {
  final String id;
  final String item;
  final double price;

  const TestOrder({required this.id, required this.item, required this.price});

  factory TestOrder.fromJson(Map<String, dynamic> json) => TestOrder(
        id: json['id'] as String,
        item: json['item'] as String,
        price: (json['price'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {'id': id, 'item': item, 'price': price};
}

void main() {
  group('Zero-Hardcoded RestEndpoint Declarative Routing', () {
    const baseUrl = 'https://api.acme.corp/v1';

    group('1. Default REST Conventions (GET, POST, PUT, DELETE)', () {
      test('generates standard REST paths when overrides are omitted', () {
        const endpoint = RestEndpoint(path: '/orders');

        expect(endpoint.resolveCreatePath(), equals('/orders'));
        expect(endpoint.resolveUpdatePath('ord-100'), equals('/orders/ord-100'));
        expect(endpoint.resolveDeletePath('ord-100'), equals('/orders/ord-100'));
        expect(endpoint.resolveDetailPath('ord-100'), equals('/orders/ord-100'));
        expect(endpoint.resolveListPath(), equals('/orders'));
      });

      test('sanitizes trailing and leading slashes during path joining', () {
        const endpointWithTrailingSlash = RestEndpoint(path: '/orders/');

        expect(endpointWithTrailingSlash.resolveCreatePath(), equals('/orders/'));
        expect(endpointWithTrailingSlash.resolveUpdatePath('ord-100'), equals('/orders/ord-100'));
        expect(endpointWithTrailingSlash.resolveDeletePath('/ord-100'), equals('/orders/ord-100'));
        expect(endpointWithTrailingSlash.resolveDetailPath('ord-100'), equals('/orders/ord-100'));
      });

      test('resolves full URLs using EndpointUrlResolver with baseUrl', () {
        final resolver = EndpointUrlResolver(baseUrl: baseUrl);
        const endpoint = RestEndpoint(path: '/orders');

        expect(
          resolver.resolveCreateUrl(endpoint),
          equals('https://api.acme.corp/v1/orders'),
        );
        expect(
          resolver.resolveUpdateUrl(endpoint, 'ord-101'),
          equals('https://api.acme.corp/v1/orders/ord-101'),
        );
        expect(
          resolver.resolveDeleteUrl(endpoint, 'ord-101'),
          equals('https://api.acme.corp/v1/orders/ord-101'),
        );
        expect(
          resolver.resolveDetailUrl(endpoint, 'ord-101'),
          equals('https://api.acme.corp/v1/orders/ord-101'),
        );
        expect(
          resolver.resolveListUrl(endpoint),
          equals('https://api.acme.corp/v1/orders'),
        );
      });

      test('TableEndpointResolver maps operations to standard HTTP verbs and URLs', () {
        const endpoint = RestEndpoint(path: '/orders');
        final tableResolver = TableEndpointResolver<TestOrder>(
          entityName: 'orders',
          baseUrl: baseUrl,
          restEndpoint: endpoint,
        );

        const order = TestOrder(id: 'ord-200', item: 'Tablet', price: 499.0);

        // CREATE -> POST /orders
        final createRes = tableResolver.resolveSave(item: order, id: 'ord-200', isUpdate: false);
        expect(createRes.method, equals('POST'));
        expect(createRes.url, equals('https://api.acme.corp/v1/orders'));

        // UPDATE -> PUT /orders/ord-200
        final updateRes = tableResolver.resolveSave(item: order, id: 'ord-200', isUpdate: true);
        expect(updateRes.method, equals('PUT'));
        expect(updateRes.url, equals('https://api.acme.corp/v1/orders/ord-200'));

        // DELETE -> DELETE /orders/ord-200
        final deleteRes = tableResolver.resolveDelete(id: 'ord-200');
        expect(deleteRes.method, equals('DELETE'));
        expect(deleteRes.url, equals('https://api.acme.corp/v1/orders/ord-200'));

        // DETAIL -> GET /orders/ord-200
        final detailRes = tableResolver.resolveDetail(id: 'ord-200');
        expect(detailRes.method, equals('GET'));
        expect(detailRes.url, equals('https://api.acme.corp/v1/orders/ord-200'));

        // LIST -> GET /orders
        final listRes = tableResolver.resolveList();
        expect(listRes.method, equals('GET'));
        expect(listRes.url, equals('https://api.acme.corp/v1/orders'));
      });
    });

    group('2. Custom Path Overrides', () {
      test('applies custom createPath override', () {
        const endpoint = RestEndpoint(
          path: '/orders',
          createPath: '/orders/checkout',
        );

        expect(endpoint.resolveCreatePath(), equals('/orders/checkout'));
        // Unmodified paths fall back to standard conventions
        expect(endpoint.resolveUpdatePath('123'), equals('/orders/123'));
        expect(endpoint.resolveDeletePath('123'), equals('/orders/123'));
        expect(endpoint.resolveDetailPath('123'), equals('/orders/123'));
      });

      test('applies custom updatePath, deletePath, and detailPath builders', () {
        final endpoint = RestEndpoint(
          path: '/orders',
          createPath: '/orders/new',
          updatePath: (id) => '/orders/$id/modify',
          deletePath: (id) => '/orders/$id/archive',
          detailPath: (id) => '/orders/$id/summary',
        );

        expect(endpoint.resolveCreatePath(), equals('/orders/new'));
        expect(endpoint.resolveUpdatePath('ord-42'), equals('/orders/ord-42/modify'));
        expect(endpoint.resolveDeletePath('ord-42'), equals('/orders/ord-42/archive'));
        expect(endpoint.resolveDetailPath('ord-42'), equals('/orders/ord-42/summary'));
        expect(endpoint.resolveListPath(), equals('/orders'));
      });

      test('resolves full URLs with custom overrides via EndpointUrlResolver', () {
        final resolver = EndpointUrlResolver(baseUrl: baseUrl);
        final endpoint = RestEndpoint(
          path: '/orders',
          createPath: '/api/v2/orders/custom-create',
          updatePath: (id) => '/api/v2/orders/custom-update/$id',
          deletePath: (id) => '/api/v2/orders/custom-delete/$id',
          detailPath: (id) => '/api/v2/orders/custom-detail/$id',
        );

        expect(
          resolver.resolveCreateUrl(endpoint),
          equals('https://api.acme.corp/v1/api/v2/orders/custom-create'),
        );
        expect(
          resolver.resolveUpdateUrl(endpoint, '999'),
          equals('https://api.acme.corp/v1/api/v2/orders/custom-update/999'),
        );
        expect(
          resolver.resolveDeleteUrl(endpoint, '999'),
          equals('https://api.acme.corp/v1/api/v2/orders/custom-delete/999'),
        );
        expect(
          resolver.resolveDetailUrl(endpoint, '999'),
          equals('https://api.acme.corp/v1/api/v2/orders/custom-detail/999'),
        );
      });
    });

    group('3. Dynamic Query Parameters Evaluation', () {
      test('evaluates query parameters callback dynamically at execution time', () {
        String currentBranch = 'branch_east';
        String currentStatus = 'active';

        final endpoint = RestEndpoint(
          path: '/orders',
          queryParams: () => {
            'branch': currentBranch,
            'status': currentStatus,
          },
        );

        final resolver = EndpointUrlResolver(baseUrl: baseUrl);

        // First call
        final url1 = resolver.resolveListUrl(endpoint);
        expect(url1, contains('branch=branch_east'));
        expect(url1, contains('status=active'));

        // State change
        currentBranch = 'branch_west';
        currentStatus = 'pending';

        // Second call reflects latest runtime state dynamically
        final url2 = resolver.resolveListUrl(endpoint);
        expect(url2, contains('branch=branch_west'));
        expect(url2, contains('status=pending'));
      });

      test('merges dynamic query params with per-call additional parameters', () {
        final endpoint = RestEndpoint(
          path: '/orders',
          queryParams: () => {'tenant': 'corp_a', 'version': '2'},
        );

        final resolver = EndpointUrlResolver(baseUrl: baseUrl);
        final url = resolver.resolveListUrl(
          endpoint,
          queryParams: {'limit': 25, 'offset': 50, 'nullable': null},
        );

        final uri = Uri.parse(url);
        expect(uri.queryParameters['tenant'], equals('corp_a'));
        expect(uri.queryParameters['version'], equals('2'));
        expect(uri.queryParameters['limit'], equals('25'));
        expect(uri.queryParameters['offset'], equals('50'));
        expect(uri.queryParameters.containsKey('nullable'), isFalse);
      });

      test('safely URI-encodes special characters in query parameter values', () {
        final endpoint = RestEndpoint(
          path: '/orders',
          queryParams: () => {'query': 'widgets & gadgets', 'tag': 'c++'},
        );

        final resolver = EndpointUrlResolver(baseUrl: baseUrl);
        final url = resolver.resolveListUrl(endpoint);

        final uri = Uri.parse(url);
        expect(uri.queryParameters['query'], equals('widgets & gadgets'));
        expect(uri.queryParameters['tag'], equals('c++'));
        expect(url, contains('query=widgets+%26+gadgets'));
      });

      test('produces clean URL without question mark when queryParams is empty or null', () {
        const endpoint = RestEndpoint(path: '/orders');
        final resolver = EndpointUrlResolver(baseUrl: baseUrl);

        final url = resolver.resolveListUrl(endpoint);
        expect(url, equals('https://api.acme.corp/v1/orders'));
        expect(url.contains('?'), isFalse);
      });
    });

    group('4. Dynamic Collection Headers Evaluation', () {
      test('evaluates synchronous headers callback dynamically', () async {
        String activeDepartment = 'logistics';

        final endpoint = RestEndpoint(
          path: '/orders',
          headers: () => {'X-Department': activeDepartment},
        );

        final h1 = await endpoint.resolveHeaders();
        expect(h1, equals({'X-Department': 'logistics'}));

        activeDepartment = 'finance';
        final h2 = await endpoint.resolveHeaders();
        expect(h2, equals({'X-Department': 'finance'}));
      });

      test('evaluates asynchronous headers callback dynamically', () async {
        String token = 'token_v1';
        Future<String> fetchToken() async {
          await Future.delayed(const Duration(milliseconds: 5));
          return token;
        }

        final endpoint = RestEndpoint(
          path: '/orders',
          headers: () async => {
            'Authorization': 'Bearer ${await fetchToken()}',
            'X-Tenant-ID': 'tenant_123',
          },
        );

        final h1 = await endpoint.resolveHeaders();
        expect(h1['Authorization'], equals('Bearer token_v1'));
        expect(h1['X-Tenant-ID'], equals('tenant_123'));

        // Token refreshed
        token = 'token_v2_refreshed';
        final h2 = await endpoint.resolveHeaders();
        expect(h2['Authorization'], equals('Bearer token_v2_refreshed'));
      });

      test('merges collection headers with per-call additional headers', () async {
        final endpoint = RestEndpoint(
          path: '/orders',
          headers: () => {'X-Base': 'true', 'X-Shared': 'from_endpoint'},
        );

        final merged = await endpoint.resolveHeaders({'X-Shared': 'overridden', 'X-Extra': 'custom'});
        expect(merged['X-Base'], equals('true'));
        expect(merged['X-Shared'], equals('overridden'));
        expect(merged['X-Extra'], equals('custom'));
      });
    });

    group('5. Zero-Hardcoded Endpoints Integration with OrbitClient', () {
      late Directory tempDir;
      late String dbPath;

      setUp(() {
        tempDir = Directory.systemTemp.createTempSync('orbit_rest_test_');
        dbPath = '${tempDir.path}/orbit_rest.db';
      });

      tearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      test('OrbitClient.collection with RestEndpoint writes clean REST paths and dynamic headers to outbox', () async {
        var tokenCount = 1;
        final client = await OrbitClient.initialize(
          databasePath: dbPath,
          baseUrl: 'https://backend.mycorp.com/api',
        );

        final orders = client.collection<TestOrder>(
          name: 'orders',
          endpoint: RestEndpoint(
            path: '/orders',
            createPath: '/orders/create_custom',
            updatePath: (id) => '/orders/update_custom/$id',
            deletePath: (id) => '/orders/delete_custom/$id',
            queryParams: () => {'scope': 'all'},
            headers: () async => {'X-Auth-Counter': '${tokenCount++}'},
          ),
          fromJson: TestOrder.fromJson,
          toJson: (o) => o.toJson(),
        );

        // 1. Create (save new)
        final id1 = await orders.save(const TestOrder(id: 'ord_1', item: 'Headphones', price: 99.0));
        expect(id1, equals('ord_1'));

        var records = await client.storage.db.getAll("SELECT * FROM _sync_outbox ORDER BY sequence_id ASC");
        expect(records.length, equals(1));
        var r1 = records.first;
        expect(r1['http_method'], equals('POST'));
        expect(r1['endpoint_url'], equals('https://backend.mycorp.com/api/orders/create_custom?scope=all'));
        expect(r1['headers_json'], contains('"X-Auth-Counter":"1"'));
        expect(r1['endpoint_url'].toString().contains('sync/pull'), isFalse);
        expect(r1['endpoint_url'].toString().contains('sync/push'), isFalse);

        // 2. Update (save existing)
        await orders.save(const TestOrder(id: 'ord_1', item: 'Headphones Pro', price: 149.0));
        records = await client.storage.db.getAll("SELECT * FROM _sync_outbox ORDER BY sequence_id ASC");
        expect(records.length, equals(2));
        var r2 = records.last;
        expect(r2['http_method'], equals('PUT'));
        expect(r2['endpoint_url'], equals('https://backend.mycorp.com/api/orders/update_custom/ord_1?scope=all'));
        expect(r2['headers_json'], contains('"X-Auth-Counter":"2"'));

        // 3. Delete
        await orders.delete('ord_1');
        records = await client.storage.db.getAll("SELECT * FROM _sync_outbox ORDER BY sequence_id ASC");
        expect(records.length, equals(3));
        var r3 = records.last;
        expect(r3['http_method'], equals('DELETE'));
        expect(r3['endpoint_url'], equals('https://backend.mycorp.com/api/orders/delete_custom/ord_1?scope=all'));
        expect(r3['headers_json'], contains('"X-Auth-Counter":"3"'));

        await client.close();
      });

      test('OrbitClient.collection with default RestEndpoint conventions', () async {
        final client = await OrbitClient.initialize(
          databasePath: dbPath,
          baseUrl: 'https://backend.mycorp.com',
        );

        final items = client.collection<TestOrder>(
          name: 'items',
          endpoint: const RestEndpoint(path: '/api/v1/items'),
          fromJson: TestOrder.fromJson,
          toJson: (o) => o.toJson(),
        );

        await items.save(const TestOrder(id: 'item_10', item: 'Keyboard', price: 80.0));
        var records = await client.storage.db.getAll("SELECT * FROM _sync_outbox ORDER BY sequence_id ASC");
        expect(records.length, equals(1));
        expect(records.first['http_method'], equals('POST'));
        expect(records.first['endpoint_url'], equals('https://backend.mycorp.com/api/v1/items'));

        // Update
        await items.save(const TestOrder(id: 'item_10', item: 'Mechanical Keyboard', price: 120.0));
        records = await client.storage.db.getAll("SELECT * FROM _sync_outbox ORDER BY sequence_id ASC");
        expect(records.length, equals(2));
        expect(records.last['http_method'], equals('PUT'));
        expect(records.last['endpoint_url'], equals('https://backend.mycorp.com/api/v1/items/item_10'));

        // Delete
        await items.delete('item_10');
        records = await client.storage.db.getAll("SELECT * FROM _sync_outbox ORDER BY sequence_id ASC");
        expect(records.length, equals(3));
        expect(records.last['http_method'], equals('DELETE'));
        expect(records.last['endpoint_url'], equals('https://backend.mycorp.com/api/v1/items/item_10'));

        await client.close();
      });
    });
  });
}
