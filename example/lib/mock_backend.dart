import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models/customer.dart';
import 'models/product.dart';

/// In-process mock REST backend for the Orbit Sync Mobile ERP example.
///
/// Simulates enterprise ERP endpoints (Customers, Products, Orders, Order Items)
/// with support for canonical server sequence generation (SO-2026-XXXX),
/// RFC 9457 HTTP 422 business validation rejections, and network fault injection.
class MockBackend {
  final HttpServer _server;
  bool isOutage = false;
  Duration latency = Duration.zero;
  bool simulateCreditRejection = false;

  int _nextOrderSeq = 1001;
  final Map<String, Customer> _customers = {};
  final Map<String, Product> _products = {};
  final Map<String, Map<String, dynamic>> _orders = {};
  final List<Map<String, dynamic>> _orderItems = [];

  MockBackend._(this._server) {
    _seedMasterData();
  }

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<MockBackend> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final backend = MockBackend._(server);
    backend._listen();
    return backend;
  }

  void _seedMasterData() {
    final defaultCustomers = [
      const Customer(
        id: 'cust-101',
        name: 'Acme Corp Industrial',
        creditLimit: 5000.0,
        outstandingBalance: 1200.0,
        tier: 'VIP',
      ),
      const Customer(
        id: 'cust-102',
        name: 'Apex Manufacturing',
        creditLimit: 3000.0,
        outstandingBalance: 2400.0,
        tier: 'STANDARD',
      ),
      const Customer(
        id: 'cust-103',
        name: 'Summit Logistics',
        creditLimit: 10000.0,
        outstandingBalance: 500.0,
        tier: 'VIP',
      ),
    ];

    for (final c in defaultCustomers) {
      _customers[c.id] = c;
    }

    final defaultProducts = [
      const Product(
        id: 'prod-001',
        sku: 'SKU-BEARING-50',
        name: 'Precision Ball Bearing 50mm',
        unitPrice: 45.0,
        stockQuantity: 120,
        category: 'Mechanical',
      ),
      const Product(
        id: 'prod-002',
        sku: 'SKU-HYD-VALVE',
        name: 'Hydraulic Flow Control Valve',
        unitPrice: 320.0,
        stockQuantity: 35,
        category: 'Hydraulics',
      ),
      const Product(
        id: 'prod-003',
        sku: 'SKU-PLC-CPU-04',
        name: 'Modular PLC CPU Unit 24V',
        unitPrice: 850.0,
        stockQuantity: 18,
        category: 'Automation',
      ),
      const Product(
        id: 'prod-004',
        sku: 'SKU-CBL-SHLD-50',
        name: 'Shielded Industrial Cable 50m',
        unitPrice: 110.0,
        stockQuantity: 65,
        category: 'Electrical',
      ),
      const Product(
        id: 'prod-005',
        sku: 'SKU-GASKET-SET',
        name: 'High-Temp Gasket Seal Set',
        unitPrice: 28.5,
        stockQuantity: 200,
        category: 'Mechanical',
      ),
    ];

    for (final p in defaultProducts) {
      _products[p.id] = p;
    }
  }

  void seedExtraProducts(int count) {
    for (int i = 1; i <= count; i++) {
      final id = 'prod-bulk-$i';
      _products[id] = Product(
        id: id,
        sku: 'SKU-AUTO-$i',
        name: 'Industrial Spare Part #$i',
        unitPrice: 15.0 + (i % 100),
        stockQuantity: 50 + (i % 200),
        category: i % 2 == 0 ? 'Mechanical' : 'Electrical',
      );
    }
  }

  void _listen() {
    _server.listen((HttpRequest req) async {
      if (latency > Duration.zero) {
        await Future.delayed(latency);
      }

      if (isOutage) {
        req.response.statusCode = HttpStatus.serviceUnavailable;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'error': 'simulated_outage'}));
        await req.response.close();
        return;
      }

      req.response.headers.contentType = ContentType.json;
      final path = req.uri.path;
      final method = req.method;

      try {
        if (method == 'GET' && path == '/customers') {
          _sendJson(
              req, _customers.values.map((c) => c.toJson()).toList());
        } else if (method == 'GET' && path == '/products') {
          _sendJson(
              req, _products.values.map((p) => p.toJson()).toList());
        } else if (method == 'GET' && path == '/orders') {
          _sendJson(req, _orders.values.toList());
        } else if (method == 'POST' && path == '/orders') {
          final bodyStr = await utf8.decoder.bind(req).join();
          final data = bodyStr.isNotEmpty
              ? jsonDecode(bodyStr) as Map<String, dynamic>
              : <String, dynamic>{};

          final total = (data['total_amount'] as num?)?.toDouble() ?? 0.0;
          final customerId = data['customer_id'] as String?;
          final customer = customerId != null ? _customers[customerId] : null;

          // RFC 9457 Business Validation Rejection
          if (simulateCreditRejection &&
              customer != null &&
              !customer.canAffordOrder(total)) {
            req.response.statusCode = HttpStatus.unprocessableEntity;
            req.response.headers.set(
                'content-type', 'application/problem+json');
            req.response.write(jsonEncode({
              'type': 'https://erp.example.com/errors/credit-limit-exceeded',
              'title': 'Customer Credit Limit Exceeded',
              'status': 422,
              'detail':
                  'Order total \$$total exceeds available credit limit of \$${customer.creditLimit - customer.outstandingBalance} for customer ${customer.name}',
              'instance': '/orders/${data['id']}',
            }));
            await req.response.close();
            return;
          }

          // Canonical sequence ID generation
          final orderNumber = 'SO-2026-${_nextOrderSeq++}';
          final savedOrder = {
            ...data,
            'id': orderNumber,
            'order_number': orderNumber,
            'status': 'SYNCED',
          };
          _orders[orderNumber] = savedOrder;

          _sendJson(req, savedOrder, statusCode: HttpStatus.created);
        } else if (method == 'POST' && path.contains('/items')) {
          final bodyStr = await utf8.decoder.bind(req).join();
          final data = bodyStr.isNotEmpty
              ? jsonDecode(bodyStr) as Map<String, dynamic>
              : <String, dynamic>{};
          _orderItems.add(data);
          _sendJson(req, data, statusCode: HttpStatus.created);
        } else if (method == 'POST' && path.endsWith('/sync/push')) {
          final bodyStr = await utf8.decoder.bind(req).join();
          int applied = 0;
          if (bodyStr.isNotEmpty) {
            final json = jsonDecode(bodyStr) as Map<String, dynamic>;
            final mutations = (json['mutations'] as List?) ?? [];
            for (final m in mutations) {
              if (m is Map<String, dynamic>) {
                final id = m['entity_id']?.toString() ?? m['id']?.toString();
                if (id != null) {
                  _orders[id] = m;
                  applied++;
                }
              }
            }
          }
          _sendJson(req, {'status': 'ok', 'applied': applied});
        } else if (method == 'GET' && path.endsWith('/sync/pull')) {
          _sendJson(req, {
            'changes': _orders.values.toList(),
            'next_cursor': _orders.length,
            'has_more': false,
          });
        } else {
          _sendJson(req, {'status': 'ok'});
        }
      } catch (e) {
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.write(jsonEncode({'error': e.toString()}));
        await req.response.close();
      }
    });
  }

  void _sendJson(HttpRequest req, dynamic body,
      {int statusCode = HttpStatus.ok}) {
    req.response.statusCode = statusCode;
    req.response.write(jsonEncode(body));
    req.response.close();
  }

  Future<void> stop() => _server.close(force: true);
}
