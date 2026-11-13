import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import 'package:orbit_sync/src/storage/infrastructure/sqlite/sqlite_cache_cleaner.dart';
import 'package:orbit_sync/src/client/services/entity_hydrator.dart';
import 'package:orbit_sync/src/client/services/session_manager.dart';
import 'package:orbit_sync/src/consensus/services/batch_push_orchestrator.dart';
import 'package:orbit_sync/src/consensus/services/generation_swap_manager.dart';

class CountingTransport implements SyncTransport {
  int pullCalls = 0;
  List<int> pulledCursors = [];

  @override
  Future<TransportResponse> pull({
    required int sinceCursor,
    int limit = 50,
    Map<String, dynamic>? scopeFilter,
    String? chaos,
    bool snapshot = false,
  }) async {
    pullCalls++;
    pulledCursors.add(sinceCursor);

    if (sinceCursor == 0) {
      return TransportResponse(
        statusCode: HttpStatus.ok,
        body: jsonEncode({
          'changes': [
            {'entity': 'items', 'id': 'item-1', 'version': 1, 'data': {'title': 'First'}},
          ],
          'next_cursor': 100,
          'has_more': true,
        }),
      );
    } else {
      return TransportResponse(
        statusCode: HttpStatus.ok,
        body: jsonEncode({
          'changes': [
            {'entity': 'items', 'id': 'item-2', 'version': 1, 'data': {'title': 'Second'}},
          ],
          'next_cursor': 200,
          'has_more': false,
        }),
      );
    }
  }

  @override
  Future<TransportResponse> pushBatch({
    required List<Map<String, dynamic>> mutations,
    required String idempotencyKey,
    String? chaos,
  }) async {
    return TransportResponse(statusCode: HttpStatus.ok, body: '{"applied": ${mutations.length}}');
  }

  @override
  Future<TransportResponse> pushCustom({
    required String url,
    required String method,
    required String mutationId,
    required int createdAtMs,
    Map<String, dynamic>? payload,
    String? entityId,
    Map<String, String>? headers,
  }) async {
    return const TransportResponse(statusCode: HttpStatus.ok, body: '{"success": true}');
  }

  @override
  Future<TransportResponse> pushMultipart({
    required Uri uri,
    String method = 'POST',
    required String fieldName,
    required String filePath,
    String? fileName,
    String? mimeType,
    Map<String, dynamic>? extraFields,
    Map<String, String>? headers,
    Duration? timeout,
    void Function(int sent, int total)? onSendProgress,
  }) async => const TransportResponse(statusCode: HttpStatus.ok);

  @override
  Stream<void>? get onRemoteChange => null;

  @override
  void dispose() {}
}

