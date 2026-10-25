import 'dart:io';
import 'package:test/test.dart';
import 'package:offline_sync/offline_sync.dart';
import 'package:offline_sync/src/client/domain/policies/sqlite_type_sanitizer.dart';

class TestProduct {
  final String id;
  final String title;
  final double price;
  final bool inStock;
  final Map<String, dynamic> metadata;

  TestProduct({
    required this.id,
    required this.title,
    required this.price,
    required this.inStock,
    required this.metadata,
  });

  factory TestProduct.fromJson(Map<String, dynamic> json) => TestProduct(
        id: json['id'] as String,
        title: json['title'] as String,
        price: (json['price'] as num).toDouble(),
        inStock: json['in_stock'] == 1 || json['in_stock'] == true,
        metadata: (json['metadata'] is String)
            ? {}
            : (json['metadata'] as Map<String, dynamic>? ?? {}),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'price': price,
        'in_stock': inStock,
        'metadata': metadata,
      };
}

void main() {
  late Directory tempDir;
  late OfflineSyncClient client;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('layer5_challenge4_');
    client = await OfflineSyncClient.initialize(
      databasePath: '${tempDir.path}/test.db',
    );
  });

  tearDown(() async {
    await client.close();
    tempDir.deleteSync(recursive: true);
  });

  group('Layer 5 Facade: Challenge 4 Strongly-Typed OrbitTable & SQLite Type Sanitizer', () {
    test('SqliteTypeSanitizer automatically converts booleans, dates, and nested maps', () {
      const sanitizer = SqliteTypeSanitizer();
      final now = DateTime.now();

      final input = {
        'active': true,
        'inactive': false,
        'created_at': now,
        'tags': ['flutter', 'sqlite'],
        'nested': {'city': 'Berlin'},
      };

      final sanitized = sanitizer.sanitizeMap(input);
      expect(sanitized['active'], equals(1));
      expect(sanitized['inactive'], equals(0));
      expect(sanitized['created_at'], equals(now.millisecondsSinceEpoch));
      expect(sanitized['tags'], equals('["flutter","sqlite"]'));
      expect(sanitized['nested'], equals('{"city":"Berlin"}'));
    });

    test('registerModel provides typed CRUD and automatic index registration', () async {
      final products = client.registerModel<TestProduct>(
        name: 'products',
        fromJson: TestProduct.fromJson,
        toJson: (p) => p.toJson(),
        indexes: ['price'],
      );

      // Save typed model
      final product = TestProduct(
        id: 'prod-1',
        title: 'Ergonomic Keyboard',
        price: 199.99,
        inStock: true,
        metadata: {'layout': 'ANSI'},
      );

      final savedId = await products.save(product);
      expect(savedId, equals('prod-1'));

      // Retrieve typed model
      final restored = await products.get('prod-1');
      expect(restored, isNotNull);
      expect(restored!.title, equals('Ergonomic Keyboard'));
      expect(restored.inStock, isTrue);

      // Delete with undo window
      await products.delete('prod-1', undoWindow: const Duration(seconds: 10));
      final undoSuccess = await products.undoDelete('prod-1');
      expect(undoSuccess, isTrue);
    });
  });
}
