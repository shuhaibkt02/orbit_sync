import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:example/mock_backend.dart';

void main() {
  group('Ticket 02: MockBackend Integration Tests', () {
    late MockBackend backend;
    final client = HttpClient();

    setUp(() async {
      backend = await MockBackend.start();
    });

    tearDown(() async {
      await backend.stop();
    });

    Future<({int statusCode, String body, HttpHeaders headers})> get(
        String path) async {
      final req = await client.getUrl(Uri.parse('${backend.url}$path'));
      final res = await req.close();
      final body = await utf8.decoder.bind(res).join();
      return (statusCode: res.statusCode, body: body, headers: res.headers);
    }

    Future<({int statusCode, String body, HttpHeaders headers})> post(
        String path, Map<String, dynamic> payload) async {
      final req = await client.postUrl(Uri.parse('${backend.url}$path'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(payload));
      final res = await req.close();
      final body = await utf8.decoder.bind(res).join();
      return (statusCode: res.statusCode, body: body, headers: res.headers);
    }

    test('Serves pre-seeded customers and products', () async {
      final custRes = await get('/customers');
      expect(custRes.statusCode, 200);
      final custs = jsonDecode(custRes.body) as List;
      expect(custs.length, 3);
      expect(custs.first['id'], 'cust-101');

      final prodRes = await get('/products');
      expect(prodRes.statusCode, 200);
      final prods = jsonDecode(prodRes.body) as List;
      expect(prods.length, 5);
      expect(prods.first['sku'], 'SKU-BEARING-50');
    });

    test('Generates canonical sequence order number (SO-2026-1001)', () async {
      final orderPayload = {
        'id': 'temp-order-uuid-1',
        'customer_id': 'cust-101',
        'total_amount': 250.0,
      };

      final res = await post('/orders', orderPayload);
      expect(res.statusCode, 201);
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      expect(data['order_number'], 'SO-2026-1001');
      expect(data['status'], 'SYNCED');
    });

    test(
        'Rejects order with HTTP 422 when simulateCreditRejection is active and limit exceeded',
        () async {
      backend.simulateCreditRejection = true;

      // Customer cust-102 has creditLimit: 3000, outstandingBalance: 2400 (available: 600)
      final orderPayload = {
        'id': 'temp-order-uuid-2',
        'customer_id': 'cust-102',
        'total_amount': 1500.0, // Exceeds available 600
      };

      final res = await post('/orders', orderPayload);
      expect(res.statusCode, 422);
      expect(res.headers.contentType?.value,
          contains('application/problem+json'));
      final problem = jsonDecode(res.body) as Map<String, dynamic>;
      expect(problem['title'], 'Customer Credit Limit Exceeded');
      expect(problem['status'], 422);
    });

    test('Returns HTTP 503 when isOutage is enabled', () async {
      backend.isOutage = true;
      final res = await get('/customers');
      expect(res.statusCode, 503);
    });
  });
}
