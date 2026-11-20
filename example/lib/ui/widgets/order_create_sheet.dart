import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../mock_backend.dart';
import '../../models/customer.dart';
import '../../models/order_item.dart';
import '../../models/product.dart';
import '../../services/erp_service.dart';
import '../apple_theme.dart';
import 'apple_pressable.dart';

/// Modal bottom sheet for booking multi-line Sales Orders with credit limits.
class OrderCreateSheet extends StatefulWidget {
  final ErpService erp;
  final MockBackend mockBackend;
  final VoidCallback onOrderCreated;

  const OrderCreateSheet({
    super.key,
    required this.erp,
    required this.mockBackend,
    required this.onOrderCreated,
  });

  static Future<void> show(
    BuildContext context, {
    required ErpService erp,
    required MockBackend mockBackend,
    required VoidCallback onOrderCreated,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => OrderCreateSheet(
        erp: erp,
        mockBackend: mockBackend,
        onOrderCreated: onOrderCreated,
      ),
    );
  }

  @override
  State<OrderCreateSheet> createState() => _OrderCreateSheetState();
}

class _OrderCreateSheetState extends State<OrderCreateSheet> {
  Customer? _selectedCustomer;
  final List<Customer> _customers = [
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

  final List<Product> _catalog = [
    const Product(
      id: 'prod-001',
      sku: 'SKU-BEARING-50',
      name: 'Precision Ball Bearing 50mm',
      unitPrice: 45.0,
      stockQuantity: 120,
    ),
    const Product(
      id: 'prod-002',
      sku: 'SKU-HYD-VALVE',
      name: 'Hydraulic Flow Control Valve',
      unitPrice: 320.0,
      stockQuantity: 35,
    ),
    const Product(
      id: 'prod-003',
      sku: 'SKU-PLC-CPU-04',
      name: 'Modular PLC CPU Unit 24V',
      unitPrice: 850.0,
      stockQuantity: 18,
    ),
  ];

  final Map<String, int> _quantities = {};
  bool _simulate422Rejection = false;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _selectedCustomer = _customers.first;
    _quantities['prod-001'] = 2; // Default 2 bearings
  }

  double get _totalAmount {
    double sum = 0.0;
    for (final p in _catalog) {
      final qty = _quantities[p.id] ?? 0;
      sum += qty * p.unitPrice;
    }
    return sum;
  }

  Future<void> _submit() async {
    if (_selectedCustomer == null || _totalAmount <= 0) return;
    setState(() => _isSubmitting = true);

    widget.mockBackend.simulateCreditRejection = _simulate422Rejection;

    final tempOrderId = 'ord-${DateTime.now().millisecondsSinceEpoch}';
    final lineItems = <OrderItem>[];

    for (final p in _catalog) {
      final qty = _quantities[p.id] ?? 0;
      if (qty > 0) {
        lineItems.add(OrderItem(
          id: 'item-${DateTime.now().microsecondsSinceEpoch}-${p.id}',
          orderId: tempOrderId,
          productId: p.id,
          productName: p.name,
          quantity: qty,
          unitPrice: p.unitPrice,
        ));
      }
    }

    // Instant 0ms save in local SQLite outbox
    await widget.erp.createOrder(
      customer: _selectedCustomer!,
      items: lineItems,
      tempOrderId: tempOrderId,
    );

    widget.onOrderCreated();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final availableCredit = _selectedCustomer != null
        ? (_selectedCustomer!.creditLimit - _selectedCustomer!.outstandingBalance)
        : 0.0;
    final isOverLimit = _totalAmount > availableCredit;

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Drag handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 12),
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.black12,
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Book Sales Order',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(CupertinoIcons.clear_circled_solid,
                      color: Colors.grey),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // Customer selector
                const Text('Select Customer',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.black12),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<Customer>(
                      value: _selectedCustomer,
                      isExpanded: true,
                      items: _customers.map((c) {
                        return DropdownMenuItem<Customer>(
                          value: c,
                          child: Text(
                              '${c.name} (Credit: \$${(c.creditLimit - c.outstandingBalance).toStringAsFixed(0)})'),
                        );
                      }).toList(),
                      onChanged: (c) => setState(() => _selectedCustomer = c),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text('Order Line Items',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                ..._catalog.map((p) {
                  final qty = _quantities[p.id] ?? 0;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.black12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(p.name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14)),
                              Text('\$${p.unitPrice.toStringAsFixed(2)} / unit',
                                  style: TextStyle(
                                      color: Colors.grey.shade600,
                                      fontSize: 12)),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(CupertinoIcons.minus_circle),
                          onPressed: qty > 0
                              ? () => setState(
                                  () => _quantities[p.id] = qty - 1)
                              : null,
                        ),
                        Text('$qty',
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                        IconButton(
                          icon: const Icon(CupertinoIcons.plus_circle),
                          onPressed: () =>
                              setState(() => _quantities[p.id] = qty + 1),
                        ),
                      ],
                    ),
                  );
                }),
                const SizedBox(height: 14),
                // Rejection simulator switch
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: CupertinoColors.systemOrange.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: CupertinoColors.systemOrange.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(CupertinoIcons.shield_slash,
                          color: CupertinoColors.systemOrange),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Test 422 Rejection Rollback',
                                style: TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 13)),
                            Text(
                                'Rejects order if over credit limit to prove baseline rollback',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.black54)),
                          ],
                        ),
                      ),
                      CupertinoSwitch(
                        value: _simulate422Rejection,
                        onChanged: (val) =>
                            setState(() => _simulate422Rejection = val),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Bottom action summary
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, -4),
                ),
              ],
            ),
            child: SafeArea(
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Total Amount',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey)),
                      Text(
                        '\$${_totalAmount.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: isOverLimit && _simulate422Rejection
                              ? CupertinoColors.systemRed
                              : AppleTheme.accentBlue,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: ApplePressable(
                      onTap: _totalAmount > 0 && !_isSubmitting
                          ? _submit
                          : null,
                      child: Container(
                        height: 50,
                        decoration: BoxDecoration(
                          color: _totalAmount > 0
                              ? AppleTheme.accentBlue
                              : Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          _isSubmitting
                              ? 'Saving...'
                              : 'Confirm Order (0ms Save)',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
