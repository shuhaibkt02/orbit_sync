import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:offline_sync/offline_sync.dart';

/// Minimal in-memory transport to verify zero-HTTP transport decoupling.
class InMemorySyncTransport implements SyncTransport {
  final List<Map<String, dynamic>> pushedBatches = [];
  final List<Map<String, dynamic>> serverChanges = [];
  final StreamController<void> _changeCtrl = StreamController<void>.broadcast();

  int nextCursor = 1;
  int pushStatusCode = 200;

  @override
  Stream<void> get onRemoteChange => _changeCtrl.stream;

  void triggerRemoteChange() => _changeCtrl.add(null);

  @override
  Future<TransportResponse> pushBatch({
    required List<Map<String, dynamic>> mutations,
    required String idempotencyKey,
    String? chaos,
  }) async {
    if (pushStatusCode != 200) {
      return TransportResponse(statusCode: pushStatusCode, body: 'Simulated failure');
    }
    pushedBatches.addAll(mutations);
    return TransportResponse(
      statusCode: 200,
      body: jsonEncode({'applied': mutations.length}),
    );
  }

  @override
  Future<TransportResponse> pushCustom({
    required String url,
    required String method,
    required String mutationId,
    required int createdAtMs,
    Map<String, dynamic>? payload,
    String? entityId,
  }) async {
    return const TransportResponse(statusCode: 200);
  }

  @override
  Future<TransportResponse> pull({
    required int sinceCursor,
    required int limit,
    Map<String, dynamic>? scopeFilter,
    bool snapshot = false,
    String? chaos,
  }) async {
    return TransportResponse(
      statusCode: 200,
      body: jsonEncode({
        'changes': serverChanges,
        'next_cursor': nextCursor,
        'has_more': false,
      }),
    );
  }

  @override
  void dispose() {
    _changeCtrl.close();
  }
}

void main() {
  late Directory tempDir;
  late SyncStorage storage;
  late InMemorySyncTransport transport;
  late SyncWorker worker;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('sync_transport_test_');
    storage = await SyncStorage.open(path: '${tempDir.path}/test.db');
    await storage.registerEntityTable('items', {'name': 'TEXT'});
    transport = InMemorySyncTransport();
    worker = SyncWorker(storage: storage, transport: transport);
  });

  tearDown(() async {
    worker.dispose();
    await storage.close();
    tempDir.deleteSync(recursive: true);
  });

  test('SyncWorker executes push and pull via custom in-memory transport without HTTP', () async {
    // 1. Enqueue local mutation
    await storage.save(entity: 'items', id: 'item-1', data: {'name': 'Widget'});

    // 2. Push batch via in-memory transport
    final pushRes = await worker.pushBatch();
    expect(pushRes.status, equals(SyncPushStatus.success));
    expect(pushRes.applied, equals(1));
    expect(transport.pushedBatches.length, equals(1));
    expect(transport.pushedBatches.first['id'], equals('item-1'));

    // 3. Mock incoming remote server change
    transport.serverChanges.add({
      'entity': 'items',
      'id': 'item-2',
      'version': 1,
      'data': {'name': 'Gizmo'},
    });
    transport.nextCursor = 2;

    // 4. Pull page via in-memory transport
    final pullRes = await worker.pullPage();
    expect(pullRes.status, equals(SyncPullStatus.success));
    expect(pullRes.changeCount, equals(1));

    // 5. Verify local SQLite table updated from transport pull
    final rows = await storage.query('SELECT * FROM items WHERE id = ?', ['item-2']);
    expect(rows.length, equals(1));
    expect(rows.first['name'], equals('Gizmo'));
  });

  test('Transport onRemoteChange triggers auto-sync', () async {
    transport.serverChanges.add({
      'entity': 'items',
      'id': 'item-auto',
      'version': 1,
      'data': {'name': 'Automated'},
    });
    transport.nextCursor = 10;

    // Fire remote change signal
    transport.triggerRemoteChange();

    // Allow event queue to process
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final rows = await storage.query('SELECT * FROM items WHERE id = ?', ['item-auto']);
    expect(rows.length, equals(1));
    expect(rows.first['name'], equals('Automated'));
  });
}
