import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';
import '../shared/harness/clock/controllable_clock.dart';
import '../shared/harness/transport/fault.dart';
import '../shared/harness/transport/fault_injection_http_client.dart';

void main() {
  group('Layer 2 Consensus: Backoff Retry Engine Integration', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('backoff_engine_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('Test 1: Failed mutation suppressed within window; retried after window', () async {
      final clock = ControllableClock(DateTime.utc(2026, 10, 17, 12, 0, 0));
      final policy = BackoffPolicy(
        base: const Duration(seconds: 10),
        max: const Duration(minutes: 5),
        jitterFraction: 0,
      );

      final faultClient = FaultInjectionHttpClient(
        script: [
          const ReturnStatus(500, body: 'Server Error'),
          const ReturnStatus(200, body: '{"status":"ok"}'),
        ],
      );

      final client = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/suppress_retry.db',
        httpClient: faultClient,
        backoffPolicy: policy,
        nowMsProvider: () => clock.millisecondsSinceEpoch,
      );
      await client.registerEntity('items', url: 'https://example.com/api/items');

      final itemId = await client.store('items', {'name': 'Widget A'});
      await client.sync();

      var rows = await client.query('SELECT status, retry_count, next_retry_at FROM _sync_outbox WHERE entity_id = ?', [itemId]);
      expect(rows.first['status'], equals('pending'));
      expect(rows.first['retry_count'], equals(1));
      expect(rows.first['next_retry_at'], equals(clock.millisecondsSinceEpoch + 10000));

      clock.advance(const Duration(seconds: 5));
      await client.sync();
      expect(faultClient.captured.length, equals(1));

      clock.advance(const Duration(seconds: 6));
      await client.sync();
      expect(faultClient.captured.length, equals(2));

      rows = await client.query('SELECT status, next_retry_at FROM _sync_outbox WHERE entity_id = ?', [itemId]);
      expect(rows.first['status'], equals('synced'));
      expect(rows.first['next_retry_at'], isNull);

      await client.close();
      faultClient.close();
    });

    test('Test 2: Exceeding maxRetries transitions status to dlq with zero further retries', () async {
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

      final client = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/dlq_max_retries.db',
        httpClient: faultClient,
        backoffPolicy: policy,
        nowMsProvider: () => clock.millisecondsSinceEpoch,
      );
      await client.registerEntity('items', url: 'https://example.com/api/items');

      final itemId = await client.store('items', {'name': 'Poison'});

      await client.sync();
      clock.advance(const Duration(seconds: 2));

      await client.sync();
      clock.advance(const Duration(seconds: 4));

      await client.sync();

      var rows = await client.query('SELECT status, retry_count, next_retry_at FROM _sync_outbox WHERE entity_id = ?', [itemId]);
      expect(rows.first['status'], equals('dlq'));
      expect(rows.first['retry_count'], equals(3));
      expect(rows.first['next_retry_at'], isNull);

      faultClient.captured.clear();
      clock.advance(const Duration(days: 10));
      await client.sync();
      expect(faultClient.captured.length, equals(0));

      await client.close();
      faultClient.close();
    });

    test('Test 3: Non-transient 4xx (422) is not backed off', () async {
      final faultClient = FaultInjectionHttpClient(
        script: [
          ReturnStatus(422, body: jsonEncode({'error': 'name violates minLength constraint'})),
        ],
      );

      final client = await OrbitClient.initialize(
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

      final active = await client.restoreById('items', itemId);
      expect(active, isNull);

      await client.close();
      faultClient.close();
    });

    test('Test 4: HTTP 429 Retry-After in RFC 7231 HTTP-date format correctly parses and sets next_retry_at', () async {
      final clock = ControllableClock(DateTime.utc(2026, 10, 17, 12, 0, 0));
      final httpDateHeader = HttpDate.format(DateTime.utc(2026, 10, 17, 12, 1, 0));

      final faultClient = FaultInjectionHttpClient(
        script: [
          ReturnStatus(429, headers: {'retry-after': httpDateHeader}, body: 'Rate limited'),
          const ReturnStatus(200, body: '{"status":"ok"}'),
        ],
      );

      final client = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/http_date_backoff.db',
        httpClient: faultClient,
        nowMsProvider: () => clock.millisecondsSinceEpoch,
      );
      await client.registerEntity('items', url: 'https://example.com/api/items');

      final itemId = await client.store('items', {'name': 'Date Test'});
      await client.sync();

      final rows = await client.query('SELECT status, next_retry_at FROM _sync_outbox WHERE entity_id = ?', [itemId]);
      expect(rows.first['status'], equals('pending'));
      final baseTargetMs = clock.millisecondsSinceEpoch;
      final retryAt = rows.first['next_retry_at'] as int;
      // Validates RFC 7231 parsing + full randomized jitter (±20% of 60s)
      expect(retryAt, greaterThanOrEqualTo(baseTargetMs + 48000));
      expect(retryAt, lessThanOrEqualTo(baseTargetMs + 72000));

      await client.close();
      faultClient.close();
    });

    test('Test 5: HTTP 429 Retry-After with integer seconds parses and sets next_retry_at', () async {
      final clock = ControllableClock(DateTime.utc(2026, 10, 17, 12, 0, 0));

      final faultClient = FaultInjectionHttpClient(
        script: [
          const ReturnStatus(429, headers: {'retry-after': '30'}, body: 'Too Many Requests'),
          const ReturnStatus(200, body: '{"status":"ok"}'),
        ],
      );

      final client = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/seconds_backoff.db',
        httpClient: faultClient,
        nowMsProvider: () => clock.millisecondsSinceEpoch,
      );
      await client.registerEntity('items', url: 'https://example.com/api/items');

      final itemId = await client.store('items', {'name': 'Seconds Test'});
      await client.sync();

      final rows = await client.query('SELECT status, retry_count, next_retry_at FROM _sync_outbox WHERE entity_id = ?', [itemId]);
      expect(rows.first['status'], equals('pending'));
      expect(rows.first['retry_count'], equals(0)); // Rate limit does not burn retry count
      final baseTargetMs = clock.millisecondsSinceEpoch;
      final retryAt = rows.first['next_retry_at'] as int;
      // 30 seconds ± 20% jitter = 24s .. 36s
      expect(retryAt, greaterThanOrEqualTo(baseTargetMs + 24000));
      expect(retryAt, lessThanOrEqualTo(baseTargetMs + 36000));

      await client.close();
      faultClient.close();
    });

    test('Test 6: HTTP 401 Unauthorized releases lease to pending and triggers onAuthExpired', () async {
      var authExpiredCalled = false;

      final faultClient = FaultInjectionHttpClient(
        script: [
          const ReturnStatus(401, body: '{"error":"token_expired"}'),
        ],
      );

      final client = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/auth_expired.db',
        httpClient: faultClient,
        onAuthExpired: () async {
          authExpiredCalled = true;
        },
      );
      await client.registerEntity('items', url: 'https://example.com/api/items');

      final itemId = await client.store('items', {'name': 'Auth Test Item'});
      await client.sync();

      expect(authExpiredCalled, isTrue);

      final rows = await client.query('SELECT status, retry_count, next_retry_at FROM _sync_outbox WHERE entity_id = ?', [itemId]);
      expect(rows.first['status'], equals('pending'));
      expect(rows.first['retry_count'], equals(0)); // Auth expiration does not burn retry attempts
      expect(rows.first['next_retry_at'], isNull);

      await client.close();
      faultClient.close();
    });

    test('Test 7: HTTP 5xx with default BackoffPolicy applies 5 retries then transitions to dlq', () async {
      final clock = ControllableClock(DateTime.utc(2026, 10, 17, 12, 0, 0));
      final policy = BackoffPolicy(
        base: const Duration(seconds: 1),
        jitterFraction: 0,
      );
      expect(policy.maxRetries, equals(5));

      final faultClient = FaultInjectionHttpClient(
        script: [
          const ReturnStatus(500, body: 'Err 1'),
          const ReturnStatus(502, body: 'Err 2'),
          const ReturnStatus(503, body: 'Err 3'),
          const ReturnStatus(504, body: 'Err 4'),
          const ReturnStatus(500, body: 'Err 5'),
        ],
      );

      final client = await OrbitClient.initialize(
        databasePath: '${tempDir.path}/dlq_5_retries.db',
        httpClient: faultClient,
        backoffPolicy: policy,
        nowMsProvider: () => clock.millisecondsSinceEpoch,
      );
      await client.registerEntity('items', url: 'https://example.com/api/items');

      final itemId = await client.store('items', {'name': '5xx DLQ Item'});

      for (var i = 1; i <= 5; i++) {
        await client.sync();
        final rows = await client.query('SELECT status, retry_count, next_retry_at FROM _sync_outbox WHERE entity_id = ?', [itemId]);
        expect(rows.first['retry_count'], equals(i));
        if (i < 5) {
          expect(rows.first['status'], equals('pending'));
          expect(rows.first['next_retry_at'], isNotNull);
          // Advance past backoff window for next retry
          clock.advance(const Duration(seconds: 20));
        } else {
          // 5th retry exhausts maxRetries (5) -> moves to dlq
          expect(rows.first['status'], equals('dlq'));
          expect(rows.first['next_retry_at'], isNull);
        }
      }

      await client.close();
      faultClient.close();
    });
  });
}
