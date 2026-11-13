import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

class MockOfflineMonitor implements ConnectivityMonitor {
  bool _online = false;
  final _controller = StreamController<bool>.broadcast();

  MockOfflineMonitor({bool isOnline = false}) : _online = isOnline;

  @override
  bool get isOnline => _online;

  void setOnline(bool online) {
    _online = online;
    _controller.add(online);
  }

  @override
  Stream<bool> get onConnectivityChanged => _controller.stream;

  void attachExternalConnectivity(Stream<bool> rawStream) {}

  @override
  Future<bool> checkReachability(
          {String? targetUrl, bool bypassDebounce = false}) async =>
      _online;

  @override
  Future<void> dispose() async => await _controller.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestItem {
  final String id;
  final String title;
  final double amount;
  final int? expiresAt;
  final bool isStale;

  TestItem({
    required this.id,
    required this.title,
    required this.amount,
    this.expiresAt,
    this.isStale = false,
  });

  factory TestItem.fromJson(Map<String, dynamic> j) => TestItem(
        id: j['id'] as String,
        title: j['title'] as String,
        amount: (j['amount'] as num?)?.toDouble() ?? 0.0,
        expiresAt: j['expires_at'] as int?,
        isStale: j['isStale'] == true || j['is_stale'] == true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'amount': amount,
        if (expiresAt != null) 'expires_at': expiresAt,
      };
}

void main() {
  late Directory tempDir;
  late SyncStorage storage;
  late OrbitTable<TestItem> table;

  setUp(() async {
    tempDir =
        Directory.systemTemp.createTempSync('orbit_pagination_cache_test_');
    storage = await SyncStorage.open(path: '${tempDir.path}/test.db');

    table = OrbitTable<TestItem>(
      name: 'items',
      primaryKey: 'id',
      fromJson: TestItem.fromJson,
      toJson: (item) => item.toJson(),
      storage: storage,
    );

    await storage.registerEntityTable('items', {});
  });

  tearDown(() async {
    await storage.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('Ticket 03: Native Pagination & Non-Destructive Offline Cache', () {
    test(
        '1. Native pagination: limit and offset correctly slice results ordered by updated_at DESC',
        () async {
      final now = DateTime.now().millisecondsSinceEpoch;

      // Seed 6 items with sequential updated_at timestamps
      for (var i = 1; i <= 6; i++) {
        final itemJson = jsonEncode(
            {'id': 'item-$i', 'title': 'Item $i', 'amount': i * 10.0});
        await storage.db.execute('''
          INSERT INTO "items" (id, version, updated_at, expires_at, data_json)
          VALUES (?, 1, ?, null, ?)
        ''', ['item-$i', now + (i * 100), itemJson]);
      }

      // Page 1: limit 2, offset 0 -> item-6, item-5 (latest updated_at first)
      final page1 = await table.query(limit: 2, offset: 0);
      expect(page1.length, equals(2));
      expect(page1[0].id, equals('item-6'));
      expect(page1[1].id, equals('item-5'));

      // Page 2: limit 2, offset 2 -> item-4, item-3
      final page2 = await table.query(limit: 2, offset: 2);
      expect(page2.length, equals(2));
      expect(page2[0].id, equals('item-4'));
      expect(page2[1].id, equals('item-3'));

      // Page 3: limit 2, offset 4 -> item-2, item-1
      final page3 = await table.query(limit: 2, offset: 4);
      expect(page3.length, equals(2));
      expect(page3[0].id, equals('item-2'));
      expect(page3[1].id, equals('item-1'));

      // Page 4: offset beyond dataset -> empty
      final page4 = await table.query(limit: 2, offset: 10);
      expect(page4, isEmpty);
    });

    test(
        '2. Dart predicate filtering evaluates lazily and respects limit and offset',
        () async {
      final now = DateTime.now().millisecondsSinceEpoch;

      // Seed 10 items (even amounts 20, 40, 60, 80, 100)
      for (var i = 1; i <= 10; i++) {
        final itemJson = jsonEncode(
            {'id': 'item-$i', 'title': 'Item $i', 'amount': i * 10.0});
        await storage.db.execute('''
          INSERT INTO "items" (id, version, updated_at, expires_at, data_json)
          VALUES (?, 1, ?, null, ?)
        ''', ['item-$i', now + (i * 100), itemJson]);
      }

      // Filter for items with amount >= 40.0 (items 4, 5, 6, 7, 8, 9, 10 in updated_at DESC: 10, 9, 8, 7, 6, 5, 4)
      // With offset 2, limit 3 -> should take items 8, 7, 6
      final filtered = await table.query(
        where: (TestItem item) => item.amount >= 40.0,
        offset: 2,
        limit: 3,
      );

      expect(filtered.length, equals(3));
      expect(filtered[0].id, equals('item-8'));
      expect(filtered[1].id, equals('item-7'));
      expect(filtered[2].id, equals('item-6'));
    });

    test(
        '3. watch() emits paginated slices reactively as records are added or updated',
        () async {
      final now = DateTime.now().millisecondsSinceEpoch;

      // Seed 2 initial items
      for (var i = 1; i <= 2; i++) {
        final itemJson = jsonEncode(
            {'id': 'item-$i', 'title': 'Item $i', 'amount': i * 10.0});
        await storage.db.execute('''
          INSERT INTO "items" (id, version, updated_at, expires_at, data_json)
          VALUES (?, 1, ?, null, ?)
        ''', ['item-$i', now + (i * 100), itemJson]);
      }

      final emittedSlices = <List<TestItem>>[];
      final completer = Completer<void>();

      // Watch limit 2, offset 0
      final sub = table.watch(limit: 2, offset: 0).listen((items) {
        emittedSlices.add(items);
        if (emittedSlices.length == 2 && !completer.isCompleted) {
          completer.complete();
        }
      });

      // Allow initial stream emission
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // Insert item-3 with higher updated_at (should replace item-1 in the top-2 window)
      final newItemJson =
          jsonEncode({'id': 'item-3', 'title': 'Item 3', 'amount': 30.0});
      await storage.db.execute('''
        INSERT INTO "items" (id, version, updated_at, expires_at, data_json)
        VALUES ('item-3', 1, ?, null, ?)
      ''', [now + 1000, newItemJson]);

      await completer.future.timeout(const Duration(seconds: 3));
      await sub.cancel();

      expect(emittedSlices.length, greaterThanOrEqualTo(2));
      // First emission: item-2, item-1
      expect(emittedSlices.first.map((i) => i.id).toList(),
          equals(['item-2', 'item-1']));
      // Latest emission after insert: item-3, item-2
      expect(emittedSlices.last.map((i) => i.id).toList(),
          equals(['item-3', 'item-2']));
    });

    test(
        '4. Non-Destructive Invalidation: isStale is true when expires_at <= now without deleting data',
        () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final pastExpiry = now - 5000; // Expired 5 seconds ago

      final expiredJson = jsonEncode({
        'id': 'exp-1',
        'title': 'Expired Document',
        'amount': 99.0,
        'expires_at': pastExpiry,
      });

      await storage.db.execute('''
        INSERT INTO "items" (id, version, updated_at, expires_at, data_json)
        VALUES ('exp-1', 1, ?, ?, ?)
      ''', [now, pastExpiry, expiredJson]);

      // 1. get() returns existing data with isStale: true (NEVER deleted!)
      final cachedItem = await table.get('exp-1');
      expect(cachedItem, isNotNull);
      expect(cachedItem!.id, equals('exp-1'));
      expect(cachedItem.title, equals('Expired Document'));
      expect(cachedItem.isStale, isTrue);

      // 2. getRecord() returns OrbitRecord with isStale: true
      final record = await table.getRecord('exp-1');
      expect(record, isNotNull);
      expect(record!.data.id, equals('exp-1'));
      expect(record.expiresAt, equals(pastExpiry));
      expect(record.isStale, isTrue);

      // 3. query() returns the stale record intact
      final queryItems = await table.query();
      expect(queryItems.length, equals(1));
      expect(queryItems.first.isStale, isTrue);

      // 4. queryRecords() returns OrbitRecord with isStale: true
      final records = await table.queryRecords();
      expect(records.length, equals(1));
      expect(records.first.isStale, isTrue);

      // Verify row still physically exists in SQLite
      final rawCheck = await storage.db
          .getAll('SELECT id FROM items WHERE id = ?', ['exp-1']);
      expect(rawCheck, isNotEmpty);
    });

    test(
        '5. Outbox-Guarded Background Purge: expired record with pending outbox mutation is NEVER purged',
        () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final pastExpiry = now - 10000;

      // Row A: Expired cache record from server (NO pending outbox mutation)
      final cleanJson = jsonEncode(
          {'id': 'clean-expired', 'title': 'Clean Item', 'amount': 10.0});
      await storage.db.execute('''
        INSERT INTO "items" (id, version, updated_at, expires_at, data_json)
        VALUES ('clean-expired', 1, ?, ?, ?)
      ''', [now, pastExpiry, cleanJson]);

      // Row B: Expired cache record WITH a pending outbox mutation
      final dirtyJson = jsonEncode({
        'id': 'dirty-expired',
        'title': 'Unsynced User Edit',
        'amount': 50.0
      });
      await storage.db.execute('''
        INSERT INTO "items" (id, version, updated_at, expires_at, data_json)
        VALUES ('dirty-expired', 1, ?, ?, ?)
      ''', [now, pastExpiry, dirtyJson]);

      // Create pending outbox mutation for Row B
      await storage.db.execute('''
        INSERT INTO _sync_outbox (mutation_id, entity_name, entity_id, op, payload_json, base_version, status, created_at, updated_at)
        VALUES ('mut-dirty', 'items', 'dirty-expired', 'upsert', ?, 1, 'pending', ?, ?)
      ''', [dirtyJson, now, now]);

      // Execute background cache prune
      final prunedCount = await storage.pruneExpiredCache('items');

      // Assert Row A was purged
      expect(prunedCount, equals(1));
      final cleanCheck = await storage.db
          .getAll('SELECT id FROM items WHERE id = ?', ['clean-expired']);
      expect(cleanCheck, isEmpty);

      // Assert Row B was strictly protected by the outbox guard!
      final dirtyCheck = await storage.db
          .getAll('SELECT id FROM items WHERE id = ?', ['dirty-expired']);
      expect(dirtyCheck, isNotEmpty);
      expect(dirtyCheck.first['id'], equals('dirty-expired'));
    });

    test(
        '6. Pull-to-refresh while offline returns RefreshResult.offline without deleting cached rows',
        () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final pastExpiry = now - 5000;

      // Populate local cache with 2 rows (one stale, one fresh)
      await storage.db.execute('''
        INSERT INTO "items" (id, version, updated_at, expires_at, data_json)
        VALUES ('item-stale', 1, ?, ?, ?)
      ''', [
        now,
        pastExpiry,
        jsonEncode({'id': 'item-stale', 'title': 'Stale Item', 'amount': 15.0})
      ]);

      await storage.db.execute('''
        INSERT INTO "items" (id, version, updated_at, expires_at, data_json)
        VALUES ('item-fresh', 1, ?, null, ?)
      ''', [
        now,
        jsonEncode({'id': 'item-fresh', 'title': 'Fresh Item', 'amount': 25.0})
      ]);

      // Setup table with mock offline monitor
      final offlineMonitor = MockOfflineMonitor(isOnline: false);
      final offlineTable = OrbitTable<TestItem>(
        name: 'items',
        primaryKey: 'id',
        fromJson: TestItem.fromJson,
        toJson: (item) => item.toJson(),
        storage: storage,
        connectivity: offlineMonitor,
        restEndpoint: RestEndpoint(path: '/items'),
      );

      // User pulls to refresh while offline
      final result = await offlineTable.refresh();

      // Assert typed result is offline
      expect(result.isOffline, isTrue);
      expect(result.status, equals(RefreshStatus.offline));
      expect(result, equals(RefreshResult.offline));

      // Assert ZERO rows were wiped or deleted from local cache
      final rowsRemaining =
          await storage.db.getAll('SELECT id FROM items ORDER BY id');
      expect(rowsRemaining.length, equals(2));
      expect(rowsRemaining.map((r) => r['id']).toList(),
          equals(['item-fresh', 'item-stale']));
    });

    test(
        '7. Network exception during fetch returns RefreshResult.offline and preserves cache',
        () async {
      final now = DateTime.now().millisecondsSinceEpoch;

      await storage.db.execute('''
        INSERT INTO "items" (id, version, updated_at, expires_at, data_json)
        VALUES ('cached-1', 1, ?, null, ?)
      ''', [
        now,
        jsonEncode(
            {'id': 'cached-1', 'title': 'Existing Cache', 'amount': 100.0})
      ]);

      // Custom client that throws SocketException (simulating network dropping during probe)
      final clientMock = _FaultyHttpClient(
          errorToThrow: const SocketException('No route to host'));

      final faultyTable = OrbitTable<TestItem>(
        name: 'items',
        primaryKey: 'id',
        baseUrl: 'https://api.example.com',
        fromJson: TestItem.fromJson,
        toJson: (item) => item.toJson(),
        storage: storage,
        httpClient: clientMock,
        restEndpoint: RestEndpoint(path: '/items'),
      );

      final result = await faultyTable.fetch();

      expect(result.isOffline, isTrue);
      expect(result.status, equals(RefreshStatus.offline));

      // Cache remains completely intact
      final rows = await storage.db
          .getAll('SELECT id FROM items WHERE id = ?', ['cached-1']);
      expect(rows.length, equals(1));
    });
  });
}

class _FaultyHttpClient extends http.BaseClient {
  final Object errorToThrow;

  _FaultyHttpClient({required this.errorToThrow});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw errorToThrow;
  }
}
