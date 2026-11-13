import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import '../shared/harness/transport/fault.dart';
import '../shared/harness/transport/fault_injection_http_client.dart';

class OrderItem {
  final String id;
  final String title;
  final double amount;

  OrderItem({required this.id, required this.title, required this.amount});

  factory OrderItem.fromJson(Map<String, dynamic> json) => OrderItem(
        id: json['id'] as String,
        title: json['title'] as String,
        amount: (json['amount'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'amount': amount};
}

void main() {
  group('Ticket 16: Unified Sync Center Diagnostic API & Memory-Safe Streams', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('sync_center_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('1. watchItems() streams processed SyncItemInfo with parsed fields and status', () async {
      final client = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/sync_items.db',
        profile: SyncProfile.standard,
      );

      final table = client.collection<OrderItem>(
        name: 'orders',
        endpoint: '/orders',
        fromJson: OrderItem.fromJson,
        toJson: (o) => o.toJson(),
      );

      // Save an item with SLA
      await table.save(
        OrderItem(id: 'ord-1', title: 'Coffee', amount: 4.5),
        sla: const Duration(minutes: 30),
      );

      final items = await client.syncCenter.watchItems().first;
      expect(items.length, equals(1));
      final item = items.first;
      expect(item.entityName, equals('orders'));
      expect(item.entityId, equals('ord-1'));
      expect(item.status, equals(SyncItemStatus.pending));
      expect(item.data['title'], equals('Coffee'));
      expect(item.data['amount'], equals(4.5));
      expect(item.remainingSla, isNotNull);
      expect(item.remainingSla!.inMinutes, greaterThanOrEqualTo(29));
      expect(item.canRetry, isFalse);

      await client.close();
    });

    test('2. watchItems(filterStatus) filters outbox records by status', () async {
      final client = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/filter_status.db',
      );

      final table = client.collection<OrderItem>(
        name: 'orders',
        endpoint: '/orders',
        fromJson: OrderItem.fromJson,
        toJson: (o) => o.toJson(),
      );

      await table.save(OrderItem(id: 'ord-pending', title: 'Pending Order', amount: 10));
      await table.save(OrderItem(id: 'ord-rejected', title: 'Rejected Order', amount: 20));

      // Simulate one item entering validation_error
      await client.storage.db.execute(
        "UPDATE _sync_outbox SET status = 'validation_error', error_details_json = '{\"error\":\"Limit reached\"}' WHERE entity_id = 'ord-rejected'",
      );

      // Filter by rejected
      final rejectedItems = await client.syncCenter.watchItems(filterStatus: SyncItemStatus.rejected).first;
      expect(rejectedItems.length, equals(1));
      expect(rejectedItems.first.entityId, equals('ord-rejected'));
      expect(rejectedItems.first.status, equals(SyncItemStatus.rejected));
      expect(rejectedItems.first.failureReason, contains('Limit reached'));
      expect(rejectedItems.first.canRetry, isTrue);

      // Filter by pending
      final pendingItems = await client.syncCenter.watchItems(filterStatus: SyncItemStatus.pending).first;
      expect(pendingItems.length, equals(1));
      expect(pendingItems.first.entityId, equals('ord-pending'));

      await client.close();
    });

