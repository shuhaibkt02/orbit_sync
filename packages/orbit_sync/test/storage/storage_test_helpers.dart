import 'dart:convert';
import 'dart:io';
import 'package:orbit_sync/offline_sync.dart';

/// Helper to create and initialize an isolated SyncStorage instance with a temp directory.
Future<({Directory tempDir, SyncStorage storage})> createTestStorage() async {
  final tempDir = Directory.systemTemp.createTempSync('offline_sync_test_');
  final storage = await SyncStorage.open(
    path: '${tempDir.path}/test_sync.db',
    maxReaders: 4,
  );
  await storage.registerEntityTable('tasks', {
    'title': 'TEXT',
    'priority': 'TEXT',
  });
  return (tempDir: tempDir, storage: storage);
}

/// Realistic domain model defined by an external Flutter app developer.
class MockExternalOrder {
  final String id;
  final String customerId;
  final double totalAmount;
  final int itemCount;
  final bool isTaxExempt;
  final Map<String, dynamic> metadata;
  final DateTime createdAt;

  MockExternalOrder({
    required this.id,
    required this.customerId,
    required this.totalAmount,
    required this.itemCount,
    required this.isTaxExempt,
    required this.metadata,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'customer_id': customerId,
    'total_amount': totalAmount,
    'item_count': itemCount,
    'is_tax_exempt': isTaxExempt,
    'metadata': metadata,
    'created_at_iso': createdAt.toIso8601String(),
  };

  factory MockExternalOrder.fromJson(Map<String, dynamic> json) => MockExternalOrder(
    id: json['id'] as String,
    customerId: json['customer_id'] as String,
    totalAmount: (json['total_amount'] as num).toDouble(),
    itemCount: json['item_count'] as int,
    isTaxExempt: json['is_tax_exempt'] == 1 || json['is_tax_exempt'] == true,
    metadata: json['metadata'] is String
        ? jsonDecode(json['metadata'] as String) as Map<String, dynamic>
        : json['metadata'] as Map<String, dynamic>,
    createdAt: DateTime.parse(json['created_at_iso'] as String),
  );
}

class MockOutboxRepo implements IOutboxRepository {
  bool saveCalled = false;

  @override
  Future<String> save({
    required String entity,
    required String id,
    required Map<String, dynamic> data,
    int version = 1,
    String? dependsOnMutationId,
    int schemaVersion = 1,
    String? endpointUrl,
    String? httpMethod,
    Duration? holdFor,
    Duration? sla,
    Duration? ttl,
    int priority = 0,
    String? correlationTag,
  }) async {
    saveCalled = true;
    return 'mock-mutation-id';
  }

  @override
  Future<String?> delete({
    required String entity,
    required String id,
    String? endpointUrl,
    String? httpMethod,
    Duration? undoWindow,
  }) async => null;

  @override
  Future<bool> undoDelete({required String entity, required String id}) async => true;

  @override
  Future<void> rollbackOptimistic(String mutationId, {String status = 'conflict'}) async {}

  @override
  Future<int> pruneSynced({Duration olderThan = const Duration(days: 7)}) async => 0;

  @override
  Future<int> pruneExpiredCache(String entity) async => 0;

  @override
  Future<void> registerEntityTable(
    String entityName,
    Map<String, String> columnTypes, {
    String? foreignKeyClause,
  }) async {}

  @override
  Future<ResultSet> query(String query, [List<dynamic> parameters = const []]) async =>
      throw UnimplementedError();

  @override
  Stream<ResultSet> watch(String query, {List<dynamic> parameters = const []}) =>
      const Stream.empty();

  @override
  Future<void> checkpoint({bool truncate = false}) async {}

  @override
  Future<void> close() async {}
}

class MockIdMapRepo implements IIdMapRepository {
  bool registerCalled = false;

  @override
  Future<void> registerServerId({
    required String entity,
    required String localTempId,
    required String canonicalServerId,
  }) async {
    registerCalled = true;
  }

  @override
  Future<String?> getCanonicalServerId({
    required String entity,
    required String localTempId,
  }) async => 'mock-canonical-id';

  @override
  Future<String?> getLocalTempId({
    required String entity,
    required String canonicalServerId,
  }) async => 'mock-temp-id';
}