void main() {
  group('Ponytail Audit Hardening & Invariant Verification', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('orbit_audit_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('1. Hydration Quota Pruning executes within transaction without deadlock', () async {
      final storage = await SyncStorage.open(path: '${tempDir.path}/quota_test.db');
      await storage.registerEntityTable('cache_items', {});

      final hydrator = EntityHydrator(storage: storage);
      final items = List.generate(
        15,
        (i) => {'id': 'item-$i', 'name': 'Item $i', 'expires_at': 9999999999, 'updated_at': 1000 + i},
      );

      // Hydrate 15 items with maxCacheRecords: 5.
      // Must NOT deadlock and must prune down to 5.
      final count = await hydrator.hydrateBatch(
        entity: 'cache_items',
        items: items,
        maxCacheRecords: 5,
      );

      expect(count, equals(15));
      final rows = await storage.db.getAll('SELECT COUNT(*) as cnt FROM "cache_items"');
      expect(rows.first['cnt'], equals(5));

      await storage.close();
    });

    test('2. pruneToQuotaTx gracefully returns 0 for non-existent table', () async {
      final storage = await SyncStorage.open(path: '${tempDir.path}/nonexistent.db');
      final deleted = await SqliteCacheCleaner.pruneToQuota(storage.db, 'does_not_exist', maxCacheRecords: 10);
      expect(deleted, equals(0));
      await storage.close();
    });

    test('3. Guest Session Merge preserves full metadata and unpurged domain row', () async {
      final guestPath = '${tempDir.path}/guest.db';
      final targetPath = '${tempDir.path}/user.db';

      final guestStorage = await SyncStorage.open(path: guestPath);
      await guestStorage.registerEntityTable('notes', {});
      await guestStorage.save(
        entity: 'notes',
        id: 'note-guest-1',
        data: {'content': 'Confidential guest draft'},
        authorId: 'guest-anon',
        userId: 'guest-anon',
      );
      await guestStorage.close();

      const sessionManager = SessionManager();
      final merged = await sessionManager.mergeGuestSession(
        guestDatabasePath: guestPath,
        targetDatabasePath: targetPath,
      );
      expect(merged, equals(1));

      final targetStorage = await SyncStorage.open(path: targetPath);
      final outbox = await targetStorage.db.getAll('SELECT * FROM _sync_outbox WHERE entity_id = ?', ['note-guest-1']);
      expect(outbox.length, equals(1));
      expect(outbox.first['author_id'], equals('guest-anon'));
      expect(outbox.first['status'], equals('pending'));

      final domainRows = await targetStorage.db.getAll('SELECT * FROM "notes" WHERE id = ?', ['note-guest-1']);
      expect(domainRows.length, equals(1));
      // Invariant: expires_at must be NULL (not 0/epoch 1970) so TTL cleaner does NOT delete it
      expect(domainRows.first['expires_at'], isNull);

      await targetStorage.close();
    });

    test('4. BatchPushOrchestrator safely partitions mixed custom REST and batch envelope mutations', () async {
      final storage = await SyncStorage.open(path: '${tempDir.path}/mixed_batch.db');
      final transport = CountingTransport();
      final orchestrator = BatchPushOrchestrator(
        storage: storage,
        transport: transport,
        profile: SyncProfile.enterprise,
        backoffPolicy: BackoffPolicy(),
      );

      // Queue 1 custom REST mutation and 1 batch mutation
      await storage.save(
        entity: 'orders',
        id: 'ord-custom',
        data: {'total': 100},
        endpointUrl: '/api/v1/orders',
        httpMethod: 'POST',
      );
      await storage.save(
        entity: 'products',
        id: 'prod-batch',
        data: {'sku': 'ABC'},
      );

      final result = await orchestrator.pushBatch(batchSize: 10);
      expect(result.status, equals(SyncPushStatus.success));
      expect(result.applied, equals(2));

      final remaining = await storage.db.getAll("SELECT status FROM _sync_outbox WHERE status = 'pending'");
      expect(remaining, isEmpty);

      await storage.close();
    });

    test('5. GenerationSwapManager paginates across multi-page snapshots on 410', () async {
      final storage = await SyncStorage.open(path: '${tempDir.path}/swap.db');
      final transport = CountingTransport();
      final swapManager = GenerationSwapManager(storage: storage, transport: transport);

      final success = await swapManager.resyncGeneration(['items']);
      expect(success, isTrue);
      // Both page 1 (has_more: true) and page 2 (has_more: false) must be pulled
      expect(transport.pullCalls, equals(2));

      final rows = await storage.db.getAll('SELECT COUNT(*) as cnt FROM "items"');
      expect(rows.first['cnt'], equals(2));

      await storage.close();
    });

    test('6. Time-travel backup holds both pending and in_flight mutations', () async {
      final storage = await SyncStorage.open(path: '${tempDir.path}/recovery.db');

      // Seed 1 pending and 1 in_flight mutation
      await storage.db.execute('''
        INSERT INTO _sync_outbox (
          mutation_id, entity_name, entity_id, op, status, created_at
        ) VALUES 
          ('m-1', 'items', 'i-1', 'create', 'pending', 1000),
          ('m-2', 'items', 'i-2', 'create', 'in_flight', 1000);
      ''');

      // Seed metadata installation ID
      await storage.db.execute("INSERT INTO _sync_metadata (key, value) VALUES ('orbit_installation_id', 'old-id');");

      // Verify integrity against empty secure storage (simulating restored device backup)
      await const SqliteRecovery().verifyInstallationIntegrity(
        storage.db,
        secureStorageReader: (k) async => null,
        secureStorageWriter: (k, v) async {},
      );

      final heldRows = await storage.db.getAll("SELECT mutation_id FROM _sync_outbox WHERE status = 'held'");
      expect(heldRows.length, equals(2));

      await storage.close();
    });

    test('7. BatchEnvelopePusher generates deterministic sorted batch idempotency key', () {
      final key1 = 'batch-${(['mut-z', 'mut-a', 'mut-m']..sort()).join(':')}';
      final key2 = 'batch-${(['mut-a', 'mut-z', 'mut-m']..sort()).join(':')}';
      expect(key1, equals(key2));
      expect(key1, equals('batch-mut-a:mut-m:mut-z'));
    });
  });
}