    test('3. Auto-pausing stream lifecycle: onCancel immediately detaches watcher', () async {
      final client = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/auto_pause.db',
      );

      final table = client.collection<OrderItem>(
        name: 'orders',
        endpoint: '/orders',
        fromJson: OrderItem.fromJson,
        toJson: (o) => o.toJson(),
      );

      await table.save(OrderItem(id: 'ord-initial', title: 'Initial', amount: 1));

      final stream = client.syncCenter.watchItems();
      var eventCount = 0;
      final sub = stream.listen((_) => eventCount++);

      // Wait for initial emission
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final countAtListen = eventCount;
      expect(countAtListen, greaterThanOrEqualTo(1));

      // Cancel subscription (simulating widget unmounting)
      await sub.cancel();

      // Subsequent database writes must not emit to canceled subscription
      await table.save(OrderItem(id: 'ord-unmounted', title: 'No Leak', amount: 5));
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(eventCount, equals(countAtListen));

      await client.close();
    });

    test('4. Microtask 100ms emission throttling during high-frequency mutation bursts', () async {
      final client = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/throttle.db',
      );

      final table = client.collection<OrderItem>(
        name: 'orders',
        endpoint: '/orders',
        fromJson: OrderItem.fromJson,
        toJson: (o) => o.toJson(),
      );

      var emissionCount = 0;
      final sub = client.syncCenter.watchItems().listen((_) => emissionCount++);

      // Rapidly write 15 mutations within 50ms (burst)
      for (var i = 0; i < 15; i++) {
        await table.save(OrderItem(id: 'ord-burst-$i', title: 'Burst Item $i', amount: i.toDouble()));
      }

      // At 50ms, because of the 100ms throttle, emission count must be small (<= 2)
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(emissionCount, lessThanOrEqualTo(2));

      // After 150ms (throttle period expires), coalesced update arrives
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(emissionCount, greaterThanOrEqualTo(2));

      await sub.cancel();
      await client.close();
    });

    test('5. ValueListenable<OrbitSummary> reflects outbox counts and health states', () async {
      final client = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/summary_test.db',
      );

      final summary = client.syncCenter.summary;
      expect(summary.value.isClean, isTrue);
      expect(summary.value.pending, equals(0));
      expect(summary.value.hasErrors, isFalse);

      var notifyCount = 0;
      void listener() => notifyCount++;
      summary.addListener(listener);

      final table = client.collection<OrderItem>(
        name: 'orders',
        endpoint: '/orders',
        fromJson: OrderItem.fromJson,
        toJson: (o) => o.toJson(),
      );

      // Save an item -> summary updates
      await table.save(OrderItem(id: 'ord-sum-1', title: 'Summary Order', amount: 12));
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(summary.value.pending, equals(1));
      expect(summary.value.isClean, isFalse);
      expect(notifyCount, greaterThanOrEqualTo(1));

      // Put item in validation_error
      await client.storage.db.execute(
        "UPDATE _sync_outbox SET status = 'validation_error' WHERE entity_id = 'ord-sum-1'",
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(summary.value.rejected, equals(1));
      expect(summary.value.hasErrors, isTrue);

      summary.removeListener(listener);
      await client.close();
    });

    test('6. Action controls: syncNow(), retryItem(), retryAllFailed()', () async {
      final faultClient = FaultInjectionHttpClient(
        script: [
          const ReturnStatus(500, body: 'Server Error'),
          const ReturnStatus(200, body: '{"id": "ord-retry-1"}'),
          const ReturnStatus(422, body: '{"error": "Invalid discount"}'),
          const ReturnStatus(200, body: '{"id": "ord-retry-2"}'),
        ],
      );

      final client = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/actions_test.db',
        httpClient: faultClient,
      );

      final table = client.collection<OrderItem>(
        name: 'orders',
        endpoint: '/orders',
        fromJson: OrderItem.fromJson,
        toJson: (o) => o.toJson(),
      );

      await table.save(OrderItem(id: 'ord-retry-1', title: 'Item 1', amount: 50));
      await table.save(OrderItem(id: 'ord-retry-2', title: 'Item 2', amount: 75));

      // 1st Push -> mut1 fails with 500, lane pauses
      await client.syncNow();

      final outbox1 = await client.query("SELECT mutation_id, status FROM _sync_outbox WHERE entity_id = 'ord-retry-1'");
      final outbox2 = await client.query("SELECT mutation_id, status FROM _sync_outbox WHERE entity_id = 'ord-retry-2'");
      final mut1 = outbox1.first['mutation_id'] as String;
      final mut2 = outbox2.first['mutation_id'] as String;
      expect(outbox1.first['status'], equals('pending')); // in pending with retry_count = 1

      // 1-Tap Retry single item -> mut1 succeeds (200), mut2 encounters 422
      await client.retryItem(mut1);
      final afterRetry1 = await client.query("SELECT status FROM _sync_outbox WHERE mutation_id = ?", [mut1]);
      final afterRetry2 = await client.query("SELECT status FROM _sync_outbox WHERE mutation_id = ?", [mut2]);
      expect(afterRetry1.first['status'], equals('synced'));
      expect(afterRetry2.first['status'], equals('validation_error'));

      // 1-Tap Retry all failed -> mut2 is recovered and succeeds (200)
      await client.retryAllFailed();
      final afterRetryAll = await client.query("SELECT status FROM _sync_outbox WHERE mutation_id = ?", [mut2]);
      expect(afterRetryAll.first['status'], equals('synced'));

      await client.close();
      faultClient.close();
    });

    test('7. Early-Warning SLA alerts trigger onSlaWarning and onSlaBreached callbacks', () async {
      int simulatedNow = 1000000;
      SlaWarningEvent? warningReceived;
      SlaBreachedEvent? breachReceived;

      final client = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/sla_alerts.db',
        nowMsProvider: () => simulatedNow,
        onSlaWarning: (event) => warningReceived = event,
        onSlaBreached: (event) => breachReceived = event,
      );

      final table = client.collection<OrderItem>(
        name: 'orders',
        endpoint: '/orders',
        fromJson: OrderItem.fromJson,
        toJson: (o) => o.toJson(),
      );

      // Save order with 100-second (100,000ms) SLA
      await table.save(
        OrderItem(id: 'ord-sla-1', title: 'SLA Watch', amount: 99),
        sla: const Duration(seconds: 100),
      );

      // Backdate created_at to simulatedNow (t=0)
      await client.storage.db.execute(
        "UPDATE _sync_outbox SET created_at = ? WHERE entity_id = 'ord-sla-1'",
        [simulatedNow],
      );

      // Advance clock to 70 seconds (70% - should NOT warn yet)
      simulatedNow += 70000;
      await client.observer.slaMonitor?.evaluate();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(warningReceived, isNull);
      expect(breachReceived, isNull);

      // Advance clock to 85 seconds (85% - triggers onSlaWarning)
      simulatedNow += 15000;
      await client.observer.slaMonitor?.evaluate();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(warningReceived, isNotNull);
      expect(warningReceived!.entityId, equals('ord-sla-1'));
      expect(breachReceived, isNull);

      // Advance clock to 105 seconds (105% - triggers onSlaBreached)
      simulatedNow += 20000;
      await client.observer.slaMonitor?.evaluate();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(breachReceived, isNotNull);
      expect(breachReceived!.entityId, equals('ord-sla-1'));

      await client.close();
    });
  });
}
