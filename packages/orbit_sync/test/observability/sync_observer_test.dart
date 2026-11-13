import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

void main() {
  group('Layer 6 Observability: SyncObserver Unified & Typed Streams', () {
    test('broadcasts unified stream and filters typed getters seamlessly', () async {
      final observer = SyncObserver();
      final allEvents = <SyncEvent>[];
      final onlineEvents = <OnlineEvent>[];
      final breachedEvents = <SlaBreachedEvent>[];
      final rejectedEvents = <SyncRejectedEvent>[];

      final sub1 = observer.events.listen(allEvents.add);
      final sub2 = observer.onOnline.listen(onlineEvents.add);
      final sub3 = observer.onSlaBreached.listen(breachedEvents.add);
      final sub4 = observer.onSyncRejected.listen(rejectedEvents.add);

      final now = DateTime.now().toUtc();
      observer.publish(OnlineEvent(timestamp: now));
      observer.publish(SlaBreachedEvent(
        timestamp: now,
        mutationId: 'mut-1',
        entity: 'orders',
        entityId: 'ord-1',
        age: const Duration(hours: 2),
        sla: const Duration(hours: 1),
      ));
      observer.publish(SyncRejectedEvent(
        timestamp: now,
        entity: 'orders',
        entityId: 'ord-1',
        errorMessage: 'Inventory exhausted',
        statusCode: 422,
      ));

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(allEvents.length, equals(3));
      expect(onlineEvents.length, equals(1));
      expect(breachedEvents.length, equals(1));
      expect(rejectedEvents.length, equals(1));
      expect(rejectedEvents.first.errorMessage, equals('Inventory exhausted'));

      await sub1.cancel();
      await sub2.cancel();
      await sub3.cancel();
      await sub4.cancel();
      await observer.dispose();
    });

    test('delegates manual retry operations cleanly', () async {
      String? retriedId;
      bool? retriedSyncNow;
      bool? allRetried;

      final observer = SyncObserver(
        onRetryMutation: (id, {syncNow = false}) async {
          retriedId = id;
          retriedSyncNow = syncNow;
        },
        onRetryAllFailed: ({syncNow = false}) async {
          allRetried = true;
        },
      );

      await observer.retryMutation('mut-99', syncNow: true);
      expect(retriedId, equals('mut-99'));
      expect(retriedSyncNow, isTrue);

      await observer.retryAllFailed();
      expect(allRetried, isTrue);

      await observer.dispose();
    });

    test('integrates with OrbitClient facade emitting live events', () async {
      final tempDir = Directory.systemTemp.createTempSync('observer_facade_test_');
      final client = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/app.db',
        transport: SyncTransport.inMemory(),
      );
      await client.registerTable('tasks', {'title': 'TEXT'});

      final queued = <MutationQueuedEvent>[];
      final rejections = <SyncRejectedEvent>[];
      final sub1 = client.onMutationQueued.listen(queued.add);
      final sub2 = client.onSyncRejected.listen(rejections.add);

      // Save triggers onMutationQueued
      await client.save(
        entity: 'tasks',
        id: 't-1',
        data: {'title': 'Test Task'},
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(queued.length, equals(1));
      expect(queued.first.entityId, equals('t-1'));
      expect(queued.first.entity, equals('tasks'));

      // Soft reject triggers onSyncRejected
      await client.softRejectRecord('tasks', 't-1', reason: 'Invalid title');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(rejections.length, equals(1));
      expect(rejections.first.errorMessage, equals('Invalid title'));

      await sub1.cancel();
      await sub2.cancel();
      await client.close();
      tempDir.deleteSync(recursive: true);
    });
  });
}
