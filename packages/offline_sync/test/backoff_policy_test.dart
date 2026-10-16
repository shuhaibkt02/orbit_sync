import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:test/test.dart';
import 'package:offline_sync/offline_sync.dart';
import 'harness/clock/controllable_clock.dart';
import 'harness/transport/fault.dart';
import 'harness/transport/fault_injection_http_client.dart';

void main() {
  group('BackoffPolicy & next_retry_at Engine', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('backoff_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('Test 1: Monotonic capped backoff schedule', () {
      final policy = BackoffPolicy(
        base: const Duration(seconds: 1),
        max: const Duration(seconds: 30),
        jitterFraction: 0,
      );

      expect(policy.delayFor(0), equals(Duration.zero));
      expect(policy.delayFor(1), equals(const Duration(seconds: 1)));
      expect(policy.delayFor(2), equals(const Duration(seconds: 2)));
      expect(policy.delayFor(3), equals(const Duration(seconds: 4)));
      expect(policy.delayFor(4), equals(const Duration(seconds: 8)));
      expect(policy.delayFor(5), equals(const Duration(seconds: 16)));
      // Capped at 30 seconds
      expect(policy.delayFor(6), equals(const Duration(seconds: 30)));
      expect(policy.delayFor(10), equals(const Duration(seconds: 30)));
      expect(policy.delayFor(25), equals(const Duration(seconds: 30)));

      // Strictly monotonic before cap
      expect(policy.delayFor(0) < policy.delayFor(1), isTrue);
      expect(policy.delayFor(1) < policy.delayFor(2), isTrue);
      expect(policy.delayFor(2) < policy.delayFor(5), isTrue);
      expect(policy.delayFor(5) <= const Duration(seconds: 30), isTrue);
    });

    test('Test 2: Bounded jitter calculation', () {
      final policy = BackoffPolicy(
        base: const Duration(milliseconds: 1000),
        max: const Duration(seconds: 60),
        jitterFraction: 0.25,
        rng: Random(42),
      );

      // retry 1 -> capped base = 1000ms. Jitter ±25% -> [750ms, 1250ms]
      for (var i = 0; i < 50; i++) {
        final delay = policy.delayFor(1).inMilliseconds;
        expect(delay, greaterThanOrEqualTo(750));
        expect(delay, lessThanOrEqualTo(1250));
      }

      // retry 3 -> capped base = 4000ms. Jitter ±25% -> [3000ms, 5000ms]
      for (var i = 0; i < 50; i++) {
        final delay = policy.delayFor(3).inMilliseconds;
        expect(delay, greaterThanOrEqualTo(3000));
        expect(delay, lessThanOrEqualTo(5000));
      }
    });

    test('Test 3 & 4: Failed mutation suppressed within window; retried after window', () async {
      final clock = ControllableClock(DateTime.utc(2026, 10, 17, 12, 0, 0));
      final policy = BackoffPolicy(
        base: const Duration(seconds: 10),
        max: const Duration(minutes: 5),
        jitterFraction: 0, // Deterministic exact 10s delay
      );

      final faultClient = FaultInjectionHttpClient(
        script: [
          const ReturnStatus(500, body: 'Server Error'),
          const ReturnStatus(200, body: '{"status":"ok"}'),
        ],
      );

      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/suppress_retry.db',
        httpClient: faultClient,
        backoffPolicy: policy,
        nowMsProvider: () => clock.millisecondsSinceEpoch,
      );
      await client.registerEntity('items', url: 'https://example.com/api/items');

      final itemId = await client.store('items', {'name': 'Widget A'});

      // Attempt 1: Fails with 500
      await client.sync();

      var rows = await client.query('SELECT status, retry_count, next_retry_at FROM _sync_outbox WHERE entity_id = ?', [itemId]);
      expect(rows.first['status'], equals('pending'));
      expect(rows.first['retry_count'], equals(1));
      final nextRetryAt = rows.first['next_retry_at'] as int;
      expect(nextRetryAt, equals(clock.millisecondsSinceEpoch + 10000));
      expect(faultClient.captured.length, equals(1));

      // Advance clock by 9999ms (10s - 1ms) -> WITHIN WINDOW
      clock.advance(const Duration(milliseconds: 9999));
      faultClient.captured.clear();

      // Trigger automatic sync -> MUST BE SUPPRESSED (zero HTTP requests)
      await client.sync();
      expect(faultClient.captured.length, equals(0), reason: 'Sync must be suppressed within backoff window');

      rows = await client.query('SELECT status, retry_count FROM _sync_outbox WHERE entity_id = ?', [itemId]);
      expect(rows.first['status'], equals('pending'));
      expect(rows.first['retry_count'], equals(1));

      // Test 4: Advance clock by 2ms (total 10,001ms, 1ms after window) -> WINDOW EXPIRED
      clock.advance(const Duration(milliseconds: 2));

      // Trigger sync -> MUST RETRY (1 HTTP request, succeeds)
      await client.sync();
      expect(faultClient.captured.length, equals(1), reason: 'Sync must retry once backoff window expires');

      rows = await client.query('SELECT status, next_retry_at FROM _sync_outbox WHERE entity_id = ?', [itemId]);
      expect(rows.first['status'], equals('synced'));
      expect(rows.first['next_retry_at'], isNull);

      await client.close();
      faultClient.close();
    });

    test('Test 5: HTTP 429 Retry-After header overrides computed backoff', () async {
      final clock = ControllableClock(DateTime.utc(2026, 10, 17, 12, 0, 0));
      final policy = BackoffPolicy(
        base: const Duration(seconds: 1), // Standard backoff would only be 1 second
        jitterFraction: 0,
      );

      final faultClient = FaultInjectionHttpClient(
        script: [
          const ReturnStatus(429, headers: {'retry-after': '60'}, body: 'Rate limited'),
          const ReturnStatus(200, body: '{"status":"ok"}'),
        ],
      );

      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/rate_limit.db',
        httpClient: faultClient,
        backoffPolicy: policy,
        nowMsProvider: () => clock.millisecondsSinceEpoch,
      );
      await client.registerEntity('items', url: 'https://example.com/api/items');

      final itemId = await client.store('items', {'name': 'Rate Limited Item'});

      // 1. Sync encounters 429 Retry-After: 60
      await client.sync();

      var rows = await client.query('SELECT status, next_retry_at FROM _sync_outbox WHERE entity_id = ?', [itemId]);
      expect(rows.first['status'], equals('pending'));
      final expectedRetry = clock.millisecondsSinceEpoch + 60000;
      expect(rows.first['next_retry_at'], equals(expectedRetry));
      expect(faultClient.captured.length, equals(1));

      // Advance clock by 59s -> Still suppressed
      clock.advance(const Duration(seconds: 59));
      faultClient.captured.clear();
      await client.sync();
      expect(faultClient.captured.length, equals(0), reason: 'Suppressed by 60s Retry-After window');

      // Advance clock by 2s (total 61s) -> Window expired, retries and succeeds
      clock.advance(const Duration(seconds: 2));
      await client.sync();
      expect(faultClient.captured.length, equals(1));

      rows = await client.query('SELECT status, next_retry_at FROM _sync_outbox WHERE entity_id = ?', [itemId]);
      expect(rows.first['status'], equals('synced'));
      expect(rows.first['next_retry_at'], isNull);

      await client.close();
      faultClient.close();
    });

    test('Test 6: Successful sync clears next_retry_at to NULL', () async {
      final clock = ControllableClock(DateTime.utc(2026, 10, 17, 12, 0, 0));
      final faultClient = FaultInjectionHttpClient(
        script: [
          const ReturnStatus(503, body: 'Unavailable'),
          const ReturnStatus(200, body: '{"status":"ok"}'),
        ],
      );

      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/clear_next_retry.db',
        httpClient: faultClient,
        backoffPolicy: BackoffPolicy(base: const Duration(seconds: 2), jitterFraction: 0),
        nowMsProvider: () => clock.millisecondsSinceEpoch,
      );
      await client.registerEntity('items', url: 'https://example.com/api/items');

      final itemId = await client.store('items', {'name': 'Clear Test'});

      // Attempt 1 fails
      await client.sync();
      var rows = await client.query('SELECT next_retry_at FROM _sync_outbox WHERE entity_id = ?', [itemId]);
      expect(rows.first['next_retry_at'], isNotNull);

      // Advance clock and retry
      clock.advance(const Duration(seconds: 3));
      await client.sync();

      rows = await client.query('SELECT status, next_retry_at FROM _sync_outbox WHERE entity_id = ?', [itemId]);
      expect(rows.first['status'], equals('synced'));
      expect(rows.first['next_retry_at'], isNull);

      await client.close();
      faultClient.close();
    });

    test('Test 7: Exceeding maxRetries transitions status to dlq with zero further retries', () async {
      final clock = ControllableClock(DateTime.utc(2026, 10, 17, 12, 0, 0));
      final policy = BackoffPolicy(
        base: const Duration(seconds: 1),
        maxRetries: 3,
        jitterFraction: 0,
      );

      final faultClient = FaultInjectionHttpClient(
        script: [
          const ReturnStatus(500, body: 'Err 1'),
          const ReturnStatus(500, body: 'Err 2'),
          const ReturnStatus(500, body: 'Err 3'),
          const ReturnStatus(200, body: '{"status":"should never reach"}'),
        ],
      );

      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/dlq_max_retries.db',
        httpClient: faultClient,
        backoffPolicy: policy,
        nowMsProvider: () => clock.millisecondsSinceEpoch,
      );
      await client.registerEntity('items', url: 'https://example.com/api/items');

      final itemId = await client.store('items', {'name': 'Poison'});

      // Retry 1 (fails -> pending, retry=1)
      await client.sync();
      clock.advance(const Duration(seconds: 2));

      // Retry 2 (fails -> pending, retry=2)
      await client.sync();
      clock.advance(const Duration(seconds: 4));

      // Retry 3 (fails -> retry=3 >= maxRetries 3 -> transitions to DLQ)
      await client.sync();

      var rows = await client.query('SELECT status, retry_count, next_retry_at FROM _sync_outbox WHERE entity_id = ?', [itemId]);
      expect(rows.first['status'], equals('dlq'));
      expect(rows.first['retry_count'], equals(3));
      expect(rows.first['next_retry_at'], isNull);

      // Further sync attempts MUST NOT send HTTP requests for DLQ records
      faultClient.captured.clear();
      clock.advance(const Duration(days: 10));
      await client.sync();
      expect(faultClient.captured.length, equals(0), reason: 'DLQ records are quarantined from normal sync');

      await client.close();
      faultClient.close();
    });

    test('Test 8: Non-transient 4xx (422) is not backed off (marked validation_error, next_retry_at = NULL)', () async {
      final faultClient = FaultInjectionHttpClient(
        script: [
          ReturnStatus(422, body: jsonEncode({'error': 'name violates minLength constraint'})),
        ],
      );

      final client = await OfflineSyncClient.initialize(
        databasePath: '${tempDir.path}/validation_error.db',
        httpClient: faultClient,
      );
      await client.registerEntity('items', url: 'https://example.com/api/items');

      final itemId = await client.store('items', {'name': 'X'});

      await client.sync();

      final rows = await client.query('SELECT status, next_retry_at, error_details_json FROM _sync_outbox WHERE entity_id = ?', [itemId]);
      expect(rows.first['status'], equals('validation_error'));
      expect(rows.first['next_retry_at'], isNull);
      expect(rows.first['error_details_json'], contains('minLength constraint'));

      // Optimistic record rolled back
      final active = await client.restoreById('items', itemId);
      expect(active, isNull);

      await client.close();
      faultClient.close();
    });
  });
}
