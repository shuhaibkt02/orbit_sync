import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

class Order {
  final String? id;
  final String title;
  final double amount;
  final OrbitAttachment? attachment;

  Order({this.id, required this.title, required this.amount, this.attachment});

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'title': title,
        'amount': amount,
        if (attachment != null) 'receipt': attachment!.toJson(),
      };

  factory Order.fromJson(Map<String, dynamic> json) => Order(
        id: json['id']?.toString(),
        title: (json['title'] ?? '').toString(),
        amount: (json['amount'] as num?)?.toDouble() ?? 0.0,
        attachment: json['receipt'] != null ? OrbitAttachment.fromJson(json['receipt'] as Map<String, dynamic>) : null,
      );
}

void main() {
  group('Blueprint 100% Alignment Verification', () {
    late Directory tempDir;
    late OrbitClient client;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('blueprint_test_');
      client = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/blueprint_test.db',
        baseUrl: 'https://api.example.com',
      );
    });

    tearDown(() async {
      await client.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('Gap 1 & 2: Collection-level default Priority, SLA, and CoolingTime', () async {
      final orders = client.collection<Order>(
        name: 'orders',
        priority: Priority.high,
        sla: const Duration(hours: 2),
        coolingTime: const Duration(minutes: 5),
        fromJson: Order.fromJson,
        toJson: (o) => o.toJson(),
      );

      final orderId = await orders.save(Order(title: 'Laptop Order', amount: 1200.0));

      final outbox = await client.query(
        'SELECT priority, sla_seconds, dispatch_after, created_at FROM _sync_outbox WHERE entity_id = ?',
        [orderId],
      );

      expect(outbox, isNotEmpty);
      expect(outbox.first['priority'], equals(Priority.high.value));
      expect(outbox.first['sla_seconds'], equals(7200)); // 2 hours

      final createdAt = outbox.first['created_at'] as int;
      final dispatchAfter = outbox.first['dispatch_after'] as int;
      expect(dispatchAfter - createdAt, greaterThanOrEqualTo(299000)); // ~5 minutes
    });

    test('Gap 3: Explicit authorId and userId on save() and delete()', () async {
      final orders = client.collection<Order>(
        name: 'orders',
        fromJson: Order.fromJson,
        toJson: (o) => o.toJson(),
      );

      final orderId = await orders.save(
        Order(title: 'Audited Order', amount: 450.0),
        authorId: 'emp_9821',
        userId: 'usr_auth_11',
      );

      var outbox = await client.query(
        'SELECT author_id, user_id, op FROM _sync_outbox WHERE entity_id = ?',
        [orderId],
      );
      expect(outbox.first['author_id'], equals('emp_9821'));
      expect(outbox.first['user_id'], equals('usr_auth_11'));
      expect(outbox.first['op'], equals('create'));

      // Delete with author attribution
      await orders.delete(orderId, authorId: 'supervisor_44', userId: 'usr_auth_11');

      outbox = await client.query(
        "SELECT author_id, user_id FROM _sync_outbox WHERE entity_id = ? AND op = 'delete'",
        [orderId],
      );
      expect(outbox.first['author_id'], equals('supervisor_44'));
      expect(outbox.first['user_id'], equals('usr_auth_11'));
    });

    test('Gap 4: OrbitRecord.isPending and OrbitRecord.isFailed getters', () async {
      const pendingRecord = OrbitRecord<String>(data: 'test', status: OrbitSyncStatus.pending);
      const inFlightRecord = OrbitRecord<String>(data: 'test', status: OrbitSyncStatus.inFlight);
      const syncedRecord = OrbitRecord<String>(data: 'test', status: OrbitSyncStatus.synced);
      const failedRecord = OrbitRecord<String>(data: 'test', status: OrbitSyncStatus.failed);
      const rejectedRecord = OrbitRecord<String>(data: 'test', status: OrbitSyncStatus.rejected);

      expect(pendingRecord.isPending, isTrue);
      expect(inFlightRecord.isPending, isTrue);
      expect(syncedRecord.isPending, isFalse);

      expect(failedRecord.isFailed, isTrue);
      expect(rejectedRecord.isFailed, isFalse);
      expect(rejectedRecord.isRejected, isTrue);
    });

    test('Gap 5: Offline Pinning API (orders.pin and orders.unpin)', () async {
      final orders = client.collection<Order>(
        name: 'orders',
        cacheTtl: const Duration(hours: 1),
        fromJson: Order.fromJson,
        toJson: (o) => o.toJson(),
      );

      final orderId = await orders.save(Order(title: 'Mission Critical Task', amount: 99.0));

      // Pin record: expires_at becomes NULL
      await orders.pin(orderId);
      var rows = await client.query('SELECT expires_at FROM orders WHERE id = ?', [orderId]);
      expect(rows.first['expires_at'], isNull);

      // Unpin record: sets fresh TTL
      await orders.unpin(orderId, ttl: const Duration(minutes: 30));
      rows = await client.query('SELECT expires_at FROM orders WHERE id = ?', [orderId]);
      expect(rows.first['expires_at'], isNotNull);
      expect(rows.first['expires_at'] as int, greaterThan(DateTime.now().millisecondsSinceEpoch));
    });

    test('Gap 6: OrbitAttachment and MediaConfig metadata extraction', () async {
      final orders = client.collection<Order>(
        name: 'orders',
        media: const MediaConfig(mode: MediaMode.twoStep, uploadEndpoint: '/orders/{id}/receipt'),
        fromJson: Order.fromJson,
        toJson: (o) => o.toJson(),
      );

      final attachment = const OrbitAttachment(
        localPath: '/tmp/receipt_scan.pdf',
        fileName: 'receipt_scan.pdf',
        mimeType: 'application/pdf',
        fieldName: 'receipt',
      );

      final orderId = await orders.save(
        Order(title: 'Expense Claim', amount: 85.0, attachment: attachment),
      );

      final outbox = await client.query(
        'SELECT media_path, payload_json FROM _sync_outbox WHERE entity_id = ?',
        [orderId],
      );
      expect(outbox.first['media_path'], equals('/tmp/receipt_scan.pdf'));
      expect(outbox.first['payload_json'], contains('orbit_attachment'));
    });

    test('Gap 7: Storage Quota & LRU Eviction (maxCacheRecords)', () async {
      client.collection<Order>(
        name: 'orders',
        maxCacheRecords: 3,
        fromJson: Order.fromJson,
        toJson: (o) => o.toJson(),
      );

      // Store 5 records with expires_at set (ephemeral cache)
      for (int i = 1; i <= 5; i++) {
        await client.storage.save(
          entity: 'orders',
          id: 'ord_$i',
          data: {'title': 'Order #$i', 'amount': i * 10.0},
          ttl: const Duration(hours: 1),
        );
      }

      var countRows = await client.query('SELECT COUNT(*) as cnt FROM orders');
      expect(countRows.first['cnt'], equals(5));

      // Mark outbox mutations as synced to simulate confirmed server mirror cache
      await client.storage.db.execute("UPDATE _sync_outbox SET status = 'synced'");

      // Trigger pruneToQuota directly and via table save
      final pruned = await client.storage.pruneToQuota('orders', maxCacheRecords: 3);
      expect(pruned, equals(2));

      countRows = await client.query('SELECT COUNT(*) as cnt FROM orders');
      expect(countRows.first['cnt'], equals(3));

      // Verify that the oldest orders (ord_1, ord_2) were evicted
      final remaining = await client.query('SELECT id FROM orders ORDER BY id ASC');
      final ids = remaining.map((r) => r['id'] as String).toList();
      expect(ids, equals(['ord_3', 'ord_4', 'ord_5']));
    });
  });
}
