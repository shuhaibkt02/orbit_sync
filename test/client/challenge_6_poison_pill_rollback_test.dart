import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'package:orbit_sync/src/client/domain/policies/causal_horizon_guard.dart';

void main() {
  late Directory tempDir;
  late SyncStorage storage;
  late CausalHorizonGuard guard;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('layer5_challenge6_');
    storage = await SyncStorage.open(path: '${tempDir.path}/test.db');
    guard = CausalHorizonGuard(storage);
    await storage.registerEntityTable('forms', {'notes': 'TEXT'});
  });

  tearDown(() async {
    await storage.close();
    tempDir.deleteSync(recursive: true);
  });

  group('Layer 5 Facade: Challenge 6 Causal Horizon Guard & Soft Rejection',
      () {
    test(
        'CausalHorizonGuard detects newer pending edits and protects domain state',
        () async {
      final t1 = DateTime.now().millisecondsSinceEpoch - 10000;

      // Old mutation at t1
      await storage
          .save(entity: 'forms', id: 'form-1', data: {'notes': 'Old draft'});
      // Newer mutation
      await storage
          .save(entity: 'forms', id: 'form-1', data: {'notes': 'Newer draft'});

      final hasNewer = await guard.hasNewerPendingMutations(
        entity: 'forms',
        id: 'form-1',
        failedCreatedAtMs: t1,
      );
      expect(hasNewer, isTrue);
    });

    test('Soft rejection preserves user form data instead of hard deleting',
        () async {
      await storage.save(
          entity: 'forms',
          id: 'form-99',
          data: {'notes': 'Important field data'});

      // Soft reject on HTTP 422
      await guard.softRejectRecord(
        entity: 'forms',
        id: 'form-99',
        errorMessage: 'Invalid postal code',
      );

      final row = await storage.db
          .getAll('SELECT * FROM forms WHERE id = ?', ['form-99']);
      expect(row.length, equals(1));
      final decoded = jsonDecode(row.first['data_json'] as String);
      expect(decoded['notes'], equals('Important field data'));
      expect(row.first['_sync_status'], equals('rejected'));
      expect(row.first['_sync_error'], equals('Invalid postal code'));
    });

    test('Recursive CTE holds descendant mutations when parent is rejected',
        () async {
      await storage.registerEntityTable('orders', {'title': 'TEXT'});
      await storage.registerEntityTable('order_items', {'order_id': 'TEXT'});

      final parentMutId = await storage
          .save(entity: 'orders', id: 'ord-1', data: {'title': 'Order 1'});
      final childMutId = await storage.save(
        entity: 'order_items',
        id: 'item-1',
        data: {'order_id': 'ord-1'},
        dependsOnMutationId: parentMutId,
      );

      // Parent fails -> hold children
      await guard.holdDescendantMutations(parentMutId);

      final childRow = await storage.db.getAll(
        'SELECT status FROM _sync_outbox WHERE mutation_id = ?',
        [childMutId],
      );
      expect(childRow.first['status'], equals('held'));
    });
  });
}
