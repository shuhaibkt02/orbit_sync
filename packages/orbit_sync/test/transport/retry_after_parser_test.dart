import 'dart:io';
import 'dart:math';
import 'package:test/test.dart';
import 'package:orbit_sync/orbit_sync.dart';

void main() {
  group('Layer 4 Transport: HTTP 429 Retry-After & Jitter Policy', () {
    test('Exact seconds parsing with jitter disabled returns exact epoch', () {
      final parser = RetryAfterParser();
      const nowMs = 1700000000000;
      final nextRetry = parser.parseNextRetryAt(
        '45',
        nowMs,
        fallbackDelay: const Duration(seconds: 10),
        withJitter: false,
      );

      expect(nextRetry, equals(nowMs + 45000));
    });

    test('Exact HTTP-date parsing with jitter disabled returns exact epoch', () {
      final parser = RetryAfterParser();
      const nowMs = 1700000000000;
      final targetDate = DateTime.fromMillisecondsSinceEpoch(nowMs + 90000, isUtc: true);
      final dateHeader = HttpDate.format(targetDate);

      final nextRetry = parser.parseNextRetryAt(
        dateHeader,
        nowMs,
        fallbackDelay: const Duration(seconds: 10),
        withJitter: false,
      );

      expect(nextRetry, equals(nowMs + 90000));
    });

    test('Jitter distribution strictly bounds between 80% and 120% of base delay', () {
      final parser = RetryAfterParser(random: Random(42));
      const baseDelayMs = 10000;

      for (var i = 0; i < 100; i++) {
        final jittered = parser.applyJitter(baseDelayMs);
        expect(jittered, greaterThanOrEqualTo(8000));
        expect(jittered, lessThanOrEqualTo(12000));
      }
    });

    test('Null, empty, or garbage headers safely default to fallback delay', () {
      final parser = RetryAfterParser();
      const nowMs = 1700000000000;
      const fallback = Duration(seconds: 15);

      expect(
        parser.parseNextRetryAt(null, nowMs, fallbackDelay: fallback, withJitter: false),
        equals(nowMs + 15000),
      );
      expect(
        parser.parseNextRetryAt('   ', nowMs, fallbackDelay: fallback, withJitter: false),
        equals(nowMs + 15000),
      );
      expect(
        parser.parseNextRetryAt('invalid-header-string', nowMs, fallbackDelay: fallback, withJitter: false),
        equals(nowMs + 15000),
      );
    });
  });
}
