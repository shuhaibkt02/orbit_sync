class Product {
  final String id;
  final String sku;
  final String name;
  final double unitPrice;
  final int stockQuantity;
  final String category;

  const Product({
    required this.id,
    required this.sku,
    required this.name,
    required this.unitPrice,
    required this.stockQuantity,
    this.category = 'General',
  });

  factory Product.fromJson(Map<String, dynamic> json) => Product(
        id: json['id'] as String,
        sku: json['sku'] as String,
        name: json['name'] as String,
        unitPrice: (json['unit_price'] as num).toDouble(),
        stockQuantity: (json['stock_quantity'] as num).toInt(),
        category: json['category'] as String? ?? 'General',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'sku': sku,
        'name': name,
        'unit_price': unitPrice,
        'stock_quantity': stockQuantity,
        'category': category,
      };
}
