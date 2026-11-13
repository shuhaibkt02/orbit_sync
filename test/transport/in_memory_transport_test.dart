import 'dart:convert';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

void main() {
  group('Layer 4 Transport: InMemorySyncTransport', () {
    test('Zero-socket in-memory operations record batches and custom pushes',
        () async {
      final mock = SyncTransport.inMemory() as InMemorySyncTransport;

      expect(mock.pushedBatches, isEmpty);
      expect(mock.customPushes, isEmpty);

      final batchResp = await mock.pushBatch(
        mutations: [
          {'id': '101', 'action': 'create'}
        ],
        idempotencyKey: 'idemp-1',
      );
      expect(batchResp.isSuccess, isTrue);
      expect(mock.pushedBatches.length, equals(1));

      final customResp = await mock.pushCustom(
        url: 'https://example.com/orders',
        method: 'PUT',
        mutationId: 'mut-2',
        createdAtMs: 5000,
        payload: {'qty': 5},
        entityId: 'ord-1',
      );
      expect(customResp.isSuccess, isTrue);
      expect(mock.customPushes.length, equals(1));
      expect(mock.customPushes.first['entityId'], equals('ord-1'));
    });

    test('Simulated error and canned pull changes', () async {
      final mock = SyncTransport.inMemory(
        cannedPullChanges: [
          {'id': 'remote-1', 'title': 'Remote Book'}
        ],
        pullNextCursor: 42,
      ) as InMemorySyncTransport;

      final pullResp = await mock.pull(sinceCursor: 0, limit: 10);
      expect(pullResp.isSuccess, isTrue);

      final decoded = jsonDecode(pullResp.body) as Map<String, dynamic>;
      expect(decoded['next_cursor'], equals(42));
      expect(decoded['changes'].length, equals(1));

      // Simulate network drop
      mock.pushError = 'Simulated TCP Drop';
      final failedPush =
          await mock.pushBatch(mutations: [], idempotencyKey: 'fail-1');
      expect(failedPush.isSuccess, isFalse);
      expect(failedPush.isNetworkError, isTrue);
      expect(failedPush.error, equals('Simulated TCP Drop'));
    });

    test('Remote change notification stream emits event', () async {
      final mock = SyncTransport.inMemory() as InMemorySyncTransport;
      var notified = false;
      final sub = mock.onRemoteChange.listen((_) => notified = true);

      mock.notifyRemoteChange();
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(notified, isTrue);
      await sub.cancel();
      mock.dispose();
    });
  });
}
