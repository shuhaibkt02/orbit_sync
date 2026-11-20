import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'mock_backend.dart';
import 'models/product.dart';
import 'models/sales_order.dart';
import 'services/erp_service.dart';
import 'ui/apple_theme.dart';
import 'ui/orbit_app.dart';
import 'ui/widgets/order_card.dart';
import 'ui/widgets/order_create_sheet.dart';
import 'ui/widgets/product_card.dart';
import 'ui/widgets/sync_telemetry_sheet.dart';

export 'models/customer.dart';
export 'models/order_item.dart';
export 'models/product.dart';
export 'models/sales_order.dart';
export 'models/task.dart';
export 'services/erp_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );
  runApp(const OrbitSyncExampleApp());
}

class ErpScreen extends StatefulWidget {
  const ErpScreen({super.key});

  @override
  State<ErpScreen> createState() => _ErpScreenState();
}

class _ErpScreenState extends State<ErpScreen> {
  OrbitClient? _orbit;
  ErpService? _erp;
  MockBackend? _mockBackend;
  String? _initError;

  int _selectedTabIndex = 0; // 0: Orders, 1: Catalog
  String _productSearch = '';
  bool _isOffline = false;

  @override
  void initState() {
    super.initState();
    _initErp();
  }

  Future<void> _initErp() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final mock = await MockBackend.start();
      _mockBackend = mock;

      final client = await OrbitClient.initialize(
        databasePath: p.join(dir.path, 'orbit_erp.db'),
        baseUrl: mock.url,
      );

      final service = ErpService(client);

      // Hydrate initial products if local SQLite cache is empty
      final existingProds = await service.products.query(limit: 1);
      if (existingProds.isEmpty) {
        final catalog = [
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
        ];
        for (final p in catalog) {
          await service.products.save(p, id: p.id);
        }
      }

      if (mounted) {
        setState(() {
          _orbit = client;
          _erp = service;
          _initError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _initError = e.toString());
    }
  }

  @override
  void dispose() {
    _orbit?.close();
    _mockBackend?.stop();
    super.dispose();
  }

  void _toggleOffline() {
    if (_mockBackend == null) return;
    setState(() {
      _isOffline = !_isOffline;
      _mockBackend!.isOutage = _isOffline;
    });
  }

  void _showOrderRejectionDetails(SalesOrder order) {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Order Validation Rejection'),
        content: Padding(
          padding: const EdgeInsets.only(top: 8.0),
          child: Text(
            order.rejectionReason ??
                'Order exceeded customer credit limit. Orbit Sync automatically executed an optimistic baseline rollback to preserve database invariants.',
          ),
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('OK'),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_initError != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Text('Initialization Error: $_initError',
                style: const TextStyle(color: Colors.red)),
          ),
        ),
      );
    }

    if (_orbit == null || _erp == null) {
      return const Scaffold(
        body: Center(child: CupertinoActivityIndicator(radius: 14)),
      );
    }

    return Scaffold(
      backgroundColor: AppleTheme.scaffoldBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Orbit Mobile ERP',
              style: TextStyle(
                color: Colors.black,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
              ),
            ),
            Text(
              'Field Sales & Dispatch',
              style: TextStyle(
                color: Colors.grey,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        actions: [
          // Airplane mode simulation pill
          GestureDetector(
            onTap: _toggleOffline,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _isOffline
                    ? CupertinoColors.systemRed.withValues(alpha: 0.12)
                    : CupertinoColors.systemGreen.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _isOffline
                      ? CupertinoColors.systemRed
                      : CupertinoColors.systemGreen,
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _isOffline
                        ? CupertinoIcons.airplane
                        : CupertinoIcons.wifi,
                    size: 14,
                    color: _isOffline
                        ? CupertinoColors.systemRed
                        : CupertinoColors.systemGreen,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _isOffline ? 'Offline' : 'Online',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _isOffline
                          ? CupertinoColors.systemRed
                          : CupertinoColors.systemGreen,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(CupertinoIcons.arrow_2_circlepath,
                color: AppleTheme.accentBlue),
            tooltip: 'Sync Now',
            onPressed: () => _orbit!.syncNow(),
          ),
          IconButton(
            icon: const Icon(CupertinoIcons.gauge, color: Colors.black87),
            tooltip: 'Telemetry Engine',
            onPressed: () => SyncTelemetrySheet.show(
              context,
              client: _orbit!,
              onSeedDemo: () async {
                _mockBackend?.seedExtraProducts(50);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Seeded 50 extra SKUs to mock backend')),
                  );
                }
              },
            ),
          ),
        ],
      ),
      body: _selectedTabIndex == 0 ? _buildOrdersTab() : _buildCatalogTab(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedTabIndex,
        onTap: (idx) => setState(() => _selectedTabIndex = idx),
        selectedItemColor: AppleTheme.accentBlue,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.doc_text_fill),
            label: 'Sales Orders',
          ),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.cube_box_fill),
            label: 'Product Catalog',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppleTheme.accentBlue,
        onPressed: () => OrderCreateSheet.show(
          context,
          erp: _erp!,
          mockBackend: _mockBackend!,
          onOrderCreated: () => setState(() {}),
        ),
        icon: const Icon(CupertinoIcons.plus, color: Colors.white),
        label: const Text('Book Order',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      ),
    );
  }

  Widget _buildOrdersTab() {
    return StreamBuilder<List<SalesOrder>>(
      stream: _erp!.watchOrders(),
      builder: (context, snapshot) {
        final orders = snapshot.data ?? [];
        if (orders.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(CupertinoIcons.cart_badge_plus,
                    size: 56, color: Colors.grey.shade300),
                const SizedBox(height: 12),
                const Text('No Sales Orders Booked',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('Tap "Book Order" to create a multi-line order',
                    style: TextStyle(color: Colors.grey.shade500)),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.only(top: 12, bottom: 80),
          itemCount: orders.length,
          itemBuilder: (ctx, i) {
            final order = orders[i];
            return OrderCard(
              order: order,
              onTap: order.status == 'REJECTED'
                  ? () => _showOrderRejectionDetails(order)
                  : null,
            );
          },
        );
      },
    );
  }

  Widget _buildCatalogTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: CupertinoSearchTextField(
            placeholder: 'Search 100+ SKUs in SQLite WAL...',
            onChanged: (val) => setState(() => _productSearch = val),
          ),
        ),
        Expanded(
          child: StreamBuilder<List<Product>>(
            stream: _erp!.watchProducts(),
            builder: (context, snapshot) {
              var prods = snapshot.data ?? [];
              if (_productSearch.isNotEmpty) {
                final q = _productSearch.toLowerCase();
                prods = prods
                    .where((p) =>
                        p.name.toLowerCase().contains(q) ||
                        p.sku.toLowerCase().contains(q))
                    .toList();
              }

              return ListView.builder(
                padding: const EdgeInsets.only(top: 6, bottom: 80),
                itemCount: prods.length,
                itemBuilder: (ctx, i) => ProductCard(product: prods[i]),
              );
            },
          ),
        ),
      ],
    );
  }
}
